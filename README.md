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

Five branches, and only five. Anything that has merged is deleted, because its commits
are still on `develop` and a stale branch pointer is just a second place to be wrong.

    main                              stable; every merge here was proven on hardware
    develop                           integration branch; gates green
      |-- feat/board-a-dual-hdmi-audio          board A: TF -> SDRAM -> 2x HDMI + audio
      |-- feat/board-b-scaler-fft-third-screen  board B: scaler, FFT, third-screen UI
      `-- feat/inter-board-8bit-sync-link       the DC3 8-bit link
              layer 1 (byte pipe, CDC, READY credit) is merged and proven;
              layer 2 (packets, CRC32, session) is WIP on this branch and NOT passing

Rules:
1. `main` only accepts a merge after the change is proven on the real board.
2. Never patch the same layer twice: state the failing layer and the evidence first.
3. Every hardware session leaves a tagged rollback anchor.
4. Simulation testbenches must model the real source rate (~96-180 clk/pixel over SPI).
   A 1 pixel/clock source is ~100x too fast and manufactures bugs that cannot exist on
   hardware. That caused an entire abandoned architecture (B3) in September 2026.
5. Before touching the render path, confirm the signal source is valid: take a screen
   photo and read the 7-seg registered-image count first.
6. A failing bench is not a gate. `run_gates.ps1` holds only checks that pass; the WIP
   link packet layer is deliberately left out rather than wired in red.

Tags are the rollback anchors: `baseline-b23-pre-refactor`, `baseline-v12.9`,
`v13.0-bmpgate`, and `v13.0-bit-0920` which names the exact tree the board's current bit
was synthesised from.

## One repository

This is the only git repository in the project. The Chinese-named folder under
`OneDrive\Desktop\` is a read-only reference library; its notes and one-click scripts are
tracked here under `docs/reference/`, and it is not a repository of its own. Build trees
(`td_project*/`), generated images and simulation binaries are ignored - the font image
in particular is regenerable with `tools/cjk_flash/convert_font_image.py`.

## Verification gates

One command, from `tools/tests/`:

    powershell -ExecutionPolicy Bypass -File .\run_gates.ps1

It compiles and runs the four SD/BMP gates and checks each one's expected pass
signature; exit code 1 means at least one gate regressed. Add `-WithOldRtl` to
replay the A/B demo of the v13.0 bug against the frozen `bmp_read_pre_v13.v`.

| Bench | Proves | Pass signature |
|---|---|---|
| `tb_bmpgate.v` | a header cannot register unless its own bytes back its declared geometry | `RESULT: PASS` (14 checks) |
| `tb_bmpscan.v` | sector walk, scan-window stop-loss, multi-resolution registration gate | `tb_bmpscan done: errors=0` (11 checks, ~2 min) |
| `tb_chain.v` | SD load chain, NEXT/commit behaviour | `30 checks, 0 FAIL` |
| `tb_mask32.v` | mask and commit path | `11090 checks, 0 FAIL` |
| `tb_dc3_link.v` | inter-board byte pipe, clock-domain crossing, READY credit | `RESULT: PASS` (13 checks) |

`tb_dc3_link.v` needs only `user_source/hdl_source/link/dc3_link.v` - the link is not in
any build yet, and it is the one part of the dual-board plan that can be proven without a
second board on the bench.

The four SD gates need only the SD subtree; `run_gates.ps1` carries the file list, because
compiling the whole `hdl_source` tree drags in vendor `*_sim.v` models that Icarus
cannot resolve.

Bench-specific gates, run by hand:

- `tb_scaler_real.v` - primary render gate: real-rate source, independently decodable
  pattern, geometry checked against design intent.
- `tb_v103_fw.v` - integration bench (real wfifo + frame_fifo_write + scaler).
- `scaler_golden_cmp.py` - offline golden geometry comparison.

`tb_scaler_burst.v` is a boundary stress bench only; its 1 pixel/clock source is not
real hardware behaviour and its numbers must be rescaled before being read as evidence.

## Current state (2026-09-20)

`develop` is tagged `v13.0-bmpgate`: the black-screen defect is root-caused at the BMP
acceptance gate, fixed, and simulation-proven, but not yet confirmed on hardware, so it
has not reached `main`. `docs/history/` holds the September forensics, including the two
conclusions that were later disproven and must not be acted on again. The target spec for
the dual-FPGA three-screen build is `docs/plan/20260920_dual_fpga_three_screen/`.

