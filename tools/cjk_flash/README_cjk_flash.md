# CJK 字库上板载 SPI FLASH 方案 — 集成设计文档
（中文字库存 W25Q64 + 离线生成工具 + glyph_fetch/glyph_xcd，供主线会话集成 OSD 中文横幅）

**TL;DR**：宋体 16×16 全量 GB2312 字模做成标准 HZK16 镜像（282,752 B），烧到用户 FLASH
**W25Q64（U33）起始地址 0x000000**；FPGA 用 `glyph_fetch.v`（50MHz 域 SPI 主机，READ 0x03，
SCLK=12.5MHz，一次取 32B≈23µs）+ `glyph_xcd.v`（请求/完成握手 + 准静态 256bit 总线跨到
video_clk 域，无双口 RAM）；行缓存建议 **22 槽 × 16bit GB2312 码位（0x0000=空，高字节
0x00=半角 ASCII）**，点阵经场消隐预取写入 **显式同步读 BRAM 行缓存**，像素流水线只读
BRAM，彻底避开 TD "异步读数组被误推 RAM" 的坑。

---

## 1. 文件清单（全部新增，未改任何现有文件）

| 文件 | 作用 |
|---|---|
| `tools/cjk_flash/gen_hzk16.py` | 生成 `hzk16.bin`（标准 HZK16，含 a/b/c 三项自验） |
| `tools/cjk_flash/convert_font_image.py` | 拼接 W25Q64 可烧镜像 + 回读自检 + 清单文件 |
| `tools/cjk_flash/hzk16.bin` | 字库本体 282,752 B（已生成，自验 ALL PASS） |
| `tools/cjk_flash/w25q64_cjk_full.bin` | **推荐烧录件**：整片 8MiB，字库@0x000000，空白 0xFF |
| `tools/cjk_flash/w25q64_cjk_sector.bin` | 4KiB 扇区对齐子集 286,720 B（70 扇区） |
| `tools/cjk_flash/cjk_flash_manifest.txt` | 镜像尺寸/md5/布局速查（烧录工具核对用） |
| `user_source/hdl_source/cjk_flash/glyph_fetch.v` | W25Q64 SPI 主机（READ 命令取 32B 字模） |
| `user_source/hdl_source/cjk_flash/glyph_xcd.v` | clk50↔video_clk 字模跨时钟域桥（握手+准静态） |

复跑方法（无副作用，可反复执行）：
```
& C:\Users\lwy\miniconda3\envs\fpga_batch\python.exe C:\td_batch\lab_pro\tools\cjk_flash\gen_hzk16.py
& C:\Users\lwy\miniconda3\envs\fpga_batch\python.exe C:\td_batch\lab_pro\tools\cjk_flash\convert_font_image.py
& ... convert_font_image.py --check "台风预警"   # 对最终镜像做回读点阵预览
```

## 2. 字模格式与地址换算（软硬件三方必须严格一致）

- 布局：94 区 × 94 位 × 32 B = 282,752 B。GB2312 实际只有 87 区（实测解码成功恰 7445
  码位 = 682 符号 + 3755 一级 + 3008 二级，与国标吻合；qu=10..15、88..94 及区一 5 个
  空位为全 0 槽）。保留完整 94×94 布局是为了下述公式对任意码位成立、硬件无需限幅。
- 槽内格式：16 行 × 每行 2 字节，**高位字节在前**；每行 16bit 中 bit15=最左像素。
- 偏移：`off = ((qu-1)*94 + (wei-1)) * 32`，`qu = 码高字节-0xA0`，`wei = 码低字节-0xA0`。
  示例：台=0xCCA8→qu44 wei8→off=129,568（与 gen/convert 两个工具实测一致）。
- FPGA 侧 `glyph_data[255:0]`：bit[255:240]=第 0 行 … bit[15:0]=第 15 行；行 r =
  `glyph_data[(15-r)*16 +: 16]`，行内像素 c(0=最左)= `row16[15-c]`。

**Verilog 地址换算建议表达式**（乘 94 全部用移位加法，不依赖硬件乘法器，纯组合、
结果只在场消隐低速路径使用，时序无压力）：

