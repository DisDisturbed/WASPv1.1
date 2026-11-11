/* riscv-tests linker script for the WASP SoC (see riscv_test.h in this dir).
 *
 * WASP is a Harvard SoC: instructions are fetched only from IMEM (I-cache ->
 * crossbar M00, read-only for data accesses) and only DMEM is writable.
 * The upstream "p" env puts everything in one region at 0x8000_0000, so here
 * the sections are split:
 *
 *   0x4000_0000  IMEM 64 KB   .text.init, .text            -> imem.mem
 *   0x8000_0000  DMEM 64 KB   .tohost (first!), .data, .bss -> dmem.mem
 *
 * tohost is pinned to 0x8000_0000 (TOHOST in the Makefile / +tohost= in the
 * testbench). The test code reaches its data with `la` (auipc+addi), which
 * spans the 1 GB distance between the two memories.
 */
OUTPUT_ARCH( "riscv" )
ENTRY( _start )

MEMORY
{
    IMEM (rx) : ORIGIN = 0x40000000, LENGTH = 64K
    DMEM (rw) : ORIGIN = 0x80000000, LENGTH = 64K
}

SECTIONS
{
    .text.init : { *(.text.init) } > IMEM
    .text      : { *(.text) *(.text.*) } > IMEM

    .tohost    : { *(.tohost) } > DMEM
    .data      : { *(.data) *(.data.*) *(.sdata*) *(.rodata*) *(.srodata*) } > DMEM
    .bss       : { *(.bss) *(.bss.*) *(.sbss*) *(COMMON) } > DMEM
    _end = .;

    ASSERT( tohost == 0x80000000, "tohost must be the first word of DMEM" )
}
