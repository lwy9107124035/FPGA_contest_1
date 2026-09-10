# WP-J 结案报告 —— v9.2 板上 MSG 行 CJK 退化 · osd_banner 侦破

**日期**: 2026-09 板上回归案 | **工具产物目录**: `%TEMP%\wpj_work\`（全部保留）
**对象**: `C:\td_batch\lab_pro\user_source\hdl_source\osd_banner.v`（v8 ascii BRAM 改造后，现版未做任何修改——见§结论）

---

## ① 结论：**无罪释放 osd_banner.v**（RTL 级差分等价，CJK 取回路全活）

用"真字库应答器"对比台（golden 与现版各配一台独立应答器、同拍同料）跑 640×480 光栅 +
真 GB2312 混排 + loader_inhibit 翻转 + EMG 帧 + 负控，**三组应答延迟**：

| 运行 | 比对拍数 | f0–f14 干净窗口失配 | xcd req/addr/new/busy 失配 | 完成取字 n/g | CJK 点亮覆盖 | 负控 1-bit 炸出 | 撤 bit 后新增 |
|---|---|---|---|---|---|---|---|
| LAT=580(≈23µs 真机) `run_real_xcd.log` | 6,274,560 | **0** | 0 | 67/67 | 38,588 px | 22 px（逐位吻合注入点） | 0 |
| LAT=4  `run_lat4.log` | 6,274,560 | **0** | 0 | 67/67 | 38,588 px | 22 | 0 |
| LAT=2000  `run_lat2000.log` | 6,274,560 | **0** | 0 | 67/67 | 38,588 px | 22 | 0 |

**负控铁证**（比对器不瞎）：仅在 golden 侧应答器把 `你/好/全/绿…` 点阵 row5 的 bit0 异或翻转 1 位，
失配立刻且**只在** y=458/459（row5 的两个 2x 放大扫描线）× x=slot·16+15（word bit0=槽最右像素）爆出，
槽号与 TXT6 的 CJK 槽 0..9/20 一一对应（日志 MISMATCH #1–#20）；撤掉翻转后失配永久冻结（+0）。
即 CJK"取回→G_TAKE→G_WR→glyph_ram→rd_word 预发→像素"整条路在两台 DUT 上都真实跑通且逐拍一致。

激励覆盖（f1–f17）：`"Hello, world! 你好，v9 全绿。"` 逐码（C4E3/BAC3/A3AC/C8AB/C2CC/A142）→
14-CJK 第二文本 → **inhibit 整帧压制提交 + 解除后补取** → **帧中途（y=300）inhibit 落沿边取字** →
GB2312 边角码（A1A1/FEFE/A1FE/FEA1/A1FF 越界/FE41/0100/00FF…）→ EMG 三短语帧 → 负控帧。
TEST-A：现版 `ascii_rom` 4096/4096 词 == 原 `glyph8x16`（`datacheck.py` 独立复核同结果，
`cjk16` 448 行数据两版逐字节相等）。

## ② 为什么"定罪清单 a–d"全部落空（结构证据）

对两文件剥离 ROM 数据块后全量 diff（`diff_stripped.txt`，548 行，全部差异就这么多）：

- **CJK 路径逐字符不变**：`glyph_ram` 声明/读口（L221–236 区域）、刷新 FSM
  （G_IDLE/G_SCAN/G_WAIT/G_TAKE/G_WR、`req_v_r/addr_r`、§4 地址乘法式）、写口 `g_wr_act` 块，
  golden 与现版**文本相同**；`msg_flat_a/b` 写逻辑仅多第三份镜像 `msg_flat_c`（同拍同码，无版本差）。
- **a) 半/全角门控**：`msg_on = line_sel && cell_ok && ((m_half&&m_half_on)||(m_full&&m_full_on))`
  两版同式；现版 `mglyph8=ascii_q` 无条件出数**但被 `m_half` 门死**（m_half 与 m_full 互斥），
  模拟中 CJK 槽像素 100% 由 rd_word 决定——未覆盖。
- **b) msg_flat_c 预发 vs CJK 请求发生器**：FSM 用 `msg_flat_b`+自带 `g_s`，与 `slotr/dyr` 无共享
  寄存器；67 笔事务 `req_v/addr_v` 两版逐拍全等（mism_cfg=0 直接证伪）。
- **c) 全角双字节槽推进**：一槽=16px=1 列，`xnp/ynp` 预发式两版同一份代码，逐字未动。
- **d) ascii 读使能共门**：两版 `rd_word` 读口都是"每拍无条件同步读"（golden L223–225 ≡ 现版 L4628–4631），
  `ascii_q` 并入同一 always 块不改变 `rd_addr` 的任何采样。

## ③ 真凶在哪：证据链与下一步（osd 之外）

现版 osd 与黄金版在**任何输入序列下**（含 xcd 应答时序畸形，LAT 4→2000 全等价）行为一致，
且板上 ASCII/小写/标点（v8 唯一实际改动的半角 ROM 路 + 新 BRAM）全部正常。
⇒ **要令 v9.2 板上 CJK 退化，osd_banner 的输入必与 v7.2 时代不同**。按优先级：

1. **字库区物理损坏/未装载（头号嫌疑，v7.3/7.4 `flash_pp`+`sd_card_bmp` 同窗口落地）**
   `flash_pp.v` 是 LOAD v1 编程引擎：块擦除命令 `0xD8 @ 0x00000/0x10000/.../0x40000`——
   **GB2312 字库地址空间(≤0x3FE00)整段在可擦范围内**。板上 CJK 变废而 ASCII(ROM 内置)/EMG(cjk16 内置)
   免疫，最简洁的单一解释就是"取字取回 0xFF/垃圾/全 0"。
   ▶ 立即可做的片上自检：用 `flash_pp cmd=2'd3` 普通读抽验 `你` 槽（addr=((0xC4-0xA1)*94+(0xE3-0xA1))*32
   = 0x1A380）应等 HZK16 的 C4E3 32 字节；若读回 0xFF/错码 → 重烧字库即愈，结案转 loader/地址复核。
