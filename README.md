# EG4S20 Dual-FPGA Three-Screen Audio-Visual System

Competition: 2026 National Embedded Chips & System Design Contest, FPGA track, topic 1.
Device: Anlogic EG4S20BG256 (19600 LUT, 29x 18x18 mult, 8 MiB SDRAM, 4 PLL per board).
Toolchain: Anlogic TD 6.2.168, Icarus Verilog for simulation.

## Path rules (hard constraints, do not violate)

- The working tree must stay on a pure-ASCII path. `C:\td_batch\` is the build root.
  TD crashes or misbehaves on Chinese / OneDrive-synced paths.
- `.bat` files must be ASCII only. Chinese text belongs in Python or Markdown.
- Keep functional Verilog comments short and ASCII: long Chinese comment lines trigger
  an elaborate-time segfault in TD 6.2.168.
- Python: `C:\Users\lwy\miniconda3\envs\fpga_batch\python.exe -X utf8`
- Icarus: `C:\iverilog\bin\iverilog.exe` (not on PATH)

## What lives where

| Path | Role | In git |
|---|---|---|
| `user_source/hdl_source/` | RTL source of truth | yes |
| `user_source/constraints_source/` | pin/timing constraints | yes |
| `tools/tests/` | simulation testbenches and gates | yes |
| `tools/console/`, `tools/sd_prep/` | host-side board console, card prep | yes |
| `docs/plan/20260920_dual_fpga_three_screen/` | authoritative target spec (V3 / V3.1) | yes |
| `td_project*/` | TD build trees, bitstreams | no (regenerable) |
| `_cold_archive/`, `_refactor_backup/` | dead experiments, kept for forensics | no |

Vendor reference material (TD installers, official examples, schematics, chip manuals)
is a 5.7 GB read-only library kept outside this repo at
`OneDrive\Desktop\FPGA嵌入式大赛\HX4S20_Contest_202606\`. It is a dependency, never a
merge target, and must not be deleted or pushed.

## Branch model

    main                      stable, each merge here was verified on hardware
      ^
    develop                   integration branch
      ^
      |-- feat/single-board-baseline-fix   current black-screen defect
      |-- feat/board-a-dual-hdmi-audio     board A: TF -> SDRAM -> 2x HDMI + audio
      |-- feat/board-b-scaler-fft-third-screen  board B: scaler, FFT, third screen UI
      |-- feat/inter-board-8bit-sync-link  the DC3 8-bit source-synchronous link
      |-- test/regression-gates            simulation gate scripts, golden models
      `-- test/hardware-in-loop            on-board probe scripts, acceptance records

Rules:
1. `main` only accepts a merge after the change is proven on the real board.
2. Never patch the same layer twice: state the failing layer and the evidence first.
3. Every hardware session leaves a tagged rollback anchor.
4. Simulation testbenches must model the real source rate (~96-180 clk/pixel over SPI).
   A 1 pixel/clock source is ~100x too fast and manufactures bugs that cannot exist
   on hardware. This caused an entire abandoned architecture (B3) in September 2026.
5. Before touching the render path, confirm the signal source is valid: take a screen
   photo and read the 7-seg registered-image count first.

## Verification gates

Run from `tools/tests/`:

- `tb_scaler_real.v` - primary gate: real-rate source, independently decodable pattern,
  geometry checked against design intent.
- `tb_chain.v`, `tb_mask32.v` - long-standing pass/fail gates.
- `tb_v103_fw.v` - integration bench (real wfifo + frame_fifo_write + scaler).
- `scaler_golden_cmp.py` - offline golden geometry comparison.

`tb_scaler_burst.v` is a boundary stress bench only; its 1 pixel/clock source is not
real hardware behaviour and its numbers must be rescaled before being read as evidence.
