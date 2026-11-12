`timescale 1ns / 1ps
`default_nettype none
// this is an ff based reg file
// has internal forwarding
//
// Uses core_pkg only for the default widths: this module carries no
// encoding (no opcodes, no mux selects) that another module has to agree
// with.
module register_file #(
       parameter DATA_WIDTH = core_pkg::CORE_DATA_WIDTH,
       parameter ADDR_WIDTH = core_pkg::CORE_RF_ADDR_WIDTH // if fpu it need to be 6
       )(
       input wire    clk,
       input wire    rst_n,


       //read port 1
       input wire [ADDR_WIDTH-1:0]   read_port1_addr_i,
       output logic [DATA_WIDTH-1:0] read_port1_data_o,

       //read port 2
       input wire [ADDR_WIDTH-1:0]   read_port2_addr_i,
       output logic [DATA_WIDTH-1:0] read_port2_data_o,

       //write port 1
       input wire                  write_port1_en_i,
       input wire [ADDR_WIDTH-1:0] write_port1_addr_i,
       input wire [DATA_WIDTH-1:0] write_port1_data_i
    );

    localparam NUM_REGS = 2**ADDR_WIDTH;
    logic [DATA_WIDTH-1:0] reg_file_mem [NUM_REGS-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
         if(!rst_n) begin
             for(int i = 1; i < NUM_REGS; i = i + 1) begin
                  reg_file_mem[i] <= DATA_WIDTH'(0);
                  reg_file_mem[0] <= 0;
             end
         end
         else if(write_port1_en_i && (write_port1_addr_i != ADDR_WIDTH'(0))) begin
              reg_file_mem[write_port1_addr_i] <= write_port1_data_i;
         end
    end

    //read port 1
    always_comb begin
         if (read_port1_addr_i == 0) begin
             read_port1_data_o = DATA_WIDTH'(0);
         end
         else if (write_port1_en_i && (write_port1_addr_i == read_port1_addr_i)&&(write_port1_addr_i !=  ADDR_WIDTH'(0))) begin
                 read_port1_data_o = write_port1_data_i;
         end
         else begin
         read_port1_data_o = reg_file_mem[read_port1_addr_i];
         end
    end


    //read port 2
    always_comb begin
         if (read_port2_addr_i == 0) begin
             read_port2_data_o = DATA_WIDTH'(0);
         end
         else if (write_port1_en_i && (write_port1_addr_i == read_port2_addr_i)&&(write_port1_addr_i !=  ADDR_WIDTH'(0))) begin
                 read_port2_data_o = write_port1_data_i;
         end
         else begin
         read_port2_data_o = reg_file_mem[read_port2_addr_i];
         end
    end
endmodule