`timescale 1ns / 1ps

`default_nettype none




module icache_data_ram #(
     parameter line_amount = 64 ,
     parameter line_size = 16 ,
     parameter data_width = 32)
(
    // In
    input   wire   clk_i,
    input   wire  data_req,
    input   wire  [5:0]  line_index_i,
    input   wire  [3:0]  line_reg_index_i,
    input   wire  [ 31:0]  data_i,
    input   wire  wr_i
    // Out
    ,output wire [31:0]  data_o

);

   localparam TOTAL_DEPTH = line_amount * line_size; //1024
   reg [31:0] idata_ram [TOTAL_DEPTH - 1 : 0];

   reg [31:0] data_o_reg;

   wire [9:0] ram_addr ;
   integer i;
    initial begin
        data_o_reg = 32'h13;
        
        for (i = 0; i < 16; i = i + 1) begin
            idata_ram[i] = 32'h13;
        end
    end
   assign ram_addr = (line_index_i * line_size) + line_reg_index_i;
          always @ (posedge clk_i)
          begin
              if (wr_i)
                  idata_ram[ram_addr][31:0] <= data_i;
              if(data_req)
                 data_o_reg <=  idata_ram[ram_addr][31:0];
          end
          assign data_o = data_o_reg;

endmodule
`default_nettype wire