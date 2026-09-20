# 交接文档 — FPGA HDMI 多媒体播放系统（致接手 Agent）

> **写于 2026-09-15 13:5x** ｜ 电脑与文件夹与前任完全相同（本机同一台）
> 前任 agent 的完整过程记录：`C:\td_batch\lab_pro`（git 受管）+ 本目录的 `01-`/`02-` 两份报告
> **请先读完本文再动手。第 6 节是整件事的核心结论，能帮你避免重走一遍弯路。**

---

## 0. 一句话现状

- **工程/固件是好的，板子也是好的**；当前**屏幕黑屏只剩开机横幅**，根因是
  **TF 卡里的图片不是本工程能读的格式**（只认 24bit 未压缩 BMP），
  **UART 实测「扫描深度加到 32 仍然 0 张」**（`LIST?` → `L 00 00 20`）。
- 固件已迭代到 **v12.3** 并已烧进板子；源码 4 个 commit 在 `C:\td_batch\lab_pro` 的 git 里。
- **待办只有两件**：① 把合规 BMP 放进卡（第 7.1 节，用户侧操作）；
  ② 若要继续开发，见第 7.2 节的建议项。

---

## 1. 项目是什么

- **赛题**：第十届（2026）全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 ·
  **赛题一：HDMI 多媒体播放系统**（基于国产 **安路 EG4S20** 的"低延迟展陈/应急发布终端"）。
- **目标**：国一。
- **核心功能**：TF 卡读 BMP → SDRAM 双缓冲 → HDMI 输出；
  加 OSD 字幕（中英/GB2312）、跑马灯、转场特效、亮度对比度、伪频谱、
  多分辨率图片自适应缩放（扩展3）、应急播出（EMG）、NEXT/PREV/AUTO 播放控制等。
- **目录约定**：**编译工作区必须在 `C:\td_batch\`（纯英文）**，
  OneDrive 桌面目录只放文档/资料/归档 —— 这是硬约束（中文路径会坑工具链）。

---

## 2. 硬件与环境（本机实测状态）

### 2.1 硬件
| 项 | 状态 | 说明 |
|---|---|---|
| 开发板 | **在位** | `read_device_id` → `EG4S20BG256`（JTAG 只读探测，2026-09-15 实测） |
| 安路编程器 | **在位** | `Anlogic usb cable v0.1`（设备管理器 OK） |
| 串口 | **COM4 可用**（经播控台） | 设备管理器显示 `USB-SERIAL CH340 (COM6)`，但**实际能用的是 COM4**；pyserial 只枚举出 COM4。**注意：串口被播控台进程独占**，直接 `serial.Serial('COM4')` 会 `PermissionError`，要走播控台 API。 |
| 显示器 | 7 寸 HDMI 屏 | HDMI 只用 **HDMI_B** 口 |
| 数码管 | 有 | 位选低电平有效；v12.3 起**低两位显示"登记图片张数"(十六进制)**，第 5 位显示状态码 |

### 2.2 工具链
| 用途 | 路径 |
|---|---|
| TD（综合/布局/bitgen） | `C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe` |
| Python（**唯一指定**） | `C:\Users\lwy\miniconda3\envs\fpga_batch\python.exe -X utf8` |
| iverilog（**必须绝对路径**） | `/c/iverilog/bin/iverilog.exe`（不在 PATH） |
| 烧写脚本 | `C:\td_batch\tf_test\dl_tf.py` |
| 播控台服务 | `http://127.0.0.1:8765/api`（进程已起；`tools\console\console.py`） |

### 2.3 ⚠️ 三条必须知道的运行环境约束
1. **TD 必须在"无沙箱"下跑**，否则 elaborate 会 coredump，且失败残骸会"毒化"工程目录
   （表现为源码没改也报错/段错误）。**重综合一律用干净目录**（见 3.2）。
2. **bash 工具的 PATH 被裁剪过**：`ls/cat/grep/head/tail/find/sleep/seq` 多数不可用。
   请一律用绝对路径（`/usr/bin/grep`）、专用工具（Read/Glob/Grep）或 PowerShell 工具。
   **不要用 `cmd`、不要在 PowerShell 工具里调用 cmd.exe**（会被安全策略拦截）。
3. 中文输出/文件写入一律 UTF-8（Python 加 `-X utf8`）。

---

## 3. 关键路径与命令速查

