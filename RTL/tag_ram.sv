
`default_nettype none
module icache_tag_ram #(
     parameter TAG_COUNT  = 64,
     parameter ADDR_WIDTH = 32,
     parameter TAG_BITS   = ADDR_WIDTH-12,
     parameter DATA_WIDTH = TAG_BITS + 2
)
(
    // In
    input   wire   clk_i,
    input   wire rst_ni,   // active low, asynchronous
    input   wire  [ADDR_WIDTH-1:0]  ins_addr_i,
    input   wire dirty_icache_in,  //unused for now here for cache coherency drive them on the port declartion critical !!!!!
    input   wire valid_icache_in,  //unused for now here for cache coherency
    
    input wire wr_i, // make a good fsm for this or it will not accept new data
    input wire inv_all_i,  // clear every valid bit (FENCE.I), wins over wr_i

    // Out
    output wire [DATA_WIDTH - 1:0]  tag_o
); 

    localparam VALID_BIT = TAG_BITS,
               DIRTY_BIT = TAG_BITS+1;

    reg [TAG_COUNT-1:0] valid_ram;
    // tag ram contains the start address of lines first address
    reg [DATA_WIDTH - 1 :0] tag_ram [TAG_COUNT - 1 : 0]; //0 to 19 is line first addr data 20 is valid 21 is dirty
    //index for line contains which line index we need to go for read
    
    
    //this is a direct mapped cache there is no logic to search 
    //if you want to change it to fully associative then add the search logic to line index
    wire [$clog2(TAG_COUNT)-1:0] line_index;   //this shows which line we are going to read i goes from 0 to 63 for 64 line cache
    assign line_index = ins_addr_i[11:6];      //removed 2 bit from word allignment removed 4 bit for each line contains 16 registers 
    
    
    reg [DATA_WIDTH - 1: 0] ram_read_q;
    
    
    // Only the valid bits and the read register are reset: the tag array
    // itself has no reset, so it can map to RAM.
    always @(posedge clk_i) begin
        if (wr_i)
            tag_ram[line_index] <= {dirty_icache_in, 1'b0, ins_addr_i[ADDR_WIDTH-1:12]};
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            valid_ram  <= {TAG_COUNT{1'b0}};
            ram_read_q <= {DATA_WIDTH{1'b0}};
        end else if (inv_all_i) begin
            valid_ram  <= {TAG_COUNT{1'b0}};
            ram_read_q <= {DATA_WIDTH{1'b0}};
        end else if (wr_i) begin
            valid_ram[line_index] <= valid_icache_in;
            ram_read_q            <= {dirty_icache_in, valid_icache_in, ins_addr_i[ADDR_WIDTH-1:12]};
        end else begin
            ram_read_q <= {tag_ram[line_index][DIRTY_BIT], valid_ram[line_index], tag_ram[line_index][0 +: TAG_BITS]};
        end
    end
    assign tag_o =  ram_read_q;

endmodule
`default_nettype wire
