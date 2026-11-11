`timescale 1ns / 1ps
`default_nettype none

// ctrl_i (funct3-based mul/div op select) intentionally stays a raw [2:0]
// vector, not a core_pkg enum -- see core_pkg.sv header. This module owns
// that encoding; it is not duplicated anywhere else in the design.
module MulDiv #(
    parameter int DATA_WIDTH = core_pkg::CORE_DATA_WIDTH
) (
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire                   start_i,   // begin a new operation (1-cycle pulse)
    input  wire                   kill_i,    // abort in-flight op  (tie to flush_i)
    input  wire                   stall_i,   // hold DONE state during downstream stall

    input  wire [2:0]             ctrl_i,

    input  wire [DATA_WIDTH-1:0]  operand_a_i,
    input  wire [DATA_WIDTH-1:0]  operand_b_i,

    output logic                  busy_o,        // high while computing
    output logic                  done_o,        // 1-cycle pulse; busy_o = 0 on this cycle
    output logic [DATA_WIDTH-1:0] result_o,      // valid when done_o is high
    output logic                  div_by_zero_o  // sticky until next start
);

    //  funct3 constants
    localparam logic [2:0] F3_MUL    = 3'b000;
    localparam logic [2:0] F3_MULH   = 3'b001;
    localparam logic [2:0] F3_MULHSU = 3'b010;
    localparam logic [2:0] F3_MULHU  = 3'b011;
    localparam logic [2:0] F3_DIV    = 3'b100;
    localparam logic [2:0] F3_DIVU   = 3'b101;
    localparam logic [2:0] F3_REM    = 3'b110;
    localparam logic [2:0] F3_REMU   = 3'b111;


    //  State machine
    typedef enum logic [1:0] {
        IDLE     = 2'b00,
        MUL_WAIT = 2'b01,  // product registered; 1 settling cycle
        DIV_CALC = 2'b10,  // iterative restoring division (32 cycles)
        DONE     = 2'b11   // result valid; busy_o LOW on this cycle
    } state_e;

    state_e state_r;

    logic [2:0]              ctrl_r;

    // - Multiply -
    logic [2*DATA_WIDTH-1:0] mul_product_r;

    // - Divide -
    logic [DATA_WIDTH-1:0]   dividend_r;    // working |numerator| shifted left each iter
    logic [DATA_WIDTH-1:0]   divisor_r;     // |denominator|, constant across iters
    logic [DATA_WIDTH:0]     remainder_r;   // 33-bit partial remainder
    logic [DATA_WIDTH-1:0]   quotient_r;
    logic [5:0]              iter_cnt_r;    // counts 32 -> 1
    logic                    quot_neg_r;    // negate quotient in result mux
    logic                    rem_neg_r;     // negate remainder in result mux
    logic                    div_zero_r;

    logic is_signed_op_w;
    logic a_neg_w, b_neg_w;
    logic [DATA_WIDTH-1:0] abs_a_w, abs_b_w;
    logic div_overflow_w;

    assign is_signed_op_w =  (ctrl_i == F3_DIV) | (ctrl_i == F3_REM);
    assign a_neg_w        =   is_signed_op_w & operand_a_i[DATA_WIDTH-1];
    assign b_neg_w        =   is_signed_op_w & operand_b_i[DATA_WIDTH-1];
    assign abs_a_w        =   a_neg_w ? (~operand_a_i + 1'b1) : operand_a_i;
    assign abs_b_w        =   b_neg_w ? (~operand_b_i + 1'b1) : operand_b_i;
    // Signed overflow: INT_MIN / -1
    assign div_overflow_w =   is_signed_op_w
                            & (operand_a_i == {1'b1, {(DATA_WIDTH-1){1'b0}}})
                            & (&operand_b_i);

    //  Multiplier: 64-bit combinational product (registered on IDLE -> MUL_WAIT)
    //
    //  Sign treatment
    //  MUL / MULH  : both operands sign-extended -> signed x signed
    //  MULHSU      : a sign-extended, b zero-extended (MSB=0 -> positive even
    //                when cast to signed 64-bit, so the product is correct)
    //  MULHU       : both zero-extended                -> unsigned x unsigned

    logic [2*DATA_WIDTH-1:0] mul_product_comb_w;

    always_comb begin : mul_product_sel
        case (ctrl_i)
            F3_MUL, F3_MULH: // signed x signed
                mul_product_comb_w =
                    $signed({{DATA_WIDTH{operand_a_i[DATA_WIDTH-1]}}, operand_a_i}) *
                    $signed({{DATA_WIDTH{operand_b_i[DATA_WIDTH-1]}}, operand_b_i});

            F3_MULHSU:        // signed x unsigned
                mul_product_comb_w =
                    $signed({{DATA_WIDTH{operand_a_i[DATA_WIDTH-1]}}, operand_a_i}) *
                    $signed({{DATA_WIDTH{1'b0}},                      operand_b_i});

            default:           // F3_MULHU - unsigned x unsigned
                mul_product_comb_w =
                    {{DATA_WIDTH{1'b0}}, operand_a_i} *
                    {{DATA_WIDTH{1'b0}}, operand_b_i};
        endcase
    end
    logic [DATA_WIDTH:0] shifted_rem_w;
    logic [DATA_WIDTH:0] trial_sub_w;

    assign shifted_rem_w = {remainder_r[DATA_WIDTH-1:0], dividend_r[DATA_WIDTH-1]};
    assign trial_sub_w   = shifted_rem_w - {1'b0, divisor_r};

    assign busy_o = (state_r == MUL_WAIT) | (state_r == DIV_CALC);
    assign done_o = (state_r == DONE);

    always_comb begin : result_mux
        result_o      = '0;
        div_by_zero_o = div_zero_r;

        case (ctrl_r)
            F3_MUL:
                result_o = mul_product_r[DATA_WIDTH-1:0];

            F3_MULH, F3_MULHSU, F3_MULHU:
                result_o = mul_product_r[2*DATA_WIDTH-1:DATA_WIDTH];

            F3_DIV, F3_DIVU:
                result_o = quot_neg_r ? (~quotient_r + 1'b1) : quotient_r;

            F3_REM, F3_REMU:
                result_o = rem_neg_r
                           ? (~remainder_r[DATA_WIDTH-1:0] + 1'b1)
                           : remainder_r[DATA_WIDTH-1:0];

            default: result_o = '0;
        endcase
     end



    always_ff @(posedge clk or negedge rst_n) begin : fsm_reg
        if (!rst_n || kill_i) begin
            state_r       <= IDLE;
            ctrl_r        <= '0;
            mul_product_r <= '0;
            dividend_r    <= '0;
            divisor_r     <= '0;
            remainder_r   <= '0;
            quotient_r    <= '0;
            iter_cnt_r    <= '0;
            quot_neg_r    <= 1'b0;
            rem_neg_r     <= 1'b0;
            div_zero_r    <= 1'b0;
        end else begin
            case (state_r)

                IDLE: begin
                    if (start_i) begin
                        ctrl_r     <= ctrl_i;
                        div_zero_r <= 1'b0;

                        if (!ctrl_i[2]) begin
                            mul_product_r <= mul_product_comb_w;
                            state_r       <= MUL_WAIT;

                        end else begin

                            if (operand_b_i == '0) begin
                                div_zero_r  <= 1'b1;
                                quotient_r  <= '1;
                                remainder_r <= {1'b0, operand_a_i};
                                quot_neg_r  <= 1'b0;
                                rem_neg_r   <= 1'b0;
                                state_r     <= DONE;

                            end else if (div_overflow_w) begin
                                quotient_r  <= {1'b1, {(DATA_WIDTH-1){1'b0}}}; // INT_MIN
                                remainder_r <= '0;
                                quot_neg_r  <= 1'b0;
                                rem_neg_r   <= 1'b0;
                                state_r     <= DONE;

                            end else begin
                                quot_neg_r  <= (ctrl_i == F3_DIV)
                                               & (operand_a_i[DATA_WIDTH-1]
                                                  ^ operand_b_i[DATA_WIDTH-1]);
                                rem_neg_r   <= (ctrl_i == F3_REM)
                                               & operand_a_i[DATA_WIDTH-1];
                                dividend_r  <= abs_a_w;
                                divisor_r   <= abs_b_w;
                                remainder_r <= '0;
                                quotient_r  <= '0;
                                iter_cnt_r  <= 6'd32;
                                state_r     <= DIV_CALC;
                            end
                        end
                    end
                end

                //  MUL_WAIT
                MUL_WAIT: begin
                    state_r <= DONE;
                end


                DIV_CALC: begin
                    if (!trial_sub_w[DATA_WIDTH]) begin
                        remainder_r <= trial_sub_w;
                        quotient_r  <= {quotient_r[DATA_WIDTH-2:0], 1'b1};
                    end else begin
                        remainder_r <= shifted_rem_w;
                        quotient_r  <= {quotient_r[DATA_WIDTH-2:0], 1'b0};
                    end
                    dividend_r <= {dividend_r[DATA_WIDTH-2:0], 1'b0};

                    if (iter_cnt_r == 6'd1)
                        state_r <= DONE;

                    iter_cnt_r <= iter_cnt_r - 6'd1;
                end

                DONE: begin
                    if (!stall_i)
                        state_r <= IDLE;
                end

                default: state_r <= IDLE;

            endcase
        end
    end

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (start_i)
                $display("[MULDIV %0t] START  ctrl=%03b  a=0x%08h  b=0x%08h",
                         $time, ctrl_i, operand_a_i, operand_b_i);
            if (done_o)
                $display("[MULDIV %0t] DONE   ctrl=%03b  result=0x%08h  div_zero=%b",
                         $time, ctrl_r, result_o, div_by_zero_o);
            if (kill_i && state_r != IDLE)
                $display("[MULDIV %0t] KILLED (was in state %s)", $time, state_r.name());
        end
    end
`endif

endmodule