# Board check for v13.0 - 2026-09-21 morning

Scope: this page exists so the hardware session needs no thinking. Everything below is
either already verified (marked V) or still unknown (marked ?). Do not skip step 0.

## What changed, in one paragraph  (V)

`bmp_read.v` gained a header acceptance gate (v13.0). A BMP is now registered and loaded
only if its own `bfSize` actually covers `pixel_offset + 3*w*h`, the pixel stream is cut
off at the declared pixel count, and end-of-frame is derived from the declared count
instead of from "the last byte of the file happens to be the third byte of a pixel".
Before this, one file whose header over- or under-stated its size could be registered,
started loading, fail to reach its row count, and park the scaler permanently - which
looks like a black screen with only the OSD banner and a repeating `0x18`.

Simulation evidence (V): `tools/tests/run_gates.ps1` -> 4 passed, 0 failed.
The same bench against the frozen pre-v13 snapshot (`-WithOldRtl`) fails C2/C3/C4/C5,
including "pix_eov still fires exactly once <== the park bug".
Resource cost (V, from TD synthesis): LUT 17330 -> 17626 of 19600 (88.4% -> 89.9%),
DSP 9 -> 12 of 29. See the packing-limit note above before reading that as spare room.

Hardware evidence: none yet. That is what tomorrow is for.

## The design is at its packing limit  (V, read this before adding any logic)

TD numbers for this build: LUT 17626/19600 (89.93%), slices 9608 = 98.04%,
DSP 12/29, BRAM 47/64. The device is effectively full.

This is not theoretical. Re-expressing the gate's `declared_pixels * 3` as shift-and-add
saves two DSP blocks (12 -> 10) and TD synthesises it happily, but placement then aborts:

    PHY-9009 ERROR: Design's mslice number = 4917, exceeds the limit 4900.

So the saved DSPs come back as LUTs and the design no longer fits. That form was measured,
reverted, and the reason is recorded at `bmp_read.v:108`. Any new logic on board A has to
arrive with a matching removal - which is exactly the argument for putting the scaler and
the FFT on board B (see `docs/plan/20260920_dual_fpga_three_screen/01_current_plan/
02_resource_budget_v3.1.md`).

## The two clock domains have not been meeting timing for a while  (V)

Routed `lab_pro_timing.rpt`, comparing the Sep-18 v12.9 build (`td_project9`) with tonight's
v13.0 build (`td_project10`). Constrained period vs what the router actually achieved:

| clock | constrained | v12.9 achieved | v13.0 achieved | verdict |
|---|---|---|---|---|
| `sd_card_clk` | 10.0 ns (100 MHz) | 29.06 ns (34.4 MHz) | 35.59 ns (28.1 MHz) | violated before, violated now, 22% worse |
| `video_clk` | 40.0 ns (25 MHz) | 74.61 ns (13.4 MHz) | 78.12 ns (12.8 MHz) | violated before, violated now |
| `clk` (50 MHz input) | 20.0 ns | met (+14.5 ns slack) | met (+14.3 ns slack) | fine |

Read this carefully before blaming v13.0: `sd_card_clk` needed 29 ns and was run at 10 ns
**in the build that has been on the board for the last two weeks**. A domain whose worst
path is 3x its period passes or fails depending on temperature and voltage, and "sometimes
it shows the image, sometimes it parks at `0x18`" is precisely what that looks like. The
transient `0x18` that has been treated as an observation item is a candidate for being this.

What v13.0 did is make an already-failing domain 22% worse, because the gate's
`width*height -> *3 -> +offset -> compare` chain is a long combinational path sitting in
exactly that domain (`sd_card_bmp` is clocked by `sd_card_clk`, `top_tf_hdmi_audio.v:708`).

Two ways to pay for it, neither attempted tonight because both need their own evidence
first (rule 2):

1. Register the gate's result. `header_match` currently ripples through a multiplier and a
   32-bit compare in one cycle; latching `size_ok` when the header finishes capturing breaks
   the path in half. Needs a scan-FSM review, not a one-line edit.
2. Free logic so the router stops congesting: `sector_lut` table merging was already
   estimated at 600-1100 LUT (P2 in the 09-15 handover).

If tomorrow's run is flaky in a way the sim cannot explain, this is the first suspect, and
the test is cheap: re-flash `td_project\lab_pro_v12.9_pre_v13.bit` and see whether the
flakiness is identical. Same flakiness with a 29 ns path and with a 35 ns path means timing
is not the cause of that particular symptom.


## Step 0 - the two readings that decide everything else  (rule 5)

Take a photo of the HDMI screen and read the two low digits of the 7-seg display
(hexadecimal registered-image count) before touching any command.

| 7-seg | Screen | Reading |
|---|---|---|
| `00` | black, banner only | card has no playable file - go to "Card", RTL is not implicated |
| `>00` | black, banner only | files registered but none delivered - this is the defect v13.0 targets |
| `>00` | image visible | fixed; compare the count against the number of files on the card |

The distinction matters because the September investigation spent a whole round on the
render path while the real problem was upstream of it.

## Step 1 - flash

Preferred, from a terminal (it prints the bit's build time, then self-tests COM4 and stops
without changing what the screen shows):

    powershell -ExecutionPolicy Bypass -File C:\td_batch\lab_pro\tools\auto_demo.ps1 -SkipEmg

