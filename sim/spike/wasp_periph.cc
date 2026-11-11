// Spike MMIO plugin: the wasp peripheral page block at 0xC000_0000, so the
// same firmware ELF runs on Spike and on the RTL (see docs/memory_map.md).
//
//   +0x0000 UART16550  RX from a file, TX to a file (like sim/axi_uart16550_0.sv)
//   +0x1000 CLINT      compact layout; mtime counts retired instructions
//                      (Spike: 1 instruction = 1 clock) through the prescaler
//   +0x2000 PLIC       compact layout, nsrc sources (source 0 reserved)
//   +0x3000 D-cache flush register (write accepted, no effect: Spike has no
//           D-cache; a read or another offset is an access fault, as on wasp)
//   +0x4000..0x6FFF    spare slots: access fault (no slave, SLOT_PRESENT=0)
//
// spike --extlib=libwasp_periph.so --device=wasp_periph[,arg...]
//   rx=<file>        UART RX bytes          (default uart_rx.bin, missing = empty)
//   tx=<file>        UART TX bytes          (default uart_tx.bin)
//   tx_bytes=<n>     exit after n TX bytes
//   eot              exit when 0x04 is sent
//   plic_irq_at=<n>  raise PLIC source 2 once minstret >= n
//   clk=<hz>         CLINT clk_freq          (default 50000000)
//   nsrc=<n>         PLIC sources incl. 0     (default 5 = System_top N_SRC)
//
// Interrupt lines (MTIP/MSIP/MEIP) are updated on every register write and
// every Spike tick (5000 instructions), so timer IRQs are tick-granular.
// Spike's own CLINT at 0x0200_0000 is silenced (mtimecmp = ~0) on the first
// tick, and the `time` CSR is synced to this CLINT's mtime.

#include <riscv/abstract_device.h>
#include <riscv/devices.h>
#include <riscv/encoding.h>
#include <riscv/processor.h>
#include <riscv/sim.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <string>
#include <vector>

namespace {

constexpr reg_t WASP_PERIPH_BASE = 0xC0000000;
constexpr reg_t WASP_PERIPH_SIZE = 0x7000;

struct summary_t {
  FILE* tx = nullptr;
  uint64_t tx_count = 0;
  processor_t* proc = nullptr;
  bool done = false;
};
summary_t g_sum;

uint64_t instret() { return g_sum.proc ? g_sum.proc->get_state()->minstret->read() : 0; }

void finish(const char* why) {
  if (g_sum.done) return;
  g_sum.done = true;
  if (g_sum.tx) fflush(g_sum.tx);
  printf("[SPIKE] %s after %llu instructions, %llu UART bytes sent\n", why,
         (unsigned long long)instret(), (unsigned long long)g_sum.tx_count);
  fflush(stdout);
}

}  // namespace

class wasp_periph_t : public abstract_device_t {
 public:
  wasp_periph_t(const sim_t* sim, const std::vector<std::string>& args) : sim(sim) {
    std::string rx_name = "uart_rx.bin", tx_name = "uart_tx.bin";
    for (const auto& a : args) {
      auto eq = a.find('=');
      std::string k = a.substr(0, eq), v = eq == std::string::npos ? "" : a.substr(eq + 1);
      if (k == "rx") rx_name = v;
      else if (k == "tx") tx_name = v;
      else if (k == "tx_bytes") tx_limit = std::stoll(v);
      else if (k == "eot") eot = true;
      else if (k == "plic_irq_at") irq_at = std::stoll(v);
      else if (k == "clk") clk_hz = std::stoul(v);
      else if (k == "nsrc") nsrc = std::min(32, std::max(1, std::stoi(v)));
      else if (!k.empty()) fprintf(stderr, "wasp_periph: unknown arg '%s'\n", a.c_str());
    }
    if (FILE* f = fopen(rx_name.c_str(), "rb")) {
      int c;
      while ((c = fgetc(f)) != EOF) rx.push_back((uint8_t)c);
      fclose(f);
    }
    g_sum.tx = fopen(tx_name.c_str(), "wb");
    if (!g_sum.tx) { perror(tx_name.c_str()); exit(1); }
    prescaler = clk_hz / 1000000 - 1;  // 1 us ticks at reset, like RTL/Clint.sv
    atexit([] { finish("instruction limit (MAX_CYCLES) reached or spike exited"); });
  }