```verilog
// slot16 = {hi,lo} = GB2312 双字节 (例 0xCCA8 "台"); 0x0000=空 不发起取模
wire [7:0]  qu   = slot16[15:8] - 8'hA0;      // 1..87
wire [7:0]  wei  = slot16[7:0]  - 8'hA0;      // 1..94
wire [13:0] q94  = ({6'd0,qu}<<6) + ({6'd0,qu}<<4) + ({6'd0,qu}<<3)
                 + ({6'd0,qu}<<2) + ({6'd0,qu}<<1);          // 64+16+8+4+2 = 94
wire [13:0] slot = q94 + {6'd0,wei} - 14'd95;                // = (qu-1)*94+(wei-1)
wire [19:0] gaddr = {slot, 5'd0};                             // *32, <= 282,720+... 注①
wire        cjk_ok = (qu >= 8'd1 && qu <= 8'd87 && wei >= 8'd1 && wei <= 8'd94);
```
注①：`{slot,5'd0}` 为 19bit，接到 20bit `glyph_addr` 高位天然补 0 即可（如
`{1'b0, slot, 5'd0}`）。`cjk_ok=0` 或槽位读出全 0 时建议渲染成空格（或自绘 "?" 豆腐块），
全 0xFF 表示 FLASH 没烧好——可作在线自检特征。

区划速查：qu 1..3 标点/数字/字母符号（含半角位）｜4..9 序号/拼音/图形符号｜
10..15 未定义｜**16..55 一级汉字（3755，按拼音）**｜**56..87 二级汉字（3008，按部首）**。

## 3. 镜像烧录步骤（主线负责，本会话未碰板）

W25Q64 是**用户 FLASH，不参与 FPGA 上电配置**（boot 走 MSPI 上的 W25Q16，别混淆），
所以不需要 TD bit 流拼接格式（.hdr+bin 级联那套只针对 MSPI 启动链），直接把
`w25q64_cjk_full.bin` 整片写入即可：

1. 打开安路 TD 自带烧写上位机（Programmer / Flash Programmer），JTAG 链上先识别 FPGA，
   再选择其后端 SPI FLASH，**器件必须选 W25Q64（8MiB）**，不要选成 boot 的 W25Q16。
2. 载入 `w25q64_cjk_full.bin`，起始偏移 0x000000，勾选擦除→编程→校验（verify）。
   （工具若只支持小文件：改烧 `w25q64_cjk_sector.bin`，同样基址 0x000000。）
3. 核对 `cjk_flash_manifest.txt` 里的 md5 与源文件一致。
4. 若板子 JTAG 无法经 FPGA 间接访问用户 FLASH（见第 10 节不确定点），备选：厂商 SVF
   脚本烧写，或后续加"UART→FPGA 软装载（Page Program 0x02）"通道——本方案模块只读，
   软装载不影响 glyph_fetch/glyph_xcd 的任何接口。
5. 上电软件验收见第 9 节。

## 4. 两个新模块的接口与实现要点

### 4.1 glyph_fetch.v（clk50 域）
| 端口 | 说明 |
|---|---|
| `clk` | **板晶振 50MHz**（顶层 `clk`），不要用 video_clk，否则 SCLK 不是 12.5M |
| `fetch_req` / `glyph_addr[19:0]` | 1 拍脉冲 + 字节地址（32B 对齐，已含 ×32） |
| `glyph_data[255:0]` / `fetch_done` / `busy` | 字模 / 完成 1 拍 / 忙（期间总线在变，禁止取用） |
| `flash_cs_n/sck/mosi`、`flash_miso` | P8/M9/N8 ←、P7 →（按任务书原理图口径：SDO=N8 为 FPGA→FLASH） |

- 命令 0x03 + 24bit 地址 + 32B 数据，**每拍都重发命令头**（不做突发）；全寄存器驱动
  引脚，组合逻辑只有一个带 default 的字节选择 mux，无 latch、无组合环。
- 模式 0：SCLK 空闲低、四分频高 2 低 2（12.5MHz）；MOSI 在上升沿前 1 拍更新，MISO
  在"上升沿后一拍"移位入（采样窗距 FLASH 输出翻转 ≥40ns，见文件头逐相位推导）。
- 一次事务 36B×32clk + 控制开销 ≈ **23µs**。
- `busy=1` 期间的 `fetch_req` 被忽略（排队/互锁由 glyph_xcd 负责）。

### 4.2 glyph_xcd.v（clk50 ↔ video_clk 双向桥）
- 请求方向：video 侧 `req_v`(1拍)+`addr_v` → 内部锁存 `addr_hold` 并翻转 `req_tgl`；
  clk50 侧两级同步+沿检测 → `fetch_req`/`fetch_addr` 驱动 glyph_fetch。
