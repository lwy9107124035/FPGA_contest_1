# OSD 任意中文上屏 · 模块接口契约 v1（2026-09-05 主线定稿）

任何子包偏离本契约即返工。三个工作包：
- WP-B：osd_banner.v 行缓存 22 槽点阵化改造（子代理）
- WP-C：msg_ink.v 引擎 GB2312 配对序列化（子代理）
- WP-A：顶层接线 + SPI 总线复用 + .al 登记（主线自己做）

## 0. 时钟域
- osd_banner / msg_ink 全部在 `video_clk = 25.175MHz`，复位 `rst` 高有效、异步复位同步释放风格与现状一致。
- glyph_fetch / glyph_xcd 的 clk50 侧在 `clk = 50MHz`（顶层晶振）。跨域只允许走 glyph_xcd。

## 1. msg_ink -> osd_banner（消息行写口，替换旧的 we/waddr[6:0]/wdata[7:0] 中写行缓存的那一路）
```verilog
input  wire        msg_we,      // 1 拍写使能
input  wire [4:0]  msg_wslot,   // 槽号 0..21（行宽 22 个全角位 = 352px，与旧 44x8px 同宽）
input  wire [15:0] msg_wcode,   // 槽内容编码，见 §2
input  wire        msg_commit,  // 本条消息全部槽写完后 1 拍 -> 触发点阵刷新
```
### 2. msg_wcode 编码
- `16'h0000` = 空（该槽不显示任何东西）
- `[15:8] == 8'h00 且 [7:0] != 0` = 半角 ASCII：`{8'h00, 字节}`，字模用 osd 内置 8x16 ROM，显示在槽左半 8px，右半空白
- `[15:8] >= 8'hA1 且 [7:0] >= 8'hA1` = 全角汉字，GB2312 双字节原样 {高,低}
- 其它值 = 按空处理（防御性）
### 3. msg_ink 配对规则（WP-C）
从快照 payload 字节序列 b[0..paylen-1] 造码流：b[i]>=0xA1 且 i+1<paylen 时取 {b[i],b[i+1]} 占 1 槽、i+=2；否则 {8'h00,b[i]} 占 1 槽、i+=1。最多 22 槽，多余丢弃；不足 22 槽的剩余槽必须在 commit 前写 16'h0000（旧字符必须被清掉！）。最后 1 拍 msg_commit。
### 4. FLASH 取字地址（WP-B 点阵刷新状态机用）
```
qu = hi - 0xA1 (0..86),  wei = lo - 0xA1 (0..93)
glyph_addr = ((qu*94) + wei) * 32        // 20bit，字库镜像烧在 FLASH 偏移 0
```
### 5. osd_banner <-> glyph_xcd（WP-B 内部例化点在 osd？ 否——见 WP-A，xcd 例化在顶层）
osd_banner 只暴露 video 侧 5 根 + 1 抑制位：
```verilog
output wire         xcd_req_v,     // 1 拍
output wire [19:0]  xcd_addr_v,
input  wire         xcd_new_v,     // 1 拍：out_v 新到
input  wire [255:0] xcd_out_v,
input  wire         xcd_busy_v,
input  wire         loader_inhibit // 顶层 = loader_active（OTA 字库烧写中，禁止新请求）
```
行为：msg_commit 置 dirty；点阵刷新 FSM 在 dirty 时逐槽扫描：槽码为全角且点阵缓存 checksum 变化则经 xcd 取字，`new_v` 拍把 xcd_out_v 的 16 行（[255:240]=行0…[15:0]=行15，bit15=最左像素）写入该槽点阵 BRAM。`busy_v`/inhibit 期间挂起等待，不许并发第二请求（xcd 会丢）。
### 6. 点阵 BRAM（WP-B）
`glyph_ram: 22 槽 x 16 行 x 16bit`（=352 词）。写口=刷新 FSM；读口=渲染（{slot,行号}）。1R1W，TD 会抽 RAM——综合后必须查 `HDL-1007 extracting RAM` 日志。渲染侧读到什么画什么，不做 SPI 等待（缓存没新到就画旧点阵，消息更新晚 1 帧无感）。
### 7. 不许回退的东西（WP-B 验收底线）
- LINE0 英文横幅、EMG1/2/3 三种告警中文横幅、红色 TEXT 色（emg_mode 时 24'hFF3030）、底行 ALL CLEAR——这些现在就在屏上，改完必须在。
- 旧固定字模 cjk16() 448-case ROM：允许保留继续给 EMG 固定横幅用，但新 MSG 通道一律走 §5/§6 的 FLASH 路径。半角 ASCII 行不受影响（继续内置 ROM）。
### 8. 命令字（WP-C 全部保留）
MSG/EMG[1-3]/CLR/VOL 0-9/NEXT/AUTO/LOAD/STAT? 一个都不能少，ack 格式不变（OK/ERR/V2）。CLR = 22 槽写 0 + commit。
### 9. 顶层 SPI 总线复用（WP-A 主线专属，两个子包不用管）
`flash_pp`（OTA 装载）与 `glyph_fetch`（取字）**共用 W25Q64 的 P8/M9/P7/N8**。顶层改：
```verilog
wire pp_cs, pp_sck, pp_mosi, gf_cs, gf_sck, gf_mosi;
// u_flash_pp 的 .flash_cs_n/.flash_sck/.flash_mosi 接到 pp_*；
// u_glyph_fetch 的同名口接到 gf_*；两者的 flash_miso 都接 c_flash_miso。
assign c_flash_cs   = loader_active ? pp_cs   : gf_cs;
assign c_flash_sck  = loader_active ? pp_sck  : gf_sck;
assign c_flash_mosi = loader_active ? pp_mosi : gf_mosi;
```
两侧空闲时 cs 均为高，切换无毛刺；osd 侧 `loader_inhibit` 保证装载期间不再发起新取字。
## 10. 主线裁决记录
- EMG 预设 ASCII：paylen 26→**19**（"EMERGENCY BROADCAST"），PB 内容未动。
- 半角容量 22 槽（44→22）为契约设计后果，接受。
- WP-B 交付的 osd_banner 例化片段必须与新 msg_ink 端口（msg_we/msg_wslot[4:0]/msg_wcode[15:0]/msg_commit）一致，主线在 WP-A 统一接线。
- WP-B 只改 `osd_banner.v`；WP-C 只改 `msg_ink.v`。
- 都不许动顶层、不许跑 TD 综合、不许改 pin.adc。
- 各自在文件头加一段"集成给主线的话"注释（改了哪些端口、顶层要连什么）。
- TD 铁律：一个数组同一拍只许一个读口；多读者就复制；case 带 default；begin/end 配平。