2. **`loader_inhibit` 常 1 / xcd 在途被抢总线（系统死锁，非本版逻辑）**
   `G_IDLE/G_SCAN` 见 `loader_inhibit=1` 永不发起（设计如此，两版相同）。顶层
   `assign c_flash_cs = loader_active ? pp_cs : gf_cs` 用 clk50 域即时切换：**若 loader/pp 在
   glyph_fetch 在途拍抢走 SPI**，`glyph_fetch` 无超时/无响应校验，36 字节盲移位照常打 `fetch_done`
   ——回给 banner 的是别的会话的数据（上屏即乱码）；若 loader 侧把 xcd `busy_v` 卡死，则 banner FSM
   永远停在 G_WAIT（**G_WAIT 无超时、`drop_err_v`/`glyph_ready_v` 在顶层全部悬空**，top L559/L563，
   无任何可见性）。两版 golden/current 同样脆弱——所以它是"触发条件变新了"（v7.3/7.4 引入 flash_pp
   并发），不是 v8 代码错。▶ 建议主线：接出 `drop_err_v/out_addr_v` 到调试口；查 loader_active 波形
   （`msg_ink` 卡死黑匣子 v10 连线已在 top L74 预留）。
3. **若实拍板上是"字面 '?' 字形"而非空白/乱块**：`'?'`(0x3F) 半角码只可能由 **msg_ink 写进槽**
   （osd 无全角→半角退化逻辑，现版逐拍与 golden 等价亦排除渲染端）。我读了 msg_ink.v 取证：
   v9 `san` 存储路 ≥0xA1 原样透传（L257–262, L525），命令影子用 `upc(s0..s5)` 仅限 6 字节头
   （L421–426），未见把 CJK 替换成 3F 的通路——初步无辜，但若板上确认字面 '?'，重点查
   **发送端/上位工具把非 ASCII 打成 '?'**（串口工具、终端编码），而不是 FPGA。
4. EMG 大字号帧已在我的对比台 f12–f14 验证等价（cjk16 数据两版逐字节相等）。
   ⇒ **板上 EMG 若正常**：与"字库区/取字链损坏"自洽（EMG 不依赖 flash）；
   **若 EMG 也废**：嫌疑转向注入路（msg_ink 之后的槽内容）——但 osd 渲染两版等价不受影响。

## ④ 排除性旁证：TD 合成日志取证（`td_project\*.log`）

- v8+ 构建（19:53/20:50/21:27/syn_run）：`extracting RAM 'glyph_ram'`+`'ascii_rom'` 均在，
  `msg_flat_*` 未被抽 RAM（守约）。新增仅 `HDL-5314 net 'ascii_rom' does not have a driver`
  （initial→BRAM 初值的例行告警；**板上 ASCII 正常=BRAM 内容正确=不构成 CJK 凶器**）。
- `SYN-2595 u_osd_banner/ramread0_syn_4 → PDPW/SP`、`Infer Logic BRAM(u_osd_banner/...)` 在
  v7.x 正常构建（16:05/17:57/18:19/18:39，当时**无** ascii_rom）就已逐字存在 → 非 v8 新增，无罪。
- `SYN-2501 Inferred 15 ROM instances`、BRAM 3→4（+ascii_rom 属预期）；Logic DRAM 恒 1（flash_pp pbuf）。
- 慢性告警 `paylen_r used before declaration`（msg_ink）与 `sd_dbg/loader_active_v` 隐式声明对
  在**每个**构建（含 v7.2 正常件）中都存在，非退化差分。

## ⑤ 四项回归状态（本案走"无罪"分支，修复未发生）