  reg_t size() override { return WASP_PERIPH_SIZE; }

  // Same access check as RTL/cache_system_top.sv: returning false makes
  // Spike raise a load/store access fault with mtval = address.
  static bool accessible(reg_t addr, bool store) {
    switch (addr >> 12) {
      case 0: case 1: case 2: return true;                // UART, CLINT, PLIC
      case 3:  return store && (addr & 0xFFF) == 0;       // flush register: write only
      default: return false;                              // spare slots, no slave
    }
  }

  bool load(reg_t addr, size_t len, uint8_t* bytes) override {
    if (len > 4 || (addr & 3) + len > 4) return false;
    if (!accessible(addr, false)) return false;
    uint32_t v = read32(addr & ~reg_t(3));
    memcpy(bytes, reinterpret_cast<uint8_t*>(&v) + (addr & 3), len);
    return true;
  }

  bool store(reg_t addr, size_t len, const uint8_t* bytes) override {
    if (len > 4 || (addr & 3) + len > 4) return false;
    if (!accessible(addr, true)) return false;
    uint32_t v = 0, mask = 0;
    memcpy(reinterpret_cast<uint8_t*>(&v) + (addr & 3), bytes, len);
    memset(reinterpret_cast<uint8_t*>(&mask) + (addr & 3), 0xFF, len);
    write32(addr & ~reg_t(3), v, mask);
    update_irqs();
    return true;
  }

  void tick(reg_t) override {
    if (!started) {  // silence Spike's built-in CLINT timer
      started = true;
      uint64_t never = ~0ull;
      static_cast<simif_t*>(const_cast<sim_t*>(sim))->mmio_store(0x02004000, 8, reinterpret_cast<uint8_t*>(&never));
    }
    if (irq_at >= 0 && !irq_fired && instret() >= (uint64_t)irq_at) {
      irq_fired = true;
      plic_pending |= 1u << 2;
    }
    update_irqs();
  }

 private:
  const sim_t* sim;
  bool started = false;

  // UART
  std::vector<uint8_t> rx;
  size_t rx_pos = 0;
  uint32_t lcr = 0, ier = 0, mcr = 0, scr = 0;
  long long tx_limit = -1;
  bool eot = false;

  // CLINT: mtime = mtime_ref + (instret - instret_ref) / (prescaler + 1)
  uint32_t clk_hz = 50000000, prescaler = 49, msip = 0;
  uint64_t mtime_ref = 0, instret_ref = 0, mtimecmp = ~0ull;

  // PLIC
  uint32_t plic_prio[32] = {}, plic_pending = 0, plic_enable = 0, plic_threshold = 0,
           plic_in_service = 0;
  long long irq_at = -1;
  bool irq_fired = false;
  int nsrc = 5;

  processor_t* proc() {
    if (!g_sum.proc) g_sum.proc = sim->get_harts().begin()->second;
    return g_sum.proc;
  }

  uint64_t mtime() {
    proc();
    return mtime_ref + (instret() - instret_ref) / (uint64_t(prescaler) + 1);
  }
  void set_mtime(uint64_t t) { mtime_ref = t; instret_ref = instret(); }

  int plic_best() {  // highest priority pending+enabled source above threshold
    int best = 0;
    for (int i = 1; i < nsrc; i++) {
      uint32_t b = 1u << i;
      if ((plic_pending & plic_enable & ~plic_in_service & b) && plic_prio[i] > plic_threshold &&
          (best == 0 || plic_prio[i] > plic_prio[best]))
        best = i;
    }
    return best;
  }

  void update_irqs() {
    processor_t* p = proc();
    uint64_t t = mtime();
    reg_t mip = (t >= mtimecmp ? MIP_MTIP : 0) | (msip ? MIP_MSIP : 0) |
                (plic_best() ? MIP_MEIP : 0);
    p->get_state()->mip->backdoor_write_with_mask(MIP_MTIP | MIP_MSIP | MIP_MEIP, mip);
    p->get_state()->time->sync(t);
  }

