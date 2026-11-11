/*
 * WASP user extension for riscv-dv (shadows riscv-dv's user_extension/
 * user_extension.svh: target/wasp is first on the include path; it is
 * included at the end of riscv_instr_pkg).
 *
 * riscv-dv's default data regions are 4 KB + 64 KB, more than WASP's 64 KB
 * DMEM once the stacks are added. wasp_gen_config replaces them with 4 x 4 KB
 * (DMEM use: 16 KB regions + 20 KB user stack + 16 KB kernel stack + .data,
 * see env/link.ld). Selected by the Makefile with
 *   +uvm_set_type_override=riscv_instr_gen_config,wasp_gen_config
 */
class wasp_gen_config extends riscv_instr_gen_config;

  `uvm_object_utils(wasp_gen_config)

  function new(string name = "");
    super.new(name);
    mem_region = '{
      '{name:"region_0", size_in_bytes: 4096, xwr: 3'b111},
      '{name:"region_1", size_in_bytes: 4096, xwr: 3'b111},
      '{name:"region_2", size_in_bytes: 4096, xwr: 3'b111},
      '{name:"region_3", size_in_bytes: 4096, xwr: 3'b111}
    };
  endfunction

endclass