The double-click shortcut
`C:\Users\lwy\OneDrive\Desktop\FPGA嵌入式大赛\1-板子复活一键烧录.bat` does the same thing
but then sends `EMG1`, which puts the board into the Chinese emergency-banner mode and hides
the image playback being tested. If that is what was run, send `CLR` afterwards to return to
normal, otherwise step 0's screen reading is meaningless.

Both burn `C:\td_batch\lab_pro\td_project\lab_pro.bit`. Check the printed build time says
2026-09-20; if it does not, the v13.0 bit is not in place. Takes ~50 s, the screen goes
black during it, that is normal.

Two known traps (V):
- SRAM configuration, so every power cycle needs a re-flash.
- The script opens COM4 directly. If the console app is running, COM4 is held and step 3
  of the script reports `NO ACK` even though the flash itself succeeded.

Rollback bit: `td_project\lab_pro_v12.9_pre_v13.bit` (the pre-fix build). Copy it over
`lab_pro.bit` to return to last week's behaviour.


## Step 2 - card

Use the eight demo images that ship with the project, at card root, nothing else:

    C:\td_batch\lab_pro\tools\multires_demo\BMP0000..0007.BMP

They pass the official `bmp_check.py` 8/8 (V). Expected registered count after power-up
is `08`. If the count comes up short, run the official 640x480 set from
`HX4S20_Contest_202606\7_lab_ex_2026_nosoft\已解压_官方参考例程\lab_ex4_tf\doc\TF卡图片`
as a control - if the official images play and ours do not, the defect is in our card
content, not in the RTL.

The card content was pre-flighted against the v13.0 gate tonight (V), header by header:

| file | geometry | bfSize | 54 + 3*w*h | gate |
|---|---|---|---|---|
| BMP0000 | 640x480 | 921654 | 921654 | pass, exact |
| BMP0001 | 1280x720 | 2764854 | 2764854 | pass, exact |
| BMP0002 | 800x600 | 1440054 | 1440054 | pass, exact |
| BMP0003 | 400x800 | 960054 | 960054 | pass, exact |
| BMP0004 | 1024x768 | 2359350 | 2359350 | pass, exact |
| BMP0005 | 320x240 | 230454 | 230454 | pass, exact |
| BMP0006 | 640x200 | 384054 | 384054 | pass, exact |
| BMP0007 | 1280x360 | 1382454 | 1382454 | pass, exact |

All eight are 24bpp, uncompressed, `pixel_offset = 54`, and byte-exact, so none of them can
be rejected by the new size gate. That removes "is the test card valid?" from tomorrow's
question list: if the count is not `08`, the board is telling us something about the RTL or
the SD path, not about the files.


## Step 3 - serial readings, in this order

COM4 is reachable through the console API at `http://127.0.0.1:8765/api`; commands end in
`\n` (not `\r\n`) and the board answers in GB2312 (V).

    LIST?      -> "L <cur> <idx> <count>"   registered count, walk it every 5 s for 2 min
    WHY?       -> "W <a> <b> <c> <code>"    state_code triple + reason byte
    STAT?      -> "V2 <msgcnt> <dbg>"       dbg byte: bit7 scan_done bit5 src_done bit4 wr_done

Record `WHY?` at 60 s and at 5 min. The `0x18` code means bmp_read is idle with
`source_done=1, write_done=0`, i.e. the frame never received its 307200 words.

## What each outcome means

| Observation after flash | Conclusion | Next move |
|---|---|---|
| count `08`, image on screen, `WHY?` no longer `18` | v13.0 closed the defect | merge `develop` to `main`, tag the hardware anchor |
| count `08`, still `0x18` | shortfall is not header-driven | add the delivered-word telemetry on `WHY?` bits 1:0 before touching anything else |
| count lower than the file count | scan/registration still rejecting files | `LIST?` + compare against `bmp_check.py` on the same card |
| count `00` | card or SD path | step 2 control test with the official images |

## Known open items, deliberately not touched this round  (?)

None of these are proven defects; they are places where the design can lose a frame
silently, and each needs its own evidence before it gets a fix.

1. `top_tf_hdmi_audio.v:705,718` - `sc_fd` (scaler frame_done) is wired and never
   consumed. `sd_card_bmp.v:351` leaves the low 2 bits of the `WHY?` state byte unused.
   Routing a delivered-word counter or `sc_fd` into those two bits ends the guessing in
   the table above. Not done yet because it spans three modules with no simulation
   coverage.
2. `frame_read_write.v:101,153` - both `full_flag` outputs are unconnected, so a FIFO
   overflow on either side is invisible.
3. `top_tf_hdmi_audio.v:185` - `SCAN_MAX_SECTOR` is 131071 while the data area starts at
   sector 65536; a cold scan can walk a long empty tail.
4. `top_tf_hdmi_audio.v` reports ~30 `HDL-7225 CRITICAL-WARNING: ... is already
   implicitly declared` from TD. Implicit nets are exactly how a port ends up silently
   unconnected; worth one dedicated cleanup pass with the build log as the checklist.

Rule 2 still applies: name the failing layer and show the evidence before patching it.
Six versions (b17..b23) were spent on SDRAM arbitration for a defect that lived in the
header gate.