| 项 | 结果 |
|---|---|
| 对比台 0 失配（CJK+inhibit 段） | ✅ 0/6.27M 拍 ×3 LAT |
| 负控炸 1 位 | ✅ 22 px，位置逐位可解释；撤后 +0 |
| 原 WP-G 静态 xcd TB 重跑 | ✅ `run_wpg_static_recheck.log` ALL PASS（15,191,040 拍 0 失配，TEST-A 4096/0，NEG-C 128/0）——现版文件未被本次工作改动，既有验证完好 |
| `iverilog -g2005 -Wall -tnull osd_banner.v` | ✅ 0 error / 0 warning（`lint_osd.txt` 空） |

## ⑥ 风险与遗留

- **黄金基线假设**：以 `osd_rom_work\osd_banner_golden.v`（标称 v7.2+COL）为"板测正常"的代表。
  若 v7.2 实刷机另有差异，请主线用仓库 tag 重出基线再跑（对比台 30 分钟可复跑）。
- **差分方法盲区**：本台只答"v8 改坏了没有"，不答"v6 契约实现是否健壮"。G_WAIT 无超时、
  drop_err_v 悬空、SPI mux 抢拍这三处**新旧共有的脆弱点**建议后续版本加防护（与本案定罪无关）。
- 应答器模型按契约 §5/FSM 注释行为（new_v 拍 out_v 仍旧、结束沿更新、busy 与 new_v 同拍清）；
  真实 glyph_xcd 若偏离，两 DUT 受扰相同，差分结论不受影响，但绝对时序保真以 RTL 契约为准。
- 未触碰 `sd_card_bmp.v/msg_ink.v/top/tools`（只读取证），未碰 COM4，`osd_banner.v` **零改动**。

## 附：产物清单（`%TEMP%\wpj_work\`）

`xcd_resp.v` 应答器模型 · `tb_cjk_cmp.v` 双 DUT 差分 TB · `tb_golden_fn.v`(拷贝) ·
`wpj_cmp.vvp / wpj_fast.vvp / wpj_slow.vvp` · `run_real_xcd.log / run_lat4.log / run_lat2000.log` ·
`run_wpg_static_recheck.log` · `diff_stripped.txt`(全量结构 diff) · `cur_stripped.v / gld_stripped.v` ·
`datacheck.py / mkdiff.py` · `lint_osd.txt`

---

# v1.1 增补（接主线案情通报：报案系测试脚本 Ascii 编码把"你好全绿"打成字面 0x3F 的误报）

按通报要求把本台定位为**项目首个"CJK 真回话→上屏"验收资产**收口，并补大偏移槽位与
g_addr 19bit 上限审计（TB 增加 req 监视：bit19/32B 对齐断言 + 指定槽位命中计数，TXT5 加
FEFF/FFFF 极限码）。重跑 LAT=580/4 两配置（`run_v11_lat580.log` / `run_v11_lat4.log`）：

| 项 | 结果（两配置一致） |
|---|---|
| ① 对比台干净窗口 f0–f14 | **0 失配** / 6,274,560 拍（预期无罪 → **无罪确认**；真失配即重大发现——未出现） |
| ① g_addr 19bit 审计 | 69 笔 req **violation=0**（无 bit19 置位、恒 32B 对齐）；max addr = **285760 = 0x45C40 < 2^19**（FFFF 码 → g_sum 8930 ×32） |
| ① 指定大偏移槽位命中 | 你 3356×3 / 好 2384×2 / 全 3676×5 / 绿 3145×4；FEFF-8836、FFFF-8930 各×1 |
| ② 负控 1-bit | 炸 22 px（row5 逐位吻合），撤后 +0 |
| ③ 静态 xcd 旧 TB 回归 | ALL PASS（15,191,040 拍 0 失配，`run_wpg_static_recheck.log`） |
| 附 | CJK 点亮像素 39,564；取字 69/69 双边同步；req/addr/new/busy 逐拍全等 |

**小勘误（顺带发现，非缺陷）**：osd_banner.v L4653 注释"addr=((qu\*94)+wei)\*32 (<=261664, 19b)"
——按 8bit 码全域 qu,wei∈0..94 实际最大 **285760**（注释值 261664 偏小 ~9%），但仍在 19bit 内，
`{1'b0, g_sum, 5'd0}` 无截断风险（本次审计实证）。建议主线顺手改注释，与本判决无关。

**验收资产使用说明**（主线后续可复用）：
`iverilog -g2005 -DLATV=580 -o x.vvp osd_banner.v osd_banner_golden.v xcd_resp.v tb_cjk_cmp.v && vvp x.vvp`
golden 版可随时换成任意基线文件（module 名保持 `osd_banner_golden`）；`LATV` 改应答时延即可
压力不同 interleaving；负控注入点在 f15（flip_g），任何未来改动弄坏 CJK 取回路都会在 f1–f14
干净窗口立刻报数，且像素坐标自带定位信息。

