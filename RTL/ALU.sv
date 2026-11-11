`timescale 1ns / 1ps
`default_nettype none
// alu_control_i encoding intentionally stays a raw vector, not a core_pkg
// This module's own case statement is ALU's actual source of truth for the
// encoding; putting a guessed enum in core_pkg would risk a second, wrong
// definition instead of preventing a duplicate one.
module Alu #(
    parameter DATA_WIDTH = core_pkg::CORE_DATA_WIDTH,
    parameter CONTROL_WIDTH = 4
)
(
    input  wire [DATA_WIDTH - 1:0]    a_in,
    input  wire [DATA_WIDTH - 1:0]    b_in,
    input  wire [CONTROL_WIDTH - 1:0] alu_control_i,

    output reg  [DATA_WIDTH - 1:0] result,
    output reg  error_flag,
    output reg  carry_flag,
    output wire zero_flag
);

    assign zero_flag = (result == {DATA_WIDTH{1'b0}});

    always_comb begin
        result     = {DATA_WIDTH{1'b0}};
        carry_flag = 1'b0;
        error_flag = 1'b0;
        case (alu_control_i)
            4'b0000: begin  // ADD
                {carry_flag, result} = {1'b0, a_in} + {1'b0, b_in};
            end
            4'b0001: begin  // SUB
                {carry_flag, result} = {1'b0, a_in} - {1'b0, b_in};
            end
            4'b0010: begin  // AND
                result = a_in & b_in;
            end
            4'b0011: begin  // OR
                result = a_in | b_in;
            end
            4'b0100: begin  // XOR
                result = a_in ^ b_in;
            end
            4'b0101: begin  // SLT (signed)
                result = ($signed(a_in) < $signed(b_in)) ? {{(DATA_WIDTH-1){1'b0}},1'b1} : {DATA_WIDTH{1'b0}};
            end
            4'b0110: begin  // SLTU (unsigned)
                result = (a_in < b_in) ? {{(DATA_WIDTH-1){1'b0}},1'b1} : {DATA_WIDTH{1'b0}};
            end
            4'b0111: begin  // SLL (logical left shift)
                result = a_in << b_in[$clog2(DATA_WIDTH)-1:0];
            end
            4'b1000: begin  // SRL (logical right shift)
                result = a_in >> b_in[$clog2(DATA_WIDTH)-1:0];
            end
            4'b1001: begin  // SRA (arithmetic right shift)
                result = $signed(a_in) >>> b_in[$clog2(DATA_WIDTH)-1:0];
            end
            default: begin
                error_flag = 1'b1;
            end
        endcase
    end
endmodule