/* wasp memory map (see RTL/System_top.sv, memmap.h)
 *   0x4000_0000  IMEM  64 KB  (boot address, read-only for the program)
 *   0x8000_0000  DMEM  64 KB  (D-cacheable; .data/.rodata are preloaded
 *                              from dmem.mem, crt0 only clears .bss)
 *   0xC000_0000  peripherals (4 KB page each), not used by the linker
 */
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x40000000, LENGTH = 64K
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
}

/* Stack grows down from the top of RAM. The linker fails the build if
 * .data + .bss leave less than this for the stack. */
__stack_size = DEFINED(__stack_size) ? __stack_size : 4K;

SECTIONS
{
    .text : {
        KEEP(*(.text.init))
        *(.text*)
    } > ROM =0x13000000   /* pad gaps with NOPs (ld writes the fill big-endian) */

    /* .data must stay the FIRST section in RAM: dmem.mem is a raw dump of
     * it and is loaded at offset 0 of the data memory. */
    .data : {
        . = ALIGN(4);
        *(.rodata*)
        *(.srodata*)
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        PROVIDE( __global_pointer$ = . + 0x800 );
    } > RAM

    .bss : {
        . = ALIGN(4);
        PROVIDE( __bss_start = . );
        *(.sbss*)
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        PROVIDE( __bss_end = . );
    } > RAM

    PROVIDE( __stack_top = ORIGIN(RAM) + LENGTH(RAM) );

    ASSERT( __bss_end + __stack_size <= __stack_top,
            "RAM overflow: .data + .bss + stack do not fit in 64 KB" )
}
