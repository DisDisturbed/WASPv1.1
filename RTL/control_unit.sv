`timescale 1ns / 1ps
`default_nettype none

// branch_type_o / wb_ctrl_o / csr_op_o now emit the core_pkg enums directly
// -- this is the module that is the source of truth for those encodings,
// so casting the raw instruction-field bits into the named type here (once)
// is what lets EX_stage/WB_stage/csr_file consume named values instead of
// re-deriving meaning from a bare 2-3 bit number.
//
// op_type / F7 / SYSTEM / imm_sel_e stay as local typedefs: they are not
// duplicated anywhere else in the design, so promoting them to core_pkg
// would add a dependency without removing any duplication risk.
//
// alu_ctrl_o / mem_ctrl_o / muldiv_ctrl_o stay raw vectors -- see
// core_pkg.sv header ("WHAT WAS DELIBERATELY *NOT* PROMOTED").
module control_unit
    import core_pkg::*;
(
    input  wire [31:0]  instr_i,

    // datapath signals
    output logic [31:0] imm_extended_o,
    output logic [11:0] csr_addr_o,
    output csr_op_e      csr_op_o,
    output logic [31:0] csr_wdata_o,
    output logic [4:0]  rs1_addr_o,
    output logic [4:0]  rs2_addr_o,
    output logic [4:0]  rd_addr_o,

    //mux control
    output logic        reg_write_o,
    output logic [1:0]  rs1_src_o,
    output logic        alu_src_o,
    output logic [3:0]  alu_ctrl_o,

    // branch and jump
    output branch_type_e branch_type_o,
    output logic        is_branch_o,
    output logic        is_jump_o,
    output logic        jalr_o,

    // ex signals
    output logic        is_muldiv_o,
    output logic [2:0]  muldiv_ctrl_o,
    output logic        is_mul_o,
    output logic        is_div_o,

    // mem/wb control
    output logic [2:0]  mem_ctrl_o,
    output logic        is_load_o,
    output logic        is_store_o,
    output wb_sel_e      wb_ctrl_o,

    // csr and trap
    output logic        csr_access_o,
    output logic        mret_o,
    output logic        ecall_o,
    output logic        ebreak_o,
    output logic        illegal_instr_o
);

    logic [6:0] opcode ;
    logic [2:0] funct3 ;
    logic [6:0] funct7 ;

    assign opcode = instr_i[6:0];
    assign funct3 = instr_i[14:12];
    assign funct7 = instr_i[31:25];

    assign rs1_addr_o = instr_i[19:15];
    assign rs2_addr_o = instr_i[24:20];
    assign rd_addr_o  = instr_i[11:7];
    assign csr_addr_o = instr_i[31:20];


    typedef enum logic [6:0] {
        OP_R      = 7'b011_0011,
        OP_I_ALU  = 7'b001_0011,
        OP_LOAD   = 7'b000_0011,
        OP_STORE  = 7'b010_0011,
        OP_BRANCH = 7'b110_0011,
        OP_JAL    = 7'b110_1111,
        OP_JALR   = 7'b110_0111,
        OP_LUI    = 7'b011_0111,
        OP_AUIPC  = 7'b001_0111,
        OP_SYSTEM = 7'b111_0011} op_type;

    typedef enum logic [6:0] {
        F7_BASE = 7'b000_0000,
        F7_ALT  = 7'b010_0000,
        F7_MEXT = 7'b000_0001,
        F7_MRET = 7'b001_1000,
        F7_WFI  = 7'b000_1000 }F7;

    typedef enum logic [4:0]{
        RS2_ECALL  = 5'b00000,
        RS2_EBREAK = 5'b00001,
        RS2_MRET   = 5'b00010,
        RS2_WFI    = 5'b00101}SYSTEM;

    localparam logic [1:0]
        RS1_REG  = 2'b00,
        RS1_PC   = 2'b01,
        RS1_ZERO = 2'b10;

    typedef enum logic [2:0] {
        IMM_I = 3'd0,
        IMM_S = 3'd1,
        IMM_B = 3'd2,
        IMM_U = 3'd3,
        IMM_J = 3'd4,
        IMM_Z = 3'd5
    } imm_sel_e;

    imm_sel_e imm_sel;

    // decoder
    always_comb begin : instruction_decoder


        imm_sel         = IMM_I;
        reg_write_o     = 1'b0;
        rs1_src_o       = RS1_REG;
        alu_src_o       = 1'b0;
        alu_ctrl_o      = 4'b0000;

        branch_type_o   = BR_BEQ;
        is_branch_o     = 1'b0;
        is_jump_o       = 1'b0;
        jalr_o          = 1'b0;

        is_muldiv_o     = 1'b0;
        muldiv_ctrl_o   = 3'b000;
        is_mul_o        = 1'b0;
        is_div_o        = 1'b0;

        mem_ctrl_o      = 3'b000;
        is_load_o       = 1'b0;
        is_store_o      = 1'b0;
        wb_ctrl_o       = WB_SEL_ALU_RESULT;

        csr_access_o    = 1'b0;
        csr_op_o        = CSR_OP_NOP;
        csr_wdata_o     = '0;

        mret_o          = 1'b0;
        ecall_o         = 1'b0;
        ebreak_o        = 1'b0;
        illegal_instr_o = 1'b0;

        unique case (opcode)

            OP_R: begin
                reg_write_o = 1'b1;
                if (funct7 == F7_MEXT) begin
                    is_muldiv_o   = 1'b1;
                    muldiv_ctrl_o = funct3;
                    is_mul_o      = ~funct3[2];
                    is_div_o      =  funct3[2];
                end
                else if (funct7 == F7_BASE || funct7 == F7_ALT) begin
                    case (funct3)
                        3'b000: alu_ctrl_o = (funct7 == F7_ALT) ? 4'b0001 : 4'b0000; // ADD/SUB
                        3'b111: alu_ctrl_o = 4'b0010; // AND
                        3'b110: alu_ctrl_o = 4'b0011; // OR
                        3'b100: alu_ctrl_o = 4'b0100; // XOR
                        3'b010: alu_ctrl_o = 4'b0101; // SLT
                        3'b011: alu_ctrl_o = 4'b0110; // SLTU
                        3'b001: alu_ctrl_o = 4'b0111; // SLL
                        3'b101: alu_ctrl_o = (funct7 == F7_ALT) ? 4'b1001 : 4'b1000; // SRL/SRA
                        default: alu_ctrl_o = 4'b0000;
                    endcase
                end else begin
                    illegal_instr_o = 1'b1;
                end
            end

            OP_I_ALU: begin
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1;
                imm_sel     = IMM_I;

                case (funct3)
                    3'b000: alu_ctrl_o = 4'b0000; // ADDI
                    3'b111: alu_ctrl_o = 4'b0010; // ANDI
                    3'b110: alu_ctrl_o = 4'b0011; // ORI
                    3'b100: alu_ctrl_o = 4'b0100; // XORI
                    3'b010: alu_ctrl_o = 4'b0101; // SLTI
                    3'b011: alu_ctrl_o = 4'b0110; // SLTIU
                    3'b001: begin
                        if (funct7 == F7_BASE)
                            alu_ctrl_o = 4'b0111;
                        else
                            illegal_instr_o = 1'b1;
                    end
                    3'b101: alu_ctrl_o = (funct7 == F7_ALT) ? 4'b1001 : 4'b1000; // SRLI/SRAI
                    default: alu_ctrl_o = 4'b0000;
                endcase

                if ((funct3 == 3'b001 || funct3 == 3'b101) && !(funct7 == F7_BASE || funct7 == F7_ALT)) begin
                    illegal_instr_o = 1'b1;
                end
            end

            OP_LOAD: begin
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1;
                is_load_o   = 1'b1;
                wb_ctrl_o   = WB_SEL_LOAD_DATA;
                mem_ctrl_o  = funct3;
                imm_sel     = IMM_I;
                if (funct3 > 3'b101) illegal_instr_o = 1'b1;
            end

            OP_STORE: begin
                alu_src_o   = 1'b1;
                is_store_o  = 1'b1;
                mem_ctrl_o  = funct3;
                imm_sel     = IMM_S;
                if (funct3 > 3'b010) illegal_instr_o = 1'b1;
            end

            OP_BRANCH: begin
                is_branch_o   = 1'b1;
                branch_type_o = branch_type_e'(funct3);
                imm_sel       = IMM_B;

                case (funct3)
                    3'b000, 3'b001: alu_ctrl_o = 4'b0001; // SUB for EQ/NE
                    3'b100, 3'b101: alu_ctrl_o = 4'b0101; // SLT for LT/GE
                    3'b110, 3'b111: alu_ctrl_o = 4'b0110; // SLTU for LTU/GEU
                    default: illegal_instr_o = 1'b1;
                endcase
            end

            OP_JAL: begin
                reg_write_o = 1'b1;
                rs1_src_o   = RS1_PC;
                alu_src_o   = 1'b1;
                wb_ctrl_o   = WB_SEL_PC_PLUS4;
                is_jump_o   = 1'b1;
                imm_sel     = IMM_J;
            end

            OP_JALR: begin
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1;
                wb_ctrl_o   = WB_SEL_PC_PLUS4;
                is_jump_o   = 1'b1;
                jalr_o      = 1'b1;
                alu_ctrl_o  = 4'b0000;
                imm_sel     = IMM_I;
            end

            OP_LUI: begin
                reg_write_o = 1'b1;
                rs1_src_o   = RS1_ZERO;
                alu_src_o   = 1'b1;
                alu_ctrl_o  = 4'b0000;
                imm_sel     = IMM_U;
            end

            OP_AUIPC: begin
                reg_write_o = 1'b1;
                rs1_src_o   = RS1_PC;
                alu_src_o   = 1'b1;
                alu_ctrl_o  = 4'b0000;
                imm_sel     = IMM_U;
            end

            OP_SYSTEM: begin
                     if (funct3 == 3'b000) begin
                         // MRET / ECALL / EBREAK / WFI
                         if      (funct7 == F7_MRET && instr_i[24:20] == RS2_MRET)   mret_o   = 1'b1;
                         else if (funct7 == F7_BASE && instr_i[24:20] == RS2_EBREAK) ebreak_o = 1'b1;
                         else if (funct7 == F7_BASE && instr_i[24:20] == RS2_ECALL)  ecall_o  = 1'b1;
                         else if (funct7 == F7_WFI  && instr_i[24:20] == RS2_WFI)    ; // WFI = NOP
                         else illegal_instr_o = 1'b1;
                     end
                     else if (funct3[1:0] == 2'b00) begin
                         illegal_instr_o = 1'b1;
                     end
                     else begin
                         reg_write_o  = 1'b1;
                         csr_access_o = 1'b1;
                         csr_op_o     = csr_op_e'(funct3[1:0]);
                         if (funct3[2]) begin
                             imm_sel     = IMM_Z;
                             csr_wdata_o = {27'b0, instr_i[19:15]};
                         end else begin
                             csr_wdata_o = '0;
                         end
                     end
                 end

            default: begin
                illegal_instr_o = 1'b1;
            end
        endcase
    end

    always_comb begin : immediate_generator
        imm_extended_o = '0;
        unique case(imm_sel)
            IMM_I: imm_extended_o = {{20{instr_i[31]}}, instr_i[31:20]};
            IMM_S: imm_extended_o = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
            IMM_B: imm_extended_o = {{19{instr_i[31]}}, instr_i[31], instr_i[7], instr_i[30:25], instr_i[11:8], 1'b0};
            IMM_U: imm_extended_o = {instr_i[31:12], 12'b0};
            IMM_J: imm_extended_o = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12], instr_i[20], instr_i[30:21], 1'b0};
            IMM_Z: imm_extended_o = {27'b0, instr_i[19:15]};
            default: imm_extended_o = '0;
        endcase
    end

endmodule