- 返回方向：`fetch_done` 翻转 `done_tgl`；video 侧两级同步+沿检测 → `new_v`(1拍)，
  同沿把 256bit 准静态总线锁进 `out_v`，`glyph_ready_v` 置 1、`busy_v` 清 0。
- **互锁**：`busy_v=1` 期间新 `req_v` 丢弃并置粘滞 `drop_err_v`；允许"done 同拍接新
  请求"（每字省 1 拍）。`pend50` 只是兜底，正常永不触发。
- 为什么不上双口 RAM / 两拍握手够用：见 4.2 文件头"跨域时序论证"4 条——核心是
  *done_tgl 翻转沿距总线冻结已 ≥220ns*、*video 侧采样点距 done 沿又有 2~3 拍同步*、
  *下一次总线翻转距采样 ≥ 数 µs*，256bit 全部是"恒定期很长的寄存器输出"，属标准
  准静态跨域范式；控制位才是真异步信号，走正规同步器。
- 两侧 `rst_n` 请接同一 `~rst_all`（同源释放）；即便一侧单独复位也只会产生一次良性
  `new_v`，不死锁。

## 5. 顶层集成点清单（主线会话执行）

1. **top 新增 6 个端口**（当前 `pin.adc` 中 P7/P8/P9/M9/N8/R9 均未占用，实查无冲突）：
   `c_flash_cs(P8,O)  c_flash_sck(M9,O)  c_flash_mosi(N8,O)  c_flash_miso(P7,I)
    c_flash_wp(P9,O=1'b1)  c_flash_hold(R9,O=1'b1)`（WP#/HOLD# 顶层常数拉高即可）。
2. **pin.adc 追加**（沿用现有 `set_pin_assignment` 语法）：
   ```
   set_pin_assignment	{ c_flash_cs }	{ LOCATION = P8; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = NONE; }
   set_pin_assignment	{ c_flash_sck }	{ LOCATION = M9; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = NONE; }
   set_pin_assignment	{ c_flash_mosi }	{ LOCATION = N8; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = NONE; }
   set_pin_assignment	{ c_flash_miso }	{ LOCATION = P7; IOSTANDARD = LVCMOS33; PULLTYPE = NONE; }
   set_pin_assignment	{ c_flash_wp }	{ LOCATION = P9; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = NONE; }
   set_pin_assignment	{ c_flash_hold }	{ LOCATION = R9; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = NONE; }
   ```
3. **例化**（骨架在 glyph_xcd.v 文件头已给全）：`glyph_fetch`+`glyph_xcd.clk50侧` 挂
   `clk/~rst_all`；`glyph_xcd.vclk侧` 挂 `video_clk/~rst_all`。
4. **TD 工程**：把 `user_source/hdl_source/cjk_flash/*.v` 加入 `lab_pro.al` 源文件列表
   （GUI 添加即可；`run.tcl`/`syn_run.py` 无需动，它们只 open_project）。
5. **SDC 建议**（`timing.sdc` 由主线改）：本方案 clk↔video_clk 之间只存在 glyph_xcd
   内部经论证的同步/准静态路径，可加一组假路径消除报告噪音：
   ```
   set_false_path -from [get_clocks {clk}] -to [get_clocks {video_clk}]
   set_false_path -from [get_clocks {video_clk}] -to [get_clocks {clk}]
   ```
   两向都指跨 PLL 输出的路径，不影响 `clk→video_pll` 本体的 derive 分析；如担心范围
   过大，可先不加、只看报告再决定。

## 6. 横幅行缓存（msg_ink v4）——推荐方案

**推荐：每行 22 槽 × 16bit GB2312 码位；`0x0000`=空位；`高字节=0x00、低字节=ASCII`
=半角字符；其余=全角汉字。** 即任务书两个候选里选"22 槽汉字流"并把 ASCII 编码规则
并入槽值，**不建议** 44×ASCII 字节流或"0=ASCII 非0=汉字"的 22×8bit 混排。理由：

1. **一槽=一物理格**：CJK 格 32px（16×2 放大）、ASCII 占同一格居中（右半留空）。
   渲染器 x→格号 = `x/32`，纯移位；"0=ASCII 非0=汉字"的 22 槽混排会产生 16px/32px
   两种推进宽度，x 位置变成逐格累加链，正是 TD 组合爆炸高发的形态，否决。
