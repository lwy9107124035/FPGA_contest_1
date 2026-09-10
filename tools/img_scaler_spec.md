# img_scaler 实现规格（扩展3 · 严格版）

## 目标文件
`user_source/hdl_source/img_scaler.v`（覆盖现有草稿）+ `tools/tests/tb_img_scaler.v`

## 功能
任意分辨率 24bpp BMP 像素流 → **恒定 640×480** 输出流，等比缩放 + letterbox 黑边。
- 输入：sd_card_clk 100MHz，1 拍 1 像素，`{R,G,B,8'h00}`，速率约 1~3 Mpx/s（远慢于输出）
- 输出：恒 307200 拍（640×480），含黑边，与下游 SDRAM 帧写 `write_len` 对齐
- 支持源范围：16×16 ~ 1280×1080，缩放比 ≤4:1（任一方向）；超出 → 直通兜底

## 端口（不要改）
```verilog
module img_scaler (
    input  wire        clk, rst_n,      // 高有效复位
    input  wire        in_en,           // 源像素有效，1 拍 1 像素
    input  wire [31:0] in_data,         // {R,G,B,8'h00}
    input  wire [15:0] src_w, src_h,    // 真实 BMP 头，在 in_sov 那拍有效
    input  wire        in_sov,          // 首像素脉冲（1 拍）
    input  wire        in_eov,          // 末像素脉冲（与末个 in_en 同拍）
    output reg         out_en,
    output reg  [31:0] out_data,        // {R,G,B,8'h00}
    output reg         frame_done       // 307200 拍发完后 1 拍脉冲
);
```

## 已验证的依赖（直接用，别重写）
`sdiv24`（`user_source/hdl_source/sdiv24.v`）：24÷16 迭代除法，10/10 仿真通过。
```verilog
sdiv24 u_div(.clk,.rst_n,.start,.num[23:0],.den[15:0],.done,.quo[23:0],.rem[15:0]);
// start 拉高一拍锁存 → 25 拍后 done 拉高一拍；start 期间 busy 必须拉低
```

## 状态机（三态）
| 态 | 行为 |
|---|---|
| IDLE | 等 `in_sov`；按源尺寸选路径：640×480 或非法几何(越界/比>4:1) → `pass=1` 进 RUN；否则 `pass=0` 进 CALC |
| CALC | 串行 3 次 sdiv24 算几何（见下）；期间**输入侧照常入缓存**，不得丢像素 |
| RUN | `pass=1`：逐拍 `out_en<=in_en; out_data<=in_data`，遇 `in_eov` 回 IDLE + frame_done。`pass=0`：S1 水平重采样 + S2 输出机并行跑 |

## 几何计算（CALC，交叉乘判方向，只有 3 次除法）
```
wide    = (src_w*480 >= src_h*640)          // 33bit 交叉乘，无除法
非主导边: wide ? dst_h = src_h*640/src_w : dst_w = src_w*480/src_h   // sdiv24 job0
主导边为常量: wide ? dst_w = 640 : dst_h = 480
offx = (640 - dst_w) >> 1 ;  offy = (480 - dst_h) >> 1     // 对称 → 方向无关
sout_x = dst_w*16384 / src_w   // Q14 出步长（目标像素数/源像素），sdiv24 job1
sout_y = dst_h*16384 / src_h   // 同上，sdiv24 job2
```
被除数上界核对：非主导边 ≤ 1080*640 = 691200 < 2^24 ✓；sout ≤ 640*16384 = 10485760 < 2^24 ✓。

## 归属法最近邻（关键：与 TB 参考模型必须逐像素一致）
第 k 个目标像素（0 基）归属源索引 `owner(k) = (2*k+1) * step >> 15`，其中 step = Q14 步长（sout）。
- 水平：`owner_x(j) = (2*j+1)*sout_x >> 15`，j = 目标列（0..dst_w-1）
- 垂直：`owner_y(i) = (2*i+1)*sout_y >> 15`，i = 内容行号（0..dst_h-1）
- 目标像素 (dx,dy) 落在内容区（`offx<=dx<offx+dst_w && offy<=dy<offy+dst_h`）才采样，否则发 24'h000000
- 源行号 > h0-1 时钳到 h0-1；源列同理钳 w0-1
- 放大：多个 j 落同源 → 自动复制；缩小：部分源无人归属 → 自动跳过
> 用这个闭式公式，**别用边界累加器**（累加器版已验证难对齐，是这个模块反复失败的主因）。