### 3.1 目录
```
C:\td_batch\lab_pro\                     ← 源码 + git（工作区，纯英文）
  ├─ user_source\hdl_source\              ← ★ RTL 主战场
  │    ├─ top_tf_hdmi_audio.v             ← 顶层（接线/时钟域/数码管/观测口）
  │    ├─ img_scaler.v                    ← 多分辨率缩放（扩展3 的核心）
  │    ├─ msg_ink.v                       ← 命令解析/参数寄存器（含 scale_en、fd_mode 默认值）
  │    ├─ osd_banner.v / vout_fx.v / v103_overlay.v  ← OSD/特效/叠加层
  │    └─ SD\                              ← SD 卡 + 帧缓冲 + 显示链
  │         ├─ sd_card_bmp.v              ← 播放器主体（加载状态机/双缓冲切换）
  │         ├─ bmp_read.v                 ← BMP 头解析 + 像素流（含 header_match 判定）
  │         ├─ frame_read_write.v         ← SDRAM 读写仲裁（读写互斥门就在这里）
  │         ├─ frame_fifo_write.v/read.v  ← 写/读帧状态机（0x18 案的主战场）
  │         ├─ spi_master.v/sd_card_cmd.v/sd_card_sec_read_write.v  ← SPI/SD 底层
  │         └─ video_timing_data.v/video_delay.v  ← 显示时序与读取
  ├─ tools\tests\                          ← 仿真台
  ├─ tools\console\                        ← 播控台 + 板测/探针脚本
  └─ td_project\ ~ td_project3\            ← 三代构建目录（含历代 bit）
C:\td_batch\tf_test\dl_tf.py               ← 烧写
C:\Users\lwy\OneDrive\Desktop\FPGA嵌入式大赛\   ← 文档/资料（本文件所在）
```

### 3.2 综合出 bit（**三段式，必须干净目录**）
```bash
# 1) 建干净目录（从归档模板复制，千万别在旧目录上删产物——会毒化）
cd /c/td_batch/lab_pro
/usr/bin/cp -r _cold_archive/td_project_cleanM td_projectN
/usr/bin/rm -f td_projectN/lab_pro.bit td_projectN/*.db td_projectN/*.area \
              td_projectN/*.qor td_projectN/*.rpt td_projectN/*.bid td_projectN/*.log*
/usr/bin/rm -rf td_projectN/DrCongo.info.iter0 td_projectN/minidump
# 2) 四段（TD 必须在无沙箱下运行！总耗时 ~14 分钟）
cd td_projectN
TDC="C:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/bin/td_commands_prompt.exe"
"$TDC" s1_syn.tcl    # elaborate+optimize+export gate.db   → 认 ===S1_GATE_DONE===
"$TDC" s2_place.tcl  # place seed7 → place db              → 认 ===S2_PLACE_DONE===
"$TDC" s3a_route.tcl # route（~10min，必须单独一段）        → 认 ===S3A_DONE===
"$TDC" s3b_bit.tcl   # 报告 + bitgen                        → 认 ===S3B_BIT_DONE===
# 3) 验收：lab_pro.bit 应 635444 B；lab_pro_timing.rpt 应 "Period Check WNS: 0.000ns"
```

### 3.3 烧写（**真判据 = prog_finish=True**）
```bash
cd /c/td_batch/tf_test
/c/Users/lwy/miniconda3/envs/fpga_batch/python.exe -X utf8 dl_tf.py C:/td_batch/lab_pro/td_projectN/lab_pro.bit
# 认这三样：prog_finish=True、PRG-2014 Chip validation success、RUN-1003 finish command "program"
# 注意：SRAM 配置，掉电即失 → 每次上电都要重烧，否则串口不响应、屏幕全黑（见第 8 节）
```

### 3.4 板测 / 读板状态（**串口被播控台独占，走 API**）
```bash
cd /c/td_batch/lab_pro/tools/console
/c/Users/lwy/miniconda3/envs/fpga_batch/python.exe -X utf8 probe_board2.py   # hello+reconnect+WHY?+LIST?
/c/Users/lwy/miniconda3/envs/fpga_batch/python.exe -X utf8 scan_test.py      # SCAN7/SCAN32 加深扫描
# 命令白名单见 console.py（NEXT PREV AUTO CLR EMG1-3 PLYALL SCAN4/7/32 WHY? LIST? + SPD/VOL/COL/T/VID/BR/GN/FD/CK/VU/SR/SC 等）
# 板端回执：LIST? → "L <登记hex> <当前hex> <深度hex>"；WHY? → "W <sig> <hist1> <hist2> <stallBCD>"
```

---

## 4. 已完成的工作（固件版本谱系）

