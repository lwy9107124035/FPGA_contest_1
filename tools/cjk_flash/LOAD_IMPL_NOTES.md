# LOAD 固件实现笔记 (uart_loader.v + flash_pp.v) — 固件子代理，v2 修订 2026-09-05

交付位置：
- `C:\td_batch\lab_pro\user_source\hdl_source\cjk_flash\flash_pp.v`
- `C:\td_batch\lab_pro\user_source\hdl_source\cjk_flash\uart_loader.v`
- 本文件 (`tools\cjk_flash\LOAD_IMPL_NOTES.md`)

范围：协议 §1~§4、§7（固件侧）。未修改任何既有文件；未运行 TD、未连板。
**v2 修订：按主线 2026-09-05 勘误裁决落地（见 §6），CRC/残帧/尾地址/CERR 时限四项全部生效。**

---

## 1. flash_pp.v 端口表

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| clk50 | in | 1 | 50MHz 板晶振域。**勿接 video_clk(25.175M)**，否则 SCLK 只有 6.25MHz。 |
| I_rst | in | 1 | 高有效异步复位，接 `rst_all`。 |
| cmd_i | in | 2 | 1 拍脉冲：`1`=64K 块擦(0xD8) `2`=页编程(0x02, 256B 取 pbuf) `3`=普通读(0x03, 32B→pp_rd_q) `0`=空闲。busy 期间到来被忽略（不排队）。 |
| cmd_addr_i | in | 24 | 起始字节地址；页编程时 loader 保证 256B 页对齐。 |
| pp_buf_we / pp_buf_widx / pp_buf_wdata | in | 1/8/8 | pbuf 灌页口（每拍 ≤1 写）。 |
| pp_busy | out | 1 | 事务进行中。 |
| pp_done | out | 1 | 1 拍脉冲，本次 op 结束。 |
| pp_to | out | 1 | 与 pp_done 同拍为 1 = WIP 轮询兜底超时。 |
| pp_rd_q | out | 256 | cmd=3 读回，`[255:248]`=cmd_addr 起第 0 字节（左移灌入）。 |
| flash_cs_n / flash_sck / flash_mosi | out | 1 | P8 / M9 / N8，全寄存器输出。 |
| flash_miso | in | 1 | P7，一级跟采样（准静态）。 |

WREN(0x06) 在擦/写命令前自动插入；RDSR(0x05) 轮询 WIP 自动完成；READ 不插 WREN。
24bit 地址大端先行（[23:16]→[15:8]→[7:0]）。SCLK=12.5MHz 高2低2 模式0。

## 2. uart_loader.v 端口表

**无 parameter**（v2 起）：镜像尺寸/尾地址不硬编码，尾抽验按实收字节动态算。

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| clk50, I_rst | in | 1 | clk50 域、高有效 rst_all。 |
| loader_start | in | 1 | msg_ink "LOAD" 分类命中 1 拍脉冲。 |
| rx_byte / rx_vld | in | 8/1 | top 在 `loader_active=1` 期间路由的字节流。 |
| loader_active | out | 1 | 会话电平：start 接受→1；DONE/BAD/TIMEOUT/ABORT 行发完→0。 |
| ld_tx_start / ld_tx_byte | out | 1/8 | 与 msg_ink→uart_tx 同风格：1 拍 start + 等 done。 |
| ld_tx_done | in | 1 | 上一字节发完脉冲。 |
| fp_cmd / fp_addr | out | 2/24 | flash_pp 命令脉冲 + 地址。 |
| fp_buf_we / fp_buf_widx / fp_buf_wdata | out | 1/8/8 | payload 到达拍直写 pbuf（≤1 写/拍）。 |
| fp_busy / fp_done / fp_to | in | 1 | flash_pp 状态。 |
| fp_rd_q | in | 256 | 抽验读回（done 拍取用）。 |

回执行（文本行+CRLF）：`RDY`、`ERASED`、`CERR`、`ABORT`、`P40`、`DONE`、`BAD`、`TIMEOUT`。

## 3. 状态机摘要

### 3.1 flash_pp（6 态）
`S_IDLE → S_SETUP(CS# 建立 6 拍) → S_RUN(逐 bit 4 相位) → S_GAP(末 bit 后 SCLK 先低 3 拍再抬 CS#，15 拍段决策) → {回 SETUP 起下段 | S_POLLG(轮询间隙 32 拍) | S_END(CS# 高 9 拍→done 脉冲)}`。
分段：seg0=WREN、seg1=主事务（擦 4B；写 260B）、seg2=RDSR(2B 循环至 WIP=0)；READ 仅一段 36B。
超时：页编程 100ms、块擦 4.5s（>§4 自述 max 3s，PC 30s ERASED 窗口内最坏 5×4.5=22.5s 安全）。
防死态：全状态有 tick/done/超时出口，case 全 default→S_IDLE。