2. **寄存器成本与现状完全相同**：22×16=352bit，和现行 `line1f` 的 352bit 平铺向量
   一模一样，继续用**已趟过坑的常数下标展平写法**（for 循环+常量 part-select，
   见 osd_banner.v v2b 注释，绝不让 TD 见到异步读数组）。
3. **msg_ink 解析改动最小**：`MSG <文本>` 协议不变，PC 串口助手用 GBK/GB2312 码
   直发即可（中文 Windows 终端默认就是）；收集规则改一条：字节 ≥0xA1 且 ≤0xF7 →
   暂存为高字节，等下一字节凑成槽（低字节 <0xA1 视为脏数据丢弃重同步）；字节 <0x80
   → 槽值 `{8'h00, ascii}`（大写化规则只对 ASCII 保留，现行 upc() 会把 ≥0x80 全打成
   空格，**必须绕开**，这是集成时最容易踩的一处）。
4. 密度：中文 20 字/行×2 行=40 字/屏，应急标语足够；纯英文横幅密度减半是接受的
   代价（要保 40 英文字符需再引入 ASCII 双压模式，v4 不做，接口留得下）。
5. 现行 `EMG_P0..P2` 的 gid 预置短语表直接换成 GB2312 码对表（如 "台"→`16'hCCA8`），
   `emg_sel` 行为不变，中文全部走 FLASH 通道；`cjk_font16.vh` 25 字内嵌 ROM 可退役
   （也可留作 FLASH 失效时的降级备份，看综合面积取舍）。

## 7. 渲染流水线与"防组合爆炸"（主线已踩坑：TD HDL-1007 异步读数组误推 RAM 出乱码）

字模进入显示路径的完整流水线（全部在 video 域除标注外）：

```
行缓存22槽 --(场消隐逐槽: gaddr换算 §2)--> glyph_xcd.req_v --> [clk50] glyph_fetch --> FLASH
new_v 拍: out_v(256b) --16拍拆解--> 行点阵BRAM[cell][row16]  --像素时钟同步读--> 位选择 --> OSD像素
```

**预取调度（场消隐状态机）**：`vs` 上升沿触发，槽游标 0..21 轮询两行缓存：槽值变化才
取（带 dirty 位图可再省，v4 可不做）；每槽流程 = `req_v` → 等 `new_v`（≈23µs）→ 把
`out_v` 按 `(15-r)*16+:16` **常量下标**分 16 拍写 BRAM。预算：22 槽 × ~23.2µs ≈ 512µs
< 场消隐 45 行 × 31.78µs ≈ 1430µs，余量近 3 倍；即使 44 槽全 dirty ≈ 1.02ms 也放得下。
`busy_v` 天然反压，永不欠载；未刷到的槽显示上一帧内容（应急场景可接受的"渐进刷新"）。

### 方案 A（**推荐**）：行点阵缓存 = 显式同步读 BRAM
深度 512×16bit（32 格 × 16 行，只用 22 格）每行一块，两块 BR18 都用不满，EG4S20
富余。写法必须是可推断为同步 RAM 的教科书形态（**寄存器读地址 + 单时钟**）：

```verilog
reg  [15:0] gram [0:511];                       // 只允许这一种数组; 读必须走下面寄存器形态
// y_b = y - BANNER_Y0 (0..63): 行内 32 线的带内行号; 行选择用 y_b[5] 选两块 gram 之一
wire [10:0] xp2 = x + 11'd2;                    // 地址提前 2 拍, 补偿 raddr+BRAM 两级延迟
reg  [8:0]  raddr;
reg  [15:0] row16_q;                            // 与"当前像素"同拍有效的 16bit 点阵行
always @(posedge clk) begin
    raddr   <= { xp2[9:5], y_b[4:1] };          // {cell=x/32, row=y_b/2}, 全是指定位截取
    row16_q <= gram[raddr];                     // BRAM 原生同步读; 严禁 gram[f(x)] 组合读
end
wire [3:0]  col  = x[4:1];                      // 当前像素的 16 分列 (2x 放大: x%32 再 /2)
wire        ink  = row16_q[15 - col];           // bit15=最左像素, 与 glyph_data 位序一致
```

（若 TD 仍不把该形态映射进 BRAM，就在 TD IP 库例化官方 BRAM 组件，端口逻辑照搬上面
三段；两种都不允许出现"组合读数组"。）像素输出、消隐判断与现行 osd_banner 相同：
`ink ? TEXT_COLOR : 背景压暗`，ASCII 半角槽走现行 `glyph8x16` ROM、列取 `x[3:0]`、
整体右移 8px 使其在 32px 格内居中。

