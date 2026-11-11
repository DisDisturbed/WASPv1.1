/*
 * riscv-dv core setting for the WASP core (derived from riscv-dv's
 * target/rv32imc/riscv_core_setting.sv, Apache-2.0).
 *
 * WASP: RV32IM + Zicsr + Zicntr + Zifencei, M-mode only, no compressed
 * instructions, misaligned loads/stores trap, direct-mode mtvec with the
 * trap target {mtvec[31:8], 8'h00} (the handler alignment is
 * raised to 256 bytes by tools/postproc.py), no PMP, no debug mode.
 *
 * implemented_csr lists only CSRs that both WASP and Spike --priv=m have, so
 * every CSR access behaves the same on both and the register traces can be
 * compared one to one (mcounteren exists on WASP but not on an M-only Spike).
 */
parameter int XLEN = 32;
parameter satp_mode_t SATP_MODE = BARE;
privileged_mode_t supported_privileged_mode[] = {MACHINE_MODE};
riscv_instr_name_t unsupported_instr[];
riscv_instr_group_t supported_isa[$] = {RV32I, RV32M};
mtvec_mode_t supported_interrupt_mode[$] = {DIRECT};
int max_interrupt_vector_num = 16;
bit support_pmp = 0;
bit support_epmp = 0;
bit support_debug_mode = 0;
bit support_umode_trap = 0;
bit support_sfence = 0;
bit support_unaligned_load_store = 1'b0;
parameter int NUM_FLOAT_GPR = 32;
parameter int NUM_GPR = 32;
parameter int NUM_VEC_GPR = 32;
parameter int VECTOR_EXTENSION_ENABLE = 0;
parameter int VLEN = 512;
parameter int ELEN = 32;
parameter int SELEN = 8;
parameter int VELEN = int'($ln(ELEN)/$ln(2)) - 3;
parameter int MAX_LMUL = 8;
parameter int NUM_HARTS = 1;

`ifdef DSIM
privileged_reg_t implemented_csr[] = {
`else
const privileged_reg_t implemented_csr[] = {
`endif
    MVENDORID, MARCHID, MIMPID, MHARTID,
    MSTATUS, MISA, MIE, MTVEC,
    MSCRATCH, MEPC, MCAUSE, MTVAL, MIP
};

bit [11:0] custom_csr[] = {
};

`ifdef DSIM
interrupt_cause_t implemented_interrupt[] = {
`else
const interrupt_cause_t implemented_interrupt[] = {
`endif
    // WASP also has M_TIMER_INTR, but Spike's built-in CLINT starts with
    // mtimecmp = 0: with MTIE set Spike would take a timer interrupt at once
    // and the lock-step comparison would diverge. The testbench injects
    // external and software interrupts; the timer is covered by the
    // counters self-test (make test).
    M_SOFTWARE_INTR,
    M_EXTERNAL_INTR
};

`ifdef DSIM
exception_cause_t implemented_exception[] = {
`else
const exception_cause_t implemented_exception[] = {
`endif
    INSTRUCTION_ADDRESS_MISALIGNED,
    INSTRUCTION_ACCESS_FAULT,
    ILLEGAL_INSTRUCTION,
    BREAKPOINT,
    LOAD_ADDRESS_MISALIGNED,
    LOAD_ACCESS_FAULT,
    STORE_AMO_ADDRESS_MISALIGNED,
    STORE_AMO_ACCESS_FAULT,
    ECALL_MMODE
};