## 数据通路
1. **输入 FIFO**：16 深 × 24bit（寄存器实现）。源侧任何时候都写入（满则 `in_en` 必须被消费侧即时腾空，实际源慢 30 倍不会满）。
2. **S1 水平重采样**：从 FIFO 取源像素 → 写进 dst_w 宽的**乒乓行缓存**（2×640×24）。
   - 每个源像素 i 负责目标列区间 `[owner_x⁻¹(i), owner_x⁻¹(i+1))`，即 `k` 满足 `(2k+1)*sout_x>>15 == i` 的那些 k，按序写入行缓存并置行满标记。
   - 源行计数：每写完 w0 个源像素 = 一整行 → 行槽翻转、置 `row_full[slot]`。
   - 行缓存必须是**同步读 RAM**（`always @(posedge clk) q <= mem[addr]`），保证 TD 抽 BRAM；读口只有 S2 一个读者。
3. **S2 输出机**：逐目标行 dy=0..479、逐列 dx=0..639。
   - 黑边行（dy<offy 或 dy≥offy+dst_h）：直接发 640 拍黑，不等任何源行。
   - 内容行：`sy = owner_y(dy-offy)`（钳 h0-1）；等 `row_full[sy%2]` 才发（`in_eov` 后不再等，用现存数据兜底）。
   - 发一个内容行：offx 拍黑 + dst_w 拍行缓存读出 + 右侧黑到 640。**BRAM 读有 1 拍延迟 → 地址与数据错一拍，必须显式流水**（这是最容易错的地方，TB S03/S07 专门抓它）。
   - 读完把该行 `row_full` 清 0（同槽下一源行复用）。
4. 480 行发完 → `st<=IDLE` + `frame_done` 拉高一拍。

## 硬约束（本项目血泪教训，违反必翻车）
- **Verilog-2001 语法**：iverilog `-g2005` 编译。禁 `input bit`、禁端口默认值、禁无名列块里声明变量（`begin integer x;` 非法，要么具名 `begin : n名 integer x;` 要么在模块级声明）。
- 函数必须 `function automatic`（非自动函数被多处并发调用会出 X）。
- **不要在连续赋值上下文里做多宽加法求和**（`a+b+c>24` 会按 4bit 截断），用 `integer` 累加。
- 组合块里禁止读大 RAM（会退化成 1920:1 mux）→ 一律同步读 + 打拍。
- 复位用 `always @(posedge clk or negedge rst_n)`，全寄存器显式赋初值。
- 目标 ≤ 400 LUT / ≤ 8 个 BRAM9K（当前全片剩 1133 slices、39 块 BRAM）。

## TB 必须覆盖（tools/tests/tb_img_scaler.v，iverilog 可跑）
参考模型用**闭式 owner 公式**在 TB 里独立实现（整数算），与被测逐像素对拍：
| 用例 | 内容 |
|---|---|
| S01 | 640×480 直通：输入唯一图案 `in_data={R,G,B,8'h00}` 按 (x,y) 编码，输出必须**逐拍完全相同**（旁路不变性=明天板测零风险的关键证明） |
| S02 | 1280×960 → 2:1 缩小（wide 路径，dst_h=480，offy=0）：逐像素对拍 |
| S03 | 320×240 → 2:1 放大：逐像素对拍（含 letterbox 边界与 BRAM 错拍） |
| S04 | 800×600 → dst_w=640,dst_h=480（比例刚好 4:3，无黑边）：逐像素对拍 |
| S05 | 1280×720 → wide：dst_h=360, offy=60：**上/下黑边行必须全黑**，内容区逐像素对拍 |
| S06 | 200×1000（极端竖幅）→ tall：dst_h=480, dst_w=96, offx=272：**左右黑边**+内容对拍 |
| S07 | 每源行像素数非 2 的幂（如 w0=777）：专门抓行边界与地址截断 |
| S08 | 连续两帧（同尺寸 + 不同尺寸各一次）：状态机复位干净、无残留 row_full |
| 帧率 | 统计输出总拍数必须恰好 307200（不多不少），frame_done 恰好 1 拍 |

TB 驱动：`in_en` 每 3~8 拍随机给一个像素（模拟 SD 慢速流），行末给 `in_eov`。

## 交付
1. 覆盖写 `user_source/hdl_source/img_scaler.v`
2. 新建 `tools/tests/tb_img_scaler.v`
3. 跑绿：
```
cd C:\td_batch\lab_pro; $env:PATH+=";C:\iverilog\bin"
iverilog -g2005 -o $env:TEMP\sc.vvp user_source\hdl_source\sdiv24.v user_source\hdl_source\img_scaler.v tools\tests\tb_img_scaler.v
vvp $env:TEMP\sc.vvp
```
4. **只报结果**：编译是否通过、几个用例几个 FAIL、最终 LUT/BRAM 估算。不要把大段代码贴回上下文。