**方案 B（备选，仅 ≤8 格的小缓存/调试）**：32B 字模存 32×8bit 寄存器，选择行 r/字节 j
用 `for(kk)` 常量下标 + `kk==idx` 展平（现行 `line1f` 同款，osd_banner.v v2b 注释里
就是这条 HDL-1007 修复路径）。对 1~2 格"当前字"缓冲（比如逐字滚动播出）很稳；22 格
全用它会把 LUT 炸穿（22×16 组 256bit→16bit 动态 mux），所以只作降级/局部手段。

**结论：行点阵缓存用 A，行文本缓存用 B（§6 的 352bit 平铺）**。两模块均不用
`$readmemh`、不用异步读数组、无硬件乘除法（×32、×16、÷32 全是指定位宽移位截取）。

## 8. 时钟/引脚域划分汇总

| 信号/逻辑 | 时钟域 |
|---|---|
| glyph_fetch、glyph_xcd.clk50 侧、SPI 四线 | clk 50MHz（板晶振） |
| msg_ink、行缓存、预取状态机、gram BRAM、osd_banner | video_clk 25.175MHz |
| 两域之间 | 仅 glyph_xcd 内部 4 条同步路径（req_tgl、done_tgl、addr_hold、256bit 总线）|

## 9. 上板验收清单（主线执行）

1. 烧 `w25q64_cjk_full.bin` @0x000000，上位机 verify 通过。
2. 综合/布线通过，时序报告无 clk↔video_clk 相关违例（或已按 §5.5 加假路径）。
3. 串口 `MSG 台风预警立即撤离` → 中文横幅正常、字形与 §gen 预览点阵一致（首次上电
   若显示"空/豆腐"，先查 FLASH 是否烧对芯片与基址：读回全 0xFF 即未烧写）。
4. 混合：`MSG 撤离3号集合点` 数字半角居中显示。
5. `STAT?`/`CLR` 行为不变；`EMG 1|2|3` 三组短语走 FLASH 后仍完整。
6. 稳定性：连续发 100 条中文 MSG，观察无花屏/撕裂（dirty 槽只在消隐期进 BRAM，
   行缓存在 `de=0` 才允许被渲染器看到——沿用 msg_ink 现行消隐期写策略）。
7. 快速字模通道自检（可选调试命令）：UART 发 `RDY?` 让固件读槽 1601("啊")，
   用 `STAT?` 回包低位字节报告 `glyph_data[7:0]`，期望非 0x00 非 0xFF。

## 10. 本会话拿不准的点（请主线复核）

1. **SDO/SDI 命名口径**：任务书按原理图标 `SDO=N8(FPGA→flash)`、`SDI=P7(flash→FPGA)`，
   与 W25Q64 数据手册的 SI/SO 命名正好相反（手册 SDO=flash 输出）。我按任务书方向
   实现（N8 输出/P7 输入）。若板卡网络标号实际按手册走，上板首测异常时**只需在顶层
   交换这两个端口连接**，模块本身不用改。
2. **烧写通道细节**：TD 上位机对本板"经 JTAG→FPGA→用户 SPI"通路的支持程度没有实查
   （boot FLASH 与用户 FLASH 是否在同一 JTAG 链mux 下、有没有跳线帽）。若工具不可用，
   需要补一个 FPGA 侧软装载（本模块预留了整片 0xFF 镜像设计，后续加 Page Program
   0x02/6 不冲突，glyph_fetch 可扩写分支）。
3. **>8000 非零槽**的自验指标与 GB2312 国标（7445 有效码位）矛盾，已按第 1 节修正为
   `解码数==7445 且 非零槽>7400 且汉字区无全零`；如主线另有指标需求请告知。
4. 半角符号槽（qu1..3 奇数位）渲染时宋体只占左半 8px，右半为空——显示半角建议直接
   走现有 8×16 ASCII ROM 而不用这些槽（§6 已如此建议）；若评委要求 GB2312 半角区也
   全走 FLASH，属可改用的素材，无硬件障碍。
5. `simsun.ttc` 16px 个别繁难字（如二级区笔画最密者）阈值 128 下笔画偏瘦属观感问题，
   阈值 96/112 的对比样张未做（如需我可再出参数化对比图）。

—— 子代理 cjk_flash 交付。
