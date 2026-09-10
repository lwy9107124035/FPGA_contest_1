# LOAD 协议 v1 — 通过 UART 把 GB2312 字库镜像软装载进板载 W25Q64

作者：主线会话（2026-09-05）。固件装载器、PC 发送端、OSD 集成三方**必须逐字遵守本文件**。
UART：115200-8N1，ASCII 命令行走现有 msg_ink 通道；二进制帧走 loader 独占通道。

## 1. 物理与对象
- 目标器件：用户 FLASH **W25Q64**（8MB，SPI NOR，通用 IO 引脚，与 MSPI 上的 boot FLASH 物理无关，砖不掉）。
- 引脚（FPGA 视角，来自原理图 PDF 提取）：CS=P8, MOSI(FPGA→flash, 原理图名 SDO)=N8, MISO(flash→FPGA, 原理图名 SDI)=P7, SCLK=M9, WP#=P9(常数1), HOLD#=R9(常数1)。SPI 模式0，SCLK≤12.5MHz（50MHz 四分频）。
- 镜像：`C:\td_batch\lab_pro\tools\cjk_flash\hzk16.bin`，282,752 B，标准 HZK16 布局（槽位偏移=((qu-1)*94+(wei-1))*32，16 行×每行 2 字节约定见 README_cjk_flash.md §2）。
- 镜像存放 FLASH 起始地址 **0x000000**，占用前 70 个 4KiB 扇区（0x00000..0x457FF）。

## 2. 会话建立（文本层，msg_ink 已有通道）
1. PC 发文本行 `LOAD` + `\n`。
2. msg_ink 分类命中 → 通知 loader 启动 → 板回文本 `RDY\n`（4 字节含 CRLF）。
3. loader 独占串口：**此后任何非帧头字节静默丢弃**（不用发 MSG 等，会被忽略）。
4. 结束/超时后回文本模式，可再收常规命令。超时保护：帧间 10s 无字节 → 放弃并回 `TIMEOUT\n`。
5. 装载进行中 emg/MSG 显示不受影响（loader 在 clk50 域，与 video 域解耦）。

## 3. 二进制帧（loader 通道）
```
byte0     : 0xA5            帧同步头
byte1     : 0x01            版本
byte2..3  : LEN (big-endian, 16bit)   payload 字节数 0..256
byte4..4+LEN-1 : payload（FLASH 数据，按 256B 页对齐顺序流水）
末2字节    : CRC16-CCITT (big-endian)  多项式 0x1021, **初值 0x0000（勘误：主线裁决以自检向量 0x31C3 为准，§3 原稿 0xFFFF 作废）**, 不反转, 覆盖 byte0..(4+LEN-1) 全体
```
- 首帧要求 FPGA 先擦除（见 §4），payload 偏移从 0 起自动累加；**帧长除最后残帧外固定 256**（**勘误 2026-09-05**：282752 = 1104×256 + 128，最后一帧 LEN=128，FPGA 必须接受残帧）。
- LEN=0 帧 = 结束帧（其本身也有 CRC）：FPGA 收尾 + 回读抽验（读 0x00000 起 32B 与接收缓存比对，再按**实收总字节数**抽验尾部 32B——即 282720=0x45060 起 32B，**勘误：原稿 0x457E0 是错的，勿硬编码**）。
- 每帧成功接收并烧完：板**不回**任何东西（省带宽）；每 40 帧回一个文本 `P40\n`…进度行（PC 端可选显示）。
- 任何 CRC 错：板回 `CERR\n`，丢弃该帧，等待下一帧（PC 应重发该帧一次；连错 3 次中止回 `ABORT\n`）。
- 结束帧处理后：成功回 `DONE\n`，抽验失败回 `BAD\n`。

## 4. FPGA 侧行为要求（flash_pp + uart_loader）
- 会话启动（收到 RDY 发送完成）即先做**批量擦除**：0x00000 起 70 个扇区，每扇区块擦除命令 0xD8（块=64KiB 只需 5 次！用 0xD8 64K 块擦更快，0..0x4FFFF 5 块 + 多余不要——**统一擦 5 个 64K 块 = 0x00000,0x10000,0x20000,0x30000,0x40000**；每块典型 0.4~2s？W25Q64 64K 块擦典型 0.4s max 3s → 5 块最坏 15s）→ 擦完后**必须回 `ERASED\n` 文本行**，PC 收到才开始发帧。（PC 端等待 ERASED 超时给 30s。）
- 页编程：0x02，256B/页，写完 poll 0x05 bit0 (WIP)，每页 max 3ms；WREN 0x06 每条编程/擦除前置。
- loader 数据缓冲：262B 帧组装移位缓存即可，不要求双缓冲（115200 带宽远低于页编程吞吐）。

## 5. PC 端（load_font.py，Python 3，仅标准库 + 自己数 CRC）
- 用法：`python load_font.py [-com COM4] [镜像路径默认 hzk16.bin]`
- 流程：打开串口（DTR/RTS 保持默认）→ 发 `LOAD\n` → 等 `RDY\n` → 等 `ERASED\n`(≤30s) → 逐帧发送 282752B（1105 帧 256B + 无残帧，282752=1105*256 整除）→ 结束帧 → 等 DONE/BAD；期间回显进度（每 110 帧 10%）。
- 串口每读到一个 ASCII 行就打印。CRC 实现用查表法，给出自检向量：CRC16-CCITT("123456789") = 0x31C3。
- Windows 控制台 GBK 环境下**不要用中文 print**（防编码炸），全部英文。

## 6. 集成点（主线自己做，两位实现者不用管）
- msg_ink：新增 LOAD 分类（前缀 L O A D 且 llen==4）→ 输出 loader_start 脉冲 + 让出 uart 数据通路 mux。
- top：uart_rx 输出字节流按 loader_active 信号在 msg_ink / uart_loader 间二选一路由；tx 通道两个模块共享需仲裁（loader 用独立 tx_request，简单 mux：loader_active 时占 tx）。
- OSD 渲染侧改用 FLASH 字库（glyph_fetch/glyph_xcd）由主线另行集成。

## 7. 交付物与位置
- 固件：`C:\td_batch\lab_pro\user_source\hdl_source\cjk_flash\uart_loader.v` + `flash_pp.v`（Verilog-2001，可综合，case 全 default，禁 latch，数组使用遵守"一拍一口"规范——见 msg_ink.v 头部 v3c 教训注释，违反必翻车）
- PC：`C:\td_batch\lab_pro\tools\cjk_flash\load_font.py`
- 各自写完后把编译/运行自查结果汇总在 `cjk_flash/LOAD_IMPL_NOTES.md`