| 版本 | 改了什么 | 为什么 | bit MD5 | 状态 |
|---|---|---|---|---|
| b22q（前任基线） | 四分频限流修 0x18 | 历史 | `22562AE4…` | 旧基线，可回退 |
| **v12.1** | `img_scaler.v` 缩放路出货 **1字/4拍 → 1字/32拍**；新增 `src_pause` 源侧限流 | 消除**输出突发化**：原来一整行 640 字在 2560 拍内灌向 512 深 wfifo，导致**溢出丢字(0x18)** 或 **长时间占住 SDRAM 写口饿死显示读** | `f7aaf8d4…` | 已实测：wfifo 水位 511→50、丢字 71058→0 |
| **v12.2** | `msg_ink.v` 上电默认 `scale_en = 1` | 原为 0 → `multi_res=0` 时 `bmp_read` **只认恰 640×480**，多分辨率图整组被拒 | `55dcf783…` | 已烧 |
| **v12.3** | 顶层：数码管低两位显示**登记图片张数**；修 `list_cnt/list_depth` **declare-after-use** | 本板串口时好时坏，需要一个**板上可视观测口**；后者会生成 1bit 隐式网与 6bit 声明冲突（**本文件历史老坑**） | **`955bbe78…`** | **★ 当前板内固件（2026-09-15 重烧）** |

**回归门（任何改动都必须过）**：
```bash
cd /c/td_batch/lab_pro
export PATH="/usr/bin:/bin:/c/iverilog/bin:$PATH"
CORE=$(/usr/bin/ls user_source/hdl_source/SD/*.v)
/c/iverilog/bin/iverilog.exe -g2005 -s tb_chain  -Iuser_source -Iuser_source/hdl_source -Iuser_source/hdl_source/SD -Iuser_source/hdl_source/include -o /tmp/c.vvp tools/tests/tb_chain.v  $CORE user_source/hdl_source/img_scaler.v user_source/hdl_source/sdiv24.v tools/tests/sim_stubs.v && /c/iverilog/bin/vvp.exe /tmp/c.vvp   # 期望 30 checks, 0 FAIL
/c/iverilog/bin/iverilog.exe -g2005 -s tb_mask32 -Iuser_source -Iuser_source/hdl_source -Iuser_source/hdl_source/SD -Iuser_source/hdl_source/include -o /tmp/m.vvp tools/tests/tb_mask32.v $CORE user_source/hdl_source/img_scaler.v user_source/hdl_source/sdiv24.v tools/tests/sim_stubs.v && /c/iverilog/bin/vvp.exe /tmp/m.vvp   # 期望 11090 checks, 0 FAIL
```
另有两个**真板速率**验证台（很有价值）：
- `tools/tests/tb_scaler_real.v` —— 真 SD 速率源 + 独立可解码样图 + 设计意图几何。
  **7 个多分辨率全部 `wrong px = 0` PASS**（320×240/640×200/800×600/1024×768/1280×360/400×800/1280×720）。
  参数：`-DSRC_W -DSRC_H -DT_PX（默认180拍/像素）`
- `tools/tests/tb_v103_fw.v` —— 集成台（真 wfifo + 真 frame_fifo_write + 真 scaler）。
  `+mode=scaler +gap=500 +busy_pct=40` 期望 **PASS（307200 字守恒、零丢字、finish_cnt=1）**。
  ⚠️ 它自带的收尾窗口已放宽到 12M 拍（v12.1 后出货变慢）。

---

## 5. ★★★ 第 6 节之前请先读：整件事的复盘（避免重走弯路）

### 5.1 现象与真相
用户报告「**花屏 + 疑似只显示两张图 + 切图时有竖条一闪而过**」。
前任 agent（我）为此投入了大量算力：拆 SD 速率、重写缩放器出货节奏、搭了两个全链路仿真台……

**最后靠两个"一句话"的证据定性：**
1. **数码管读数 `00`**（v12.3 加的观测口）= `img_found_count` = **卡扫描一张图都没找到**；
2. **一张屏幕实拍**：画面**全黑**，只有开机横幅
   `ANLOGI EG4S20 EMERGENCY INFO TERMINAL V2.1` / `SYSTEM READY - AWAITING`。

→ **根本不是"花屏"，是"没有图可播"。** 后经 UART 复核：`LIST?` = `L 00 00 20`
（**扫描深度加到 32 仍是 0 张**）—— 彻底排除"扫描深度不够"，坐实**卡内文件格式问题**。

### 5.2 真根因
`bmp_read.header_match` 只认 **24bit + BI_RGB 未压缩** 的 BMP：
`header_0/1=='B','M'`、`bit_count==24`、`compression==0`；
`scale_en=1` 时另需 `mr_ok`：320≤w≤1280、16≤h≤1080、长宽比≤4:1、**w%4==0**。
用户卡上大概率是 **JPG/PNG**（或 32bit / 带压缩 BMP）→ 一张都匹配不上。

