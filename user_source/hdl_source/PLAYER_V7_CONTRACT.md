# 播控 v7 扩展 · 接口契约 v2（2026-09-05）

范围：物理按键根治 + 5 条新播控命令。工作包：
- WP-E：sd_card_bmp.v（按键重写 + 参数执行端）——子代理
- WP-F：msg_ink.v（命令解析 + 参数发出端）——子代理
- 顶层接线/综合/烧录/回归 —— 主线

## 0. 板上事实（勿再假设）
- 物理键 key1(B2)/key2(C1)：**PULLUP，空闲=0，按下=1**（高有效！）。旧 key_press_debounce 模块假设"松开=1/按下=0"且复位初错 → 开机误触一次+按下语义反 + 抖动多触发。这就是"物理键偶发黑屏/切失败/连跳"的根因（连发 load → 背靠背重扫 → 画面抖动）。
- 串口软键通路（press1/press2 电平 → soft_next_btn/soft_auto_btn）是**丝滑的**，语义以此为准。
- bmp_read.scan_target_count 是 [2:0] **端口**（运行时可改），scan_found_total 3bit → 扫描上限 7 张。

## 1. 新命令（ASCII，\n 结尾，走 msg_ink 既有 6 字节快照 s0..s5；全部回 OK、计入 msgcnt；参数非法回 ERR 且不改状态）
| 命令 | 字节 | 语义 |
|---|---|---|
| `SPD n` | S,P,D,sp,n (5B) | 所有图自动播放时长 = n 秒（n∈1..9） |
| `T i n` | T,sp,i,sp,n (5B) | 第 i 张（0..6）时长 = n 秒 |
| `PLY xx` | P,L,Y,sp,h,h (6B) | 播放子集 = 8bit 十六进制掩码（bit i=第 i 张，只 0..6 有效）；例 `PLY 0F` 前 4 张，`PLY 44` 第 3、7 张 |
| `PLYALL` | 6B | 掩码 = 全部已扫到的图 |
| `SCAN4` / `SCAN7` | 5B | 扫描目标深度设为 4 / 7（写 scan_target_count 端口驱动寄存器；SCAN7 后需重扫：置 scan_kicked<=0 触发自愈重扫） |
NEXT/AUTO/其余命令行为**不变**。NEXT/AUTO/PLY 掩码交互：轮播（手动与自动）只在 `play_mask & found_bits` 集合内循环；集合 <2 张时 AUTO 不起转（沿用 count>1 门槛的语义，换成集合大小）。

## 2. msg_ink → 播放器的参数通道（video_clk 发出，播放器 100M 域自行同步）
```verilog
output reg         prm_tgl;    // 每次成功解析上述命令，翻转 1 次（准静态数据+toggle，同 ls_tgl 套路）
output reg  [3:0]  prm_code;   // 1=SPD 2=T 3=PLY 4=PLYALL 5=SCAN4 6=SCAN7
output reg  [3:0]  prm_a;      // T: 图号 i；其余 0
output reg  [7:0]  prm_b;      // SPD/T: 秒数 1..9；PLY: 掩码；其余 0
```
msg_ink：在 st1 分类处新增分支（判据只看 s0..s5 快照，hexa 解析掩码），置 prm_* 且 prm_tgl<=~prm_tgl，然后 st3 回 OK；非法（n 非 1..9、i>6、掩码为 0 等）→ 与旧命令同规则回 ERR、不翻转 tgl。
sd_card_bmp 顶层端口新增（同名 input）；内部 3FF 同步 tgl、边沿后按 prm_code 应用。

## 3. 播放器侧存储（TD 铁律：一律平铺向量+case 读写，禁止同拍多读口的数组）
- `reg [31:0] dur_flat;`（8×4bit，秒数 1..9，默认全 1）；读=case(load_idx/img_idx) 选 nibble。
- `reg [7:0] play_mask;` 默认 8'h0F。`reg [2:0] scan_target_r;` 默认 3'd4（接 bmp_read 端口）。
- `reg [31:0] auto_target;` 当前图自动翻页计数终点 = 秒数×100_000_000（case(4bit 秒数) 预计算常数乘积，不用乘法器）。
- next_index_limited / 自动推进 改为：候选 = mask & 已扫到；从 cur 往后找第一个候选（7 级优先链组合逻辑函数），找不到则回绕；无候选或仅 1 候选时不动作。
- 首图/重扫提交仍从"第一个候选"开始。

## 4. 物理键根治（仅 sd_card_bmp 内，删对 key_press_debounce 的一切依赖）
新按键前端（高有效"按下沿"事件，与软键同语义同消费点 OR）：
- raw key_next/key_auto 各：2FF 同步 → `high_cnt` 连续 5ms(19'd500_000@100M) 高电平 → 产生 1 拍 press 事件并置 armed；此后必须 `low_cnt` 连续 5ms 低 → 清 armed（一次按压只一发，抖全部被 5ms 稳定窗吃掉）。
- 事件 OR 进现有 `key_next_press || soft_next_press` 消费点（旧模块输出不再使用；`key_press_debounce` 模块整体废弃，可从文件删除或不再例化——保持编译干净）。
- 按下瞬间触发（与串口一致：按下去马上切，不用等抬手）。

## 5. 不许动的东西
- msg_ink 的 6 拍快照/snap 机制、ack 引擎、MSG/EMG/CLR/VOL/NEXT/AUTO/LOAD/STAT? 既有语义、配对引擎（f0/f1/f2）。
- 播放器：abort 脉冲化/scan_kicked 自愈、双缓冲与提交握手（v5f）、soft_* 通路、dbg_o 位布局。
- bmp_read/frame_read_write 等其余文件一律不碰。
- 两包各自文件外零改动；顶层例化由主线补（两包在文件头写 `=== 集成给主线的话 ===` 给出例化片段）。

## 6. 验收
- regress 新增：`SPD 3`→OK、`T 2 5`→OK、`PLY 05`→OK、`PLYALL`→OK、`SCAN7`→OK、`SPD A`→ERR、`T 9 1`→ERR、`PLY 00`→ERR。
- 物理键：连续快按 KEY1 ×5 不得出现双跳/漏跳/黑屏加重；KEY2 单按必须恰好开/关一次。
- 60s 烤机（AUTO, SPD 2）：rescan=0；换图节拍肉眼≈2s。
