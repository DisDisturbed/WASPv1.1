.section .text.init
.global _start

_start:
    nop                     /* Reset vector alignment/catch */

    /* ------------------------------------------------- */
    /* 0. SET EARLY TRAP CATCHER                         */
    /* If a trap fires before main() sets mtvec,         */
    /* the CPU will jump to early_trap_panic instead of  */
    /* rebooting!                                        */
    /* ------------------------------------------------- */
    la t0, early_trap_panic
    csrw mtvec, t0

    /* ------------------------------------------------- */
    /* 1. Initialize Global Pointer                      */
    /* ------------------------------------------------- */
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    /* ------------------------------------------------- */
    /* 2. Initialize Stack Pointer                       */
    /* ------------------------------------------------- */
    la sp, __stack_top      
    add s0, sp, zero        /* Set frame pointer */

    /* ------------------------------------------------- */
    /* 3. Clear .bss Section                             */
    /* ------------------------------------------------- */
    la a0, __bss_start
    la a1, __bss_end
    bgeu a0, a1, 2f         /* Skip if start >= end (empty bss) */
1:
    sw zero, 0(a0)          /* Store zero */
    addi a0, a0, 4          /* Move to next word */
    bltu a0, a1, 1b         /* Loop until we hit the end */
2:

    /* ------------------------------------------------- */
    /* 4. Jump to C Code                                 */
    /* ------------------------------------------------- */
    jal ra, main

    /* ------------------------------------------------- */
    /* 5. End of Main Loop (Safety)                      */
    /* ------------------------------------------------- */
end_of_program_loop:  
    j end_of_program_loop

    /* ------------------------------------------------- */
    /* 6. THE PANIC HANDLER                              */
    /* ------------------------------------------------- */
    .align 4
early_trap_panic:
    j early_trap_panic