**官方工具 `HX4S20_Contest_202606\tools\bmp_check.py` 的注释把同类坑全部点名**，包括
「PNG/JPG 直接改后缀 → magic 不是 'BM'」「位深不是 24」「BI_RLE8/BI_BITFIELDS → 工程读不出来」
「height 为负 → 上下颠倒」「**分辨率不匹配 → 显示错位或花屏**」。

### 5.3 ⚠️ 两条被证伪的旧结论（**不要再据此动手**）
1. **`00-深度重构方案与花屏根因_2026-09-10.md` 的"img_scaler 环形缓冲被写侧覆写"是错的。**
   它假设 SD 源"每拍 1 像素"，而**真板 SPI 只有 25MHz**：
   `spi_master.v` 每字节 = 16 半周期 ×(clk_div+2)，`SPI_HIGH_SPEED_DIV=0` → **约 32~36 个 100MHz 拍/字节**
   → **1 像素(3B) ≈ 96~108 拍**；实测旁证：`sd_card_bmp.v` 注释「正常加载 ~0.55s」÷ 640×480(921KB)
   → **1 像素 ≈ 180 拍**。而覆写需要源快于 **3.2 拍/像素** —— 真板比它**慢 30 倍**，环不可能被覆写。
   旧 TB（`tb_scaler_burst`/`tb_v103_fw`）的源是 **1 像素/拍**，**比真板快约 100 倍**。
   **→ 那份文档里提的 "B3 架构解耦" 不要做，是伪需求。**
2. **`scaler_golden_cmp.py` 原有的 `t_nd` 几何公式是错的**（分子分母错位，**只在 4:3 时正确**
   → 800×600 能过，1280×720/400×800 一律误判）。**已修正**，修正后与"设计意图(fit 640×480 保比)"
   对表 8 张实卡几何**全部一致**。

### 5.4 ★ 本次最重要的方法论（请继承）
**先确认"信号源是否有效"，再谈"渲染是否正确"。**
- 固定第一步：**请用户拍一张屏幕照片 + 读数码管/观测口**。
  一张照片（用户一句话的成本）就能立刻区分「**没图** / 有图但画错」——
  而这一次，两个方向的所有仿真都没做到这件事。
- **本板"串口不可用"时，用板上观测口代替**：数码管低两位 = 登记图片数（v12.3）。
- 判决前**先自证校验台**：本轮共踩了 **3 次"校验台自己错"**（几何公式错位 / 漏判四边黑边 /
  采集计数 2× 且漏采 1 拍脉冲），**每一次都差点被当成 DUT 的缺陷**。先做负控/自洽性检查。

---

## 6. 当前未解决 / 待办（按优先级）

### 6.1 ★ P0：把合规 BMP 放进卡（用户侧操作，不需要改代码）
- **最快**：把工程自带、已过官方校验的 8 张演示图拷到**卡根目录**：
  `C:\td_batch\lab_pro\tools\multires_demo\BMP0000.BMP … BMP0007.BMP`
  （实测 `bmp_check.py`：**8/8 均 24bit BI_RGB 未压缩**；7 张 WARN 只是"非 640×480"，
  而 `scale_en=1` 下全在合法域 → 会走缩放路，正好演示扩展3）。
  拷完重新上电，**数码管应显示 `08`**，按 KEY1 逐张切换。
- **自己的照片**：官方 `bmp_convert.py` 转换：
  `python ...\bmp_convert.py <图目录> -o <出目录> --size 640x480 --mode pad`
- 校验：`python ...\bmp_check.py <卡目录>`
- 详见 `02-卡内容修复指南_图播不出来怎么办.md`。

### 6.2 P1：两处已知小缺陷（已定位，未修，都是低风险改动）
1. **OSD 横幅文字右端被裁**：实测 `AWAITING` 缺尾（文本宽超过 640 像素）。
   在 `osd_banner.v` / 横幅文本源处缩短或分行即可。
2. **找不够图时没有明确提示**：现在只显示笼统的 `SYSTEM READY`。
   建议：若 `img_found_count == 0`，直接显示 `NO BMP FOUND - CHECK CARD`。
   （这次若有这行提示，能省掉整轮排查。）

### 6.3 P2：可选的健壮性/体验改进
- `scan_target_count` 开机默认只有 **4**（`top` 里 `SCAN_TARGET_COUNT(3'd4)`）。
  现在可用 `SCAN7/SCAN32` 加深，但若串口不可用用户就没法加。
  **注意**：直接改大会拖长开机（archive 记录：4 图卡 target=7 全卡爬要 37 秒）。