  uint32_t read32(reg_t off) {
    switch (off >> 12) {
      case 0:  // UART
        if (lcr & 0x80) return 0;  // DLL/DLM: not modelled
        switch (off & 0xFFF) {
          case 0x00: return rx_pos < rx.size() ? rx[rx_pos++] : 0;
          case 0x04: return ier;
          case 0x08: return 0xC1;  // FIFOs enabled, no interrupt pending
          case 0x0C: return lcr;
          case 0x10: return mcr;
          case 0x14: return 0x60 | (rx_pos < rx.size() ? 1 : 0);  // TEMT|THRE|DR
          case 0x1C: return scr;
        }
        return 0;
      case 1:  // CLINT
        switch (off & 0xFFF) {
          case 0x000: return msip;
          case 0x008: return uint32_t(mtimecmp);
          case 0x00C: return uint32_t(mtimecmp >> 32);
          case 0x010: return uint32_t(mtime());
          case 0x014: return uint32_t(mtime() >> 32);
          case 0x018: return clk_hz;
          case 0x01C: return prescaler;
        }
        return 0;
      case 2: {  // PLIC
        reg_t o = off & 0xFFF;
        if (o < 0x80) return int(o >> 2) < nsrc ? plic_prio[o >> 2] : 0;
        switch (o) {
          case 0x080: return plic_pending;
          case 0x100: return plic_enable;
          case 0x200: return plic_threshold;
          case 0x204: {  // claim
            int id = plic_best();
            if (id) { plic_pending &= ~(1u << id); plic_in_service |= 1u << id; }
            update_irqs();
            return id;
          }
        }
        return 0;
      }
    }
    return 0;  // flush register, spare slots
  }

  void write32(reg_t off, uint32_t v, uint32_t mask) {
    auto merge = [&](uint32_t old) { return (old & ~mask) | (v & mask); };
    switch (off >> 12) {
      case 0:  // UART
        switch (off & 0xFFF) {
          case 0x00:
            if (!(lcr & 0x80) && (mask & 0xFF)) tx_byte(uint8_t(v));
            break;
          case 0x04: if (!(lcr & 0x80)) ier = merge(ier) & 0xF; break;
          case 0x0C: lcr = merge(lcr) & 0xFF; break;
          case 0x10: mcr = merge(mcr) & 0x1F; break;
          case 0x1C: scr = merge(scr) & 0xFF; break;
        }
        break;
      case 1:  // CLINT
        switch (off & 0xFFF) {
          case 0x000: msip = merge(msip) & 1; break;
          case 0x008: mtimecmp = (mtimecmp & ~0xFFFFFFFFull) | merge(uint32_t(mtimecmp)); break;
          case 0x00C: mtimecmp = (mtimecmp & 0xFFFFFFFFull) | (uint64_t(merge(uint32_t(mtimecmp >> 32))) << 32); break;
          case 0x010: { uint64_t t = mtime(); set_mtime((t & ~0xFFFFFFFFull) | merge(uint32_t(t))); break; }
          case 0x014: { uint64_t t = mtime(); set_mtime((t & 0xFFFFFFFFull) | (uint64_t(merge(uint32_t(t >> 32))) << 32)); break; }
          case 0x01C: { uint64_t t = mtime(); prescaler = merge(prescaler); set_mtime(t); break; }
        }
        break;
      case 2: {  // PLIC
        reg_t o = off & 0xFFF;
        if (o < 0x80) {
          if (o >= 4 && int(o >> 2) < nsrc) plic_prio[o >> 2] = merge(plic_prio[o >> 2]) & 7;
          break;
        }
        switch (o) {
          case 0x100: plic_enable = merge(plic_enable) & ~1u & uint32_t((1ull << nsrc) - 1); break;
          case 0x200: plic_threshold = merge(plic_threshold) & 7; break;
          case 0x204: if (v > 0 && int(v) < nsrc) plic_in_service &= ~(1u << v); break;  // complete
        }
        break;
      }
    }
  }

  void tx_byte(uint8_t b) {
    fputc(b, g_sum.tx);
    g_sum.tx_count++;
    if (eot && b == 0x04) { finish("EOT received"); exit(0); }
    if (tx_limit >= 0 && (long long)g_sum.tx_count >= tx_limit) {
      finish("TX byte limit reached");
      exit(0);
    }
  }
};

static wasp_periph_t* wasp_periph_parse(const void*, const sim_t* sim, reg_t* base,
                                        const std::vector<std::string>& args) {
  *base = WASP_PERIPH_BASE;
  return new wasp_periph_t(sim, args);
}

static std::string wasp_periph_dts(const sim_t*, const std::vector<std::string>&) { return ""; }

REGISTER_DEVICE(wasp_periph, wasp_periph_parse, wasp_periph_dts)
