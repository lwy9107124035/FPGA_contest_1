# Board pin notes - EG4S20BG256 (U70)

Source: `HX4S20_Contest_202606\3_原理图\开发板原理图\2_FPGA.pdf`, cross-checked against
`user_source/constraints_source/pin.adc` and the official LED lab
(`2_Example\DEMO实验介绍\2_按键控制LED灯实验.pdf`).

| Function | Net | U70 pin | Level | How this was established |
|---|---|---|---|---|
| system clock | `clk` | R7 | 50 MHz | `pin.adc:20`, and `timing.sdc` `create_clock -period 20` |
| board reset | `rst_n` | A2 | active low, PULLUP | `pin.adc:23` |
| LED0 | `NLLED0` | A4 | write 1 = lit | `2_FPGA.pdf` net/pin list; polarity from the official lab (`led=4'b1111` -> all lit) |
| LED1 | `NLLED1` | A3 | write 1 = lit | as above |
| LED2 | `NLLED2` | C10 | write 1 = lit | as above |
| LED3 | `NLLED3` | B12 | write 1 = lit | as above |
| KEY1..KEY4 | `NLKEY01..04` | A2 / B2 / B1 / C1 | idle 0, pressed 1 | board-tested, see below |

## Confidence, stated honestly

The LED and key pins were read out of the PDF's text layer, where the FPGA ball names and
net names come out as adjacent tokens (`PIU70A4 / NLLED0`). That extraction is corroborated
by the keys: it puts `NLKEY01/02/03/04` on A2/B2/B1/C1, and the design's own `pin.adc`
assigns `rst_n = A2` and `key1 = B2`. So the schematic's NLKEY01 ball is used as reset,
and the code signal `key1` is the ball under silkscreen KEY2 - the one-place offset between
code signal names and silk labels that was already noticed by hand on this board.

The LEDs have not been driven on hardware yet; the first D1 session is what confirms them.

Two facts worth carrying into D1:

1. `pin.adc` has no LED port at all, so A4/A3/C10/B12 are free - a D1 blink design can
   claim them without touching the player's constraints.
2. The official lab drives LEDs on `key==0` meaning pressed. This board is the other way
   around (idle 0, pressed 1, PULLUP). Trust the board, not the lab text.