- 低频瞬态 `0x18`（`WHY?` 的 stall 计数）：实测本轮深扫描后 `W 18 18 18 010`。
  与"卡死型 0x18"（distinct=1、永不恢复）本质不同；v12.1 已消除溢出根因，剩此观察项。
- `sector_lut` 表合并（预估省 600~1100 LUT，LUT 已 ~87%）。

---

## 7. 铁律与历史坑（血泪浓缩，**动手前先背**）

1. **TD 段错误**：长中文注释行可能触发 elaborate 段错误；老构建目录删产物会"毒化"。
   → 核心 .v 注释保持短；**重综合一律新建干净目录**。
2. **烧写真判据**：`Chip validation success` ≠ 烧完！认 **`prog_finish=True`** 或
   `RUN-1003 finish command "program"`。
3. **SRAM 掉电即失**：每次重新上电都要重烧，否则**串口不响应、屏幕全黑**
   （本次交接就遇到：JTAG 能读到 `EG4S20BG256`，但 UART 全无应答 → 重烧 v12.3 后即恢复）。
4. **串口被播控台独占**：直连 pyserial 会 `PermissionError`，走 `http://127.0.0.1:8765/api`。
   固件命令以 **`\n`** 结尾（不是 `\r\n`），GB2312 编码。
5. **仿真台比 DUT 更容易错**：几何必须用"设计意图"独立对表（勿与 DUT 内部寄存器同式复算，
   否则"同错抵消"）；letterbox **必须判四边**；1 拍脉冲要用粘滞位捕获。
6. **全链路仿真性价比极低**：本机"源→scaler→frame_read_write→行为SDRAM→显示读"跑 200ms 仿真
   要 **10~25 分钟墙钟**，且极易被自己 TB 的计数/相位 bug 污染。**优先用"定点+快激励"小台，
   或直接上板取现象。**
7. **`search/路径`**：Windows 路径在 bash 里要写 `/c/...`；但**传给 Python 脚本时用 `C:/...`**
   （写成 `/c/...` 会被解析成 `C:\c\...`，本轮的坑）。
8. **数码管**：位选低电平有效；丝印 `KEY1=A2 / KEY2=B2 / KEY4=C1`（代码信号与丝印差一格）；
   物理键 PULLUP、空闲=0 按下=1。HDMI 只用 **HDMI_B** 口。
9. **`.bat` 必须纯 ASCII**，中文 UI 移进 Python；路径与脚本输出一律 ASCII-only。
10. **TD 增量布线毒化**：连跑多次综合后随机 `RUN-8102/PHY-8023` = 缓存毒化非设计超限，
    **原样重跑即愈**。

---

## 8. 参考文档索引（都在 `C:\Users\lwy\OneDrive\Desktop\FPGA嵌入式大赛\`）

| 文件 | 内容 |
|---|---|
| `01-花屏修复报告与验证_2026-09-12.md` | 前任 agent 的完整技术报告（含被证伪结论的更正、全分辨率验证表、三版 bit 的 MD5） |
| `02-卡内容修复指南_图播不出来怎么办.md` | **P0 待办的详细操作步骤**（含官方工具的完整命令） |
| `00-深度重构方案与花屏根因_2026-09-10.md` | ⚠️ **结论已被证伪，仅作案情存档**（第 5.3 节说明原因） |
| `AI资料\wyt\HDMI备赛详细计划\00-交接文档-新窗口必读.md` | 更早的（b16~b23 时代）详细交接，含大量工具链踩坑记录；**顶部已加入本次更正说明** |
| `HX4S20_Contest_202606\` | 官方赛题资料（**权威**）：`tools\bmp_check.py` / `bmp_convert.py` 等 |
| `通知\` | 官方通知（**权威**） |
| `.workbuddy\memory\` | 工作记忆：`MEMORY.md`（长期）+ `2026-09-07 ~ 09-12.md`（逐日） |

> 前任的完整心路与全部证据链在 `C:\td_batch\lab_pro` 的 git log（4 个 commit）与
> `tools/tests/_b3/`、`tools/opt_surgery/` 的实验产物里，需要复核时可查。

---

## 9. 给你的第一条建议

**先做第 6.1 节**（把 8 张演示 BMP 拷进卡，重新上电），这会立刻让屏幕出图、数码管显示 `08`。
**在这一步完成之前，不要动 RTL** —— 因为你现在看到的"黑屏"和渲染层毫无关系。
（这次前任 agent 就是在这上面绕了一整天，我用一整章把弯路写清楚了，希望你别重走。）
