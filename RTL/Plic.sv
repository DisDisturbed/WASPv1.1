`timescale 1ns / 1ps
`default_nettype none

// irq_src_i (flat [N_SRC-1:0]) is now irq_lines[N_SRC-1:0], an array of
// irq_if.sink ports -- see irq_if.sv for why an array (not a single wide
// interface) is the right shape here. Source 0 stays reserved/unused
// exactly as before (pending_irq[0]/enable_irq[0]/priority_irq[0] are
// still hard-zeroed below); irq_lines[0] is still wired up by whoever
// instantiates this module, same as irq_src_i[0] always was, it's just
// ignored internally.
//
// The OBI bus side (req_i/gnt_o/rvalid_o/addr_i/we_i/strb_i/wdata_i/
// rdata_o) is now a single obi_data_if.slave port, matching dcache's
// conversion -- this is the leg cache_system_top's arbiter macro-wires
// against core_data_bus, so PLIC no longer needs the plain-assign bridge
// that was standing in for it.
module plic
    import core_pkg::*;
#(
    parameter int DATA_WIDTH = core_pkg::CORE_DATA_WIDTH,
    parameter int N_SRC      = 32,          // number of interrupt sources (source 0 unused)
    parameter logic [31:0] PLIC_BASE = 32'hC0002000  // informational; bus.addr arrives as an offset
)(
    input  wire                   clk,
    input  wire                   rst_n,

    irq_if.sink                   irq_lines [N_SRC-1:0],

    // Interface-array elements can only be indexed with an elaboration-
    // time constant (a genvar), not a plain procedural loop variable --
    // that's a real SV/tool restriction, not just style. So the per-source
    // level is unpacked once here, via a genvar, into a flat vector that
    // the procedural logic below indexes freely, exactly like the
    // original irq_src_i[i] did.
    obi_data_if.slave             bus,

    output logic                  external_irq_o
);

    logic [N_SRC-1:0] irq_pending_w;
    for (genvar g = 0; g < N_SRC; g++) begin : gen_irq_unpack
        assign irq_pending_w[g] = irq_lines[g].pending;
    end

    // Register State
    logic [2:0]       priority_irq [N_SRC];
    logic [N_SRC-1:0] pending_irq;
    logic [N_SRC-1:0] enable_irq;
    logic [2:0]       threshold_irq;
    logic [N_SRC-1:0] in_service_irq;

    // Bus interface registers
    assign bus.gnt = bus.req;
    assign bus.err = 1'b0;   // never fails (unknown offsets read 0)

    logic                  req_r_ff;
    logic [DATA_WIDTH-1:0] addr_r;
    logic                  we_r;
    logic [DATA_WIDTH-1:0] wdata_r;
    logic [3:0]            strb_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_r_ff <= 1'b0;
            addr_r   <= '0;
            we_r     <= 1'b0;
            wdata_r  <= '0;
            strb_r   <= '0;
        end else begin
            req_r_ff <= bus.req & bus.gnt;
            addr_r   <= bus.addr;
            we_r     <= bus.we;
            wdata_r  <= bus.wdata;
            strb_r   <= bus.be;
        end
    end

    // Memory map regions
    typedef enum logic [2:0] {
        REG_PRIORITY,
        REG_PENDING,
        REG_ENABLE,
        REG_THRESHOLD,
        REG_CLAIM,
        REG_UNKNOWN
    } reg_region_e;

    reg_region_e region_w;
    logic [$clog2(N_SRC)-1 :0 ] src_indx;

    // Compact wasp layout: the whole PLIC fits one 4 KB page (offsets from
    // PLIC_BASE; cache_system_top subtracts the base). Same registers as the
    // RISC-V PLIC spec, but NOT its offsets (spec: enable +0x2000,
    // threshold/claim +0x20_0000).
    //   0x000 + 4*id  priority[id]   (id 1..N_SRC-1, 0 is reserved)
    //   0x080         pending        (RO, one bit per source)
    //   0x100         enable         (one bit per source)
    //   0x200         threshold
    //   0x204         claim / complete
    localparam logic [11:0]
        OFF_PENDING   = 12'h080,
        OFF_ENABLE    = 12'h100,
        OFF_THRESHOLD = 12'h200,
        OFF_CLAIM     = 12'h204;

    if (N_SRC > 32)
        $error("plic: compact layout supports at most 32 sources (N_SRC=%0d)", N_SRC);

    // Address Decoding (word-aligned offsets inside the 4 KB page)
    always_comb begin
        region_w  = REG_UNKNOWN;
        src_indx  = '0;

        case ({addr_r[11:2], 2'b00})
            OFF_PENDING:   region_w = REG_PENDING;
            OFF_ENABLE:    region_w = REG_ENABLE;
            OFF_THRESHOLD: region_w = REG_THRESHOLD;
            OFF_CLAIM:     region_w = REG_CLAIM;
            default:
                // 0x000-0x07C; slots >= N_SRC read 0 / ignore writes
                if (addr_r[11:7] == 5'd0 && 32'(addr_r[6:2]) < N_SRC) begin
                    region_w = REG_PRIORITY;
                    src_indx = addr_r[$clog2(N_SRC)+1 : 2];
                end
        endcase
    end

    logic [2:0] most_imp_irq_prio;
    logic is_pending_any;
    logic [$clog2(N_SRC)-1:0] best_id;

    always_comb begin
        most_imp_irq_prio = '0;
        best_id = '0;
        is_pending_any = 1'b0;

        for(int i = 0 ; i < N_SRC ; i++) begin
            if(pending_irq[i] && enable_irq[i] && !in_service_irq[i] && (priority_irq[i] > threshold_irq)) begin

                if (!is_pending_any ||
                    (priority_irq[i] > most_imp_irq_prio) ||
                    ((priority_irq[i] == most_imp_irq_prio) && (i < best_id))) begin

                    most_imp_irq_prio = priority_irq[i];
                    best_id = i[$clog2(N_SRC)-1:0];
                    is_pending_any = 1'b1;
                end
            end
        end
    end

    assign external_irq_o = is_pending_any;

    // Detect a claim read
    logic claim_read;
    assign claim_read = req_r_ff && !we_r && (region_w == REG_CLAIM);

    // Pending Latch
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pending_irq <= '0;
        end else begin
            for(int i = 1; i < N_SRC; i++) begin
                if (claim_read && is_pending_any && (best_id == i[$clog2(N_SRC)-1:0])) begin
                    pending_irq[i] <= 1'b0;
                end else if (irq_pending_w[i] && !in_service_irq[i]) begin
                    pending_irq[i] <= 1'b1;
                end
            end
            pending_irq[0] <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < N_SRC; i++) priority_irq[i] <= 3'd1;
            priority_irq[0] <= 3'd0;
            enable_irq      <= '0;
            threshold_irq   <= 3'd0;
            in_service_irq  <= '0;
        end else begin
            if (req_r_ff && we_r) begin
                case (region_w)
                    REG_PRIORITY: begin
                        if (src_indx != '0 && src_indx < N_SRC)
                            priority_irq[src_indx] <= wdata_r[2:0];
                    end
                    REG_ENABLE: begin
                        for (int b = 0; b < 4; b++) begin
                            if (strb_r[b]) begin
                                for (int k = 0; k < 8; k++) begin
                                    automatic int current_src = b*8 + k;
                                    if (current_src > 0 && current_src < N_SRC)
                                        enable_irq[current_src] <= wdata_r[current_src];
                                end
                            end
                        end
                        enable_irq[0] <= 1'b0;
                    end
                    REG_THRESHOLD: begin
                        threshold_irq <= wdata_r[2:0];
                    end
                    REG_CLAIM: begin
                        if (wdata_r < N_SRC && wdata_r != '0)
                            in_service_irq[wdata_r] <= 1'b0;
                    end
                    default: ;
                endcase
            end else if (claim_read) begin
                if (is_pending_any) begin
                    in_service_irq[best_id] <= 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus.rvalid <= 1'b0;
            bus.rdata  <= '0;
        end else begin
            bus.rvalid <= req_r_ff;
            if (req_r_ff && !we_r) begin
                case (region_w)
                    REG_PRIORITY:  bus.rdata <= DATA_WIDTH'(priority_irq[src_indx]);
                    REG_PENDING:   bus.rdata <= DATA_WIDTH'(pending_irq);
                    REG_ENABLE:    bus.rdata <= DATA_WIDTH'(enable_irq);
                    REG_THRESHOLD: bus.rdata <= DATA_WIDTH'(threshold_irq);
                    REG_CLAIM:     bus.rdata <= is_pending_any ? DATA_WIDTH'(best_id) : '0;
                    default:       bus.rdata <= '0;
                endcase
            end else begin
                bus.rdata <= '0;
            end
        end
    end

endmodule