### 3.2 uart_loader（并发段 A/B/B2/C，同一 always）
**A. 帧收集机** `R_F0(A5)→R_F1(01)→R_L1→R_L0(LEN)→R_PAY→R_C1→R_C0`：
- **任意 0<LEN≤256 均接受**（R_PAY 在 `fix+1==LEN` 结束 → 残帧 LEN=128 天然兼容；LEN=0 直接进 CRC 态=结束帧；LEN>256 判 P_BAD 防越界）。
- 每 payload 字节：1 次 pbuf 写 + CRC 更新 + `arr_off++` + first32 窗口抄写（arr_off<32）+ **last32 滚动寄存器左移插入**（普通 256bit 寄存器，非数组）。
- C0 判 CRC：对 → pend=P_DATA/P_END；错 → pend=P_BAD 并 `arr_off -= LEN` 回滚（first32 窗口对齐靠回滚复原；last32 靠 PC 重发同帧再移入自动复原）。非帧头字节静默丢弃。
- 帧间 10s（29bit=5e8）计表只在收集期跑，收任意字节清零。

**B. 文本行引擎**：msg_ink 同手法的 lreq/lbusy/lidx 三段；行内容与长度是 `ldb/lnl` 纯组合函数。

**B2. CERR 快速通道（v2 新增，裁决4）**：`pend==P_BAD` 且行引擎空闲且 `st∈{ST_PPW,ST_V0W,ST_V1W}` 时**不等 fp_done** 立即请 CERR 行（行引擎与编排态解耦），并 cerr_n++；凑满 3 连错置 `abort_pend`。ST_COLLECT 头部优先补发 ABORT 行（ABORT 无 2ms 硬窗）→ ST_LINE→ST_EXIT。
**CERR ≤2ms 时序审计**：C0 坏判 → pend 打拍 → B2 请求 → 引擎起发，固定延迟 ~4 clk = 0.08us；唯一可能被拖长的场景是行引擎正忙（上一条 P40/CERR 在发）：最长一条行 9 字节 ≈ 782us，仍 <2ms ✓。若 PPW 恰逢 fp_to 真超时，TIMEOUT 请求优先（fast-path 加了 `!(fp_done && fp_to)` 防抢线），会话以 TIMEOUT 收尾，语义更强 ✓。

**C. 会话编排机**（11 态）：`ST_IDLE(start:清场+RDY) → ST_LINE → ST_ERASE/ST_ERAW ×5(0x00000..0x40000 串行) → ST_LINE(ERASED) → ST_COLLECT → {P_DATA: PP(addr=goff)+len_c 锁存 | P_BAD: CERR(3连错→ABORT) | P_END: ST_V0/V0W 读 0x00000 比 first32 → ST_V1/V1W 读 **(goff-32)** 比 last32 → DONE/BAD} → ST_EXIT`。每 40 个完成帧插 P40。fp_to 一律 TIMEOUT 退会话。
10s 超时抢占加了 `!lreq && pend!=P_BAD` 门（v2）：保证 B2 的 CERR 与 TIMEOUT 抢占不同拍互踩；抢占后 ST_LINE 派发 → ST_EXIT，无死锁路径。

## 4. CRC16 实现说明（**CRC init 裁决=0x0000（向量权威）**）

`function [15:0] crc_upd(input [15:0] crc_in, input [7:0] b)`：组合函数逐 bit 展开
（`bit = crc[15] ^ b[7-k]`；`crc = {crc[14:0],1'b0} ^ (bit ? 16'h1021 : 0)`），无查表，
每字节一拍算完（8 级 XOR 链 @50MHz 无压力）。覆盖 byte0..payload 末；0xA5 本身喂入；
收到的末 2 字节拼 `{crc_rx[7:0], 当前字节}` 与在线值整字比较。

