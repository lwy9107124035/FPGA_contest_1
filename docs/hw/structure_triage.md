# Structural audit triage - the 31 unconnected outputs in our own RTL

Produced by `tools/lint_ports.py`. The gate is deliberately RED today: `gate_pass=false`
until every finding below carries a disposition that a human has read.

`ACCEPT` = intentional, no action. `FIX-OBSERVE` = must become observable in simulation
before it can be accepted. `FIX-DECIDE` = a functional decision is owed, and each one is
a question the September investigation could not answer because the signal went nowhere.

| # | where | port | disposition | why |
|---|---|---|---|---|
| 1 | `SD/frame_read_write.v:92` | `valid` | **ACCEPT** | vendor FIFO status output, unused by design |
| 2 | `SD/frame_read_write.v:92` | `afull` | **ACCEPT** | almost-full flag; the design drains on usedw thresholds instead |
| 3 | `SD/frame_read_write.v:92` | `aempty` | **ACCEPT** | almost-empty flag, same reason |
| 4 | `SD/frame_read_write.v:100` | `empty_flag` | **ACCEPT** | the FSM uses its own rdusedw/empty logic; the flag is redundant here. |
| 5 | `SD/frame_read_write.v:101` | `full_flag` | **FIX-OBSERVE** | a write-side or read-side FIFO overflow is currently invisible. Assert in simulation that it never fires; on hardware it is the first thing to wire into WHY? bits 1:0. |
| 6 | `SD/frame_read_write.v:102` | `wrusedw` | **FIX-OBSERVE** | water-level of the write FIFO is not visible anywhere. tb_v103_fw already samples rdusedw_max; do the same for the write side and assert it never saturates. |
| 7 | `SD/frame_read_write.v:144` | `valid` | **ACCEPT** | vendor FIFO status output, unused by design |
| 8 | `SD/frame_read_write.v:144` | `afull` | **ACCEPT** | almost-full flag; the design drains on usedw thresholds instead |
| 9 | `SD/frame_read_write.v:144` | `aempty` | **ACCEPT** | almost-empty flag, same reason |
| 10 | `SD/frame_read_write.v:152` | `empty_flag` | **ACCEPT** | the FSM uses its own rdusedw/empty logic; the flag is redundant here. |
| 11 | `SD/frame_read_write.v:153` | `full_flag` | **FIX-OBSERVE** | a write-side or read-side FIFO overflow is currently invisible. Assert in simulation that it never fires; on hardware it is the first thing to wire into WHY? bits 1:0. |
| 12 | `SD/frame_read_write.v:155` | `rdusedw` | **ACCEPT** | the read-side copy is already routed to frame_fifo_write as a port. |
| 13 | `SD/sd_card_bmp.v:1193` | `scan_found_total` | **FIX-DECIDE** | the registered-image count. The 7-seg shows img_found_count instead; pick one source of truth or this drifts. |
| 14 | `SD/sd_card_bmp.v:1238` | `sd_sec_write_data_req` | **ACCEPT** | the player never writes to the card |
| 15 | `SD/sd_card_bmp.v:1239` | `sd_sec_write_end` | **ACCEPT** | same |
| 16 | `SD/video_timing_data.v:80` | `rgb_r` | **ACCEPT** | colour-bar source unused while playing BMP |
| 17 | `SD/video_timing_data.v:81` | `rgb_g` | **ACCEPT** | as above |
| 18 | `SD/video_timing_data.v:82` | `rgb_b` | **ACCEPT** | as above |
| 19 | `link/dc3_link.v:245` | `wfill` | **ACCEPT** | READY is generated from the read-side view; wfill is kept for the overflow assertion only |
| 20 | `top_tf_hdmi_audio.v:285` | `hs_r` | **ACCEPT** | sync passthrough from video_delay, unused |
| 21 | `top_tf_hdmi_audio.v:525` | `busy` | **ACCEPT** | UART/glyph busy not waited on; TX is rate-limited elsewhere |
| 22 | `top_tf_hdmi_audio.v:580` | `busy` | **ACCEPT** | UART/glyph busy not waited on; TX is rate-limited elsewhere |
| 23 | `top_tf_hdmi_audio.v:666` | `glyph_ready_v` | **ACCEPT** | loader handshake consumed via a different path |
| 24 | `top_tf_hdmi_audio.v:669` | `out_addr_v` | **ACCEPT** | as above |
| 25 | `top_tf_hdmi_audio.v:670` | `drop_err_v` | **FIX-OBSERVE** | an explicit error output from the glyph loader is thrown away. If it ever fires, the Chinese OSD silently mis-renders and nothing reports it. |
| 26 | `top_tf_hdmi_audio.v:718` | `frame_done` | **FIX-DECIDE** | the scaler's commit pulse. Nothing consumes it, so 'the scaler finished a frame' is not a fact anywhere in the design. This is the signal that would have separated the September hypotheses in one measurement. |
| 27 | `top_tf_hdmi_audio.v:741` | `read_finish` | **FIX-DECIDE** | the read side's finish. The write side has write_finish and it gates the frame commit; the read side's counterpart is simply dropped, so a stalled display read is undetectable. |
| 28 | `top_tf_hdmi_audio.v:831` | `O_edid_read_valid` | **ACCEPT** | EDID is not read; timing is fixed |
| 29 | `top_tf_hdmi_audio.v:832` | `O_edid_read_data` | **ACCEPT** | same |
| 30 | `top_tf_hdmi_audio.v:838` | `O_axis_s_ready` | **ACCEPT** | AXI-Stream path unused |
| 31 | `top_tf_hdmi_audio.v:847` | `O_video_locked` | **FIX-OBSERVE** | 'is the panel actually locked' - the single most useful bit when the screen is black, and it is discarded. |

Totals: ACCEPT=23, FIX-DECIDE=3, FIX-OBSERVE=5

## Why the rest of the counts are not on this page

- `width=7` - checked and **benign**: every one is a narrow source driving a wider input
  (the vendor FIFO's `usedw` is 9 bits for a 512-deep FIFO while `frame_fifo_write`
  declares a 10-bit input), so the connection zero-extends. The interesting direction -
  a wide source truncated into a narrow port - has zero hits.
- `bad_port=0` - no instantiation names a port the module does not have.
- `implicit=359` - TD's own HDL-7225 class. Not swept in one go: a mass edit of implicit
  nets changes behaviour the moment a name is misread, and there is no bench covering
  most of them. Ratcheted instead - the baseline in `structure_baseline.json` is a floor
  that may go down and must not go up.
- `unconnected_in=29` / `usage=53` - reviewed alongside the table above; tying a spare
  input to `1'b0` is normal, the list exists so each one is signed off rather than ignored.
