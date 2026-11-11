/* riscv-dv programs on the WASP memory map (see ../../riscv-tests/env/wasp/link.ld).
 *   0x4000_0000 IMEM : .text (main program, test_done, trap handlers)
 *   0x8000_0000 DMEM : .data (tohost first), riscv-dv data regions, stacks
 * The generated program uses ~56 KB of DMEM (2 x 20 KB stacks, 4 x 4 KB regions).
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
    .text : { *(.text) *(.text.*) } > IMEM
    .data : {
        *(.data)
        *(.region_*) *(.s_region_*) *(.amo_*)
        *(.user_stack) *(.kernel_stack)
        *(.sdata*) *(.rodata*)
    } > DMEM
    .bss  : { *(.bss) *(.sbss*) *(COMMON) } > DMEM
    _end = .;
    ASSERT( tohost == 0x80000000, "tohost must be the first word of DMEM" )
}