**v2 按主线裁决：初值 = 16'd0（帧起点 `crc_upd(16'h0000, A5)`，复位值同步为 0）。**
依据：§5 强制自检向量 CRC16-CCITT("123456789") == 0x31C3 在数学上仅 init=0x0000
（即 CRC-16/XMODEM 变体：poly 1021、init 0、不反转）成立；0xFFFF 初值同参数得 0x29B1。
固件 Python 等价模型复核：init=0 → 0x31C3 ✓；init=FFFF → 0x29B1 ✓。
参考值（供 PC 对账）：空 payload 结束帧 `A5 01 00 00` 的 CRC = **0x6103**；
`A5 01 00 80` + 128×0x00 的 CRC = 0xB676 ⊕ 按 PC 实际末帧数据计算为准。

## 5. "一拍一口"铁律逐条自查（msg_ink v3c 教训）

工程唯一动态下标数组 = flash_pp 的 `pbuf[0:255]`。

1. **每拍 ≤1 读**：全文件 pbuf 读表达式仅 1 处：`S_RUN/ph0` 的 `if (pf_now) hold <= pbuf[pf_idx];`（grep 实证）。
2. **每拍 ≤1 写**：写口仅 1 处（`pp_buf_we`；uart_rx 每拍 ≤1 字节，天然成立）。
3. **预取—使用对齐**：SPI 移出唯一消费点在字节边界（bit7/ph3 `sh_out <= nxt_b`），`nxt_b` 只从普通寄存器 `hold` 取值，绝不直接索引 pbuf；预取点提前 **8 拍**（同字节 bit6/ph0），比 msg_ink 的 1 拍余量宽 8 倍——异步 mux/同步 BRAM(1拍)/串行化 2 拍口三种推断全部位精确对齐。
4. **窗口覆盖证明**：PP 主段数据字节 0..255 对应 tb=4..259；预取 tb∈[3,258] 读 `pbuf[tb-3]`= 下一发送字节，一次不漏不多；tb=258 预取 pbuf[255]，此后 pbuf 零访问（WIP 轮询不碰）。
5. **读写同拍共存**：即便重叠也仅构成 1R1W；且实际永不重叠（下条带宽论证）。
6. **uart_loader 侧零动态数组**：无 lbuf、无 262B 组帧数组（§4 该句为"即可"非强制）；first32/last32 是 256bit 普通寄存器（case 写使能/整字移位），整字 `==` 比较零读口。

**带宽裕量**：115200 字节周期 86.8us；PP"移位读 pbuf"段 = 260B×32×20ns≈166us（含 WREN/间隙 ≤~220us）；下一帧首个 payload 字节最早在本帧末字节后 5×86.8=434us 到达（A5/01/LEN16/LEN0 之后）→ 读段与写口物理不重叠，裕量 ≥214us。契约边界：PC 违反 §3 连续发超短帧且页编程撞满 3ms 时裕量才可能被吃穿，届时结束抽验 BAD 兜底。

## 6. 主线勘误裁决落地记录（v2，2026-09-05）

| 裁决 | 原文错误 | 固件现状 |
|---|---|---|
| 1. CRC 初值 | §3 写 0xFFFF，与 §5 自检向量 0x31C3 矛盾 | **裁决=0x0000（向量权威）**。已改：帧起点 `crc_upd(16'd0,A5)`、复位值 0；逐 bit 多项式/不反转不变 |
| 2. 帧拆分 | §5 "1105×256 整除"（1105×256=282880≠282752） | 实际 1104×256+128B 残帧。RX 接受任意 0<LEN≤256，**已实证兼容**（R_PAY 按 `fix+1==LEN` 收口），会话不会死在最后帧 |
| 3. 尾抽验地址 | §3 硬写 0x457E0（=284640，超镜像 1888B；282752−32=282720=0x45060） | **不硬编码**：v2 起删除 IMG_BYTES 参数与 TAILA 固定窗口，尾地址= `(goff-32)` 动态取自实际累计提交字节数；对比源改为滚动 `last32`（实收镜像末 32B）。282752B 镜像下自然等于 0x45060 |
| 4. CERR ≤2ms | 原文无时限；PC 每帧 4ms 观察窗 | v2 新增 B2 快速通道：C0 坏判后 ~0.1us 起发 CERR 行，即使编排机在页编程/抽验等待；最坏（P40 在发）~0.8ms，均 <2ms。ABORT 经 abort_pend 延后到页编程收尾补发 |

保留的实现期偏差：块擦 WIP 兜底 4.5s（协议 §4 自述 max 3s，100ms 会误杀正常擦除；页编程仍 100ms）。

## 7. 主线集成提醒（§6 归主线）

1. **跨时钟域**：现 top 的 uart_rx/msg_ink/uart_tx 全在 video_clk(25.175M)，本两模块在 clk50。loader_start 需脉冲/toggle 同步，rx 字节需跨域桥，tx 建议 clk50 独立例化 uart_tx `#(.CLK_HZ(50_000_000),.BAUD(115200))`（分频误差 0.005% 可忽略）+ pad mux。flash_pp 切勿接 video_clk（SCLK 变 6.25MHz）。
2. **loader_active 交接**：`LOAD\n` 的 `\n` 被 msg_ink 消费，loader 从下一字节看起无缝；会话退出后 msg_ink 的 llen=0（会话期看不到字节）。ABORT/TIMEOUT 后建议 PC 先发一个 `\n` 清残行。
3. **msg_ink 需新增 LOAD 分类**（现只回 ERR），在 v3c 快照寄存器上判，别再碰 lbuf。
4. 引脚：CS=P8、MOSI=N8(SDO)、MISO=P7(SDI)、SCLK=M9；WP#=P9、HOLD#=R9 顶层常数 1；勿与 MSPI boot FLASH 混淆。

## 8. 自查结论（v2 复核）

- 结构：两文件 begin/end、case/endcase、function/task 配平（逐 token 深度游走，负深度 0 次）；case 全 default；组合块全分支赋值，无锁存。
- 数组口：pbuf 全文 1 读 + 1 写语句（grep 实证）；uart_loader 零动态下标数组（tail32/TAILA/tsub/IMG_BYTES 已全部清除，grep 验证）。
- FSM：无死态；每个 wait 有 tick/done/超时/复位出口；B2 快速通道与 10s 抢占、TIMEOUT 优先序经互斥门排雷（`!lbusy && !lreq && !(fp_done&&fp_to)` vs `pend!=P_BAD`）。
- CRC 语义：与 Python 等价模型逐位一致；0x31C3 自检向量在 init=0 下通过（见 §4）。
