<!-- Copied verbatim from the OneDrive reference folder on 2026-09-21, when that
folder stopped being its own git repository. The folder itself is not versioned:
it is OneDrive-synced and Chinese-named, so TD cannot build from it. The one-click
scripts it holds (1-板子复活一键烧录.bat, TF卡一键修复.bat, 串口注入终端.ps1) stay
there because that is where they are double-clicked; they are not build inputs.
The pre-merge history of that folder is preserved outside the repo at
C:	d_batch\_onedrive_git_backup\onedrive_docs_dot_git (3 commits, bookkeeping only).

# FPGA 嵌入式竞赛 · 资料工作区（非工程仓库）

这个文件夹是**参考资料库**，不是工程主仓库。这里保留一个 git 仓库只为了给本目录的
组织方式留痕；所有代码、方案、验证记录的唯一版本管理主线在别处。

## 两个位置的分工

| 位置 | 角色 | 是否进 git |
|---|---|---|
| `C:\td_batch\lab_pro\` | **工程主仓库**：RTL 源码、仿真台、上位机工具、当前方案 V3/V3.1、30 天路线 | 是（主线，推 GitHub） |
| 本文件夹 | 参考库：官方 SDK 与手册、赛题通知、教学课件、历史归档 | 基本否，见下 |

工程仓库必须留在纯英文路径 `C:\td_batch\`：安路 TD 6.2.168 在中文路径和 OneDrive
同步目录下会异常甚至段错误。本文件夹由 OneDrive 同步，不能作为构建目录。

## 明早板测从这里开始

2026-09-20 夜里已把 v13.0 修复综合、布线出 bit，并装到一键烧录读取的路径上。
按这份清单走，四种观测结果各对应一个下一步，不用临场判断：

`C:\td_batch\lab_pro\docs\hw\20260921_v13_board_check.md`

要点：烧的是 `C:\td_batch\lab_pro\td_project\lab_pro.bit`（构建时间应显示 09-20 21:51）；
回滚 bit 是同目录的 `lab_pro_v12.9_pre_v13.bit`；一键脚本会额外发 `EMG1`
进入应急横幅模式，会盖住要看的图像播放，改用 `auto_demo.ps1 -SkipEmg` 或烧完发 `CLR`。


## 本目录内容

- `HX4S20_Contest_202606\` — 5.7 GB 安路官方资料：TD 工具链、官方例程、原理图、
  EG4S20 手册、康芯开发板手册。**只读依赖，禁止删除、禁止推送。**
- `通知\` — 3 份官方 PDF（第一轮通知、2026 选题指南、2025 国赛测试题）。PDF 已在
  `.gitignore` 内，不进仓库；需要引用时按文件名在本地定位。
- `双FPGA三屏_有效方案与技术计划_20260920_185710\` — 2026-09-20 目标方案原件。
  其内容已按 ASCII 文件名纳入工程仓库 `lab_pro\docs\plan\20260920_dual_fpga_three_screen\`
  并随代码一起版本化；此处保留原始同步副本，如两者不一致，以工程仓库为准。
- `Wireshark资料\`、`安装包\`、`开源参考项目\`、`示例运行结果与可视化\`、
  `FPGA创新设计大赛（安路赛道）\`、`AI资料\` — 参考与课件，不纳入版本管理。
- `99-归档\` — 历史与已作废材料。其中 `superseded_20260920\INDEX.txt` 逐条说明
  为什么作废、权威副本现在在哪里。
- `.workbuddy\` — 前序 agent 的会话与记忆目录，非项目产物；其中的经验教训已复制进
  工程仓库 `docs\history\LESSONS_LEARNED_2026-09.md`。

## 已作废判定的依据

2026-09-20 方案包的「版本边界」一节：不纳入已被替代的 V2 总纲及旧 Word/PDF，避免误用
旧题目与旧分工。据此归档的是 V2 期规划（作品介绍、国一冲刺扩展规划、V2 备赛计划）、
被 `tools/cjk_flash` 取代的原始字模 TXT、被 `tools/` 取代的早期脚本。

官方 SDK 与赛题通知不参与这种「冲突」判定——它们是外部依赖与规则原文，任何本地文件
都不与它们竞争真伪，因此不会因「冲突」被删除。
