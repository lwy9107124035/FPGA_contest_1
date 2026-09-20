> 交接说明：本文件是历史核查/检查项参考。旧分工、日程、SPI路线、工时与历史进度不作为当前实施依据；以V3架构、V3.1预算和30天单人技术路线为准。外部硬件资料路径请按队友本机位置映射。

# 本地审查证据索引

审查日期：2026-09-19。仅静态审查；历史构建报告不代表当前源码重新构建结果。

工程清单引用 45 个 File 路径；按工程目录解析缺失 0 个。

## top_tf_hdmi_audio.v

[原文件](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/top_tf_hdmi_audio.v)

- [第 28 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/top_tf_hdmi_audio.v:28)：`parameter MEM_DATA_BITS = 32;`
- [第 101 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/top_tf_hdmi_audio.v:101)：`wire        axis_s_ready;`
- [第 114 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/top_tf_hdmi_audio.v:114)：`assign rst_all = ~rst_n | ~audio_pll_lock;`
- [第 154 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/top_tf_hdmi_audio.v:154)：`.SCAN_MAX_SECTOR   (32'd131071),`
- [第 162 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/top_tf_hdmi_audio.v:162)：`.bmp_width         (16'd640),`
- [第 376 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/top_tf_hdmi_audio.v:376)：`.O_axis_s_ready     (axis_s_ready),`

## bmp_read.v

[原文件](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/bmp_read.v)

- [第 65 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/bmp_read.v:65)：`wire [31:0] next_scan_sector_if_miss;`
- [第 68 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/bmp_read.v:68)：`assign header_match = (header_0 == "B") &&`
- [第 70 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/bmp_read.v:70)：`(width[15:0]  == bmp_width) &&`
- [第 79 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/bmp_read.v:79)：`assign next_scan_sector_if_miss  = scan_sector + 32'd1;`
- [第 267 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/bmp_read.v:267)：`sd_sec_read_addr <= next_scan_sector_if_miss;`
- [第 268 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/bmp_read.v:268)：`scan_sector      <= next_scan_sector_if_miss;`
- [第 307 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/bmp_read.v:307)：`sd_sec_read_addr <= sd_sec_read_addr + 32'd1;`

## sd_card_bmp.v

[原文件](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/sd_card_bmp.v)

- [第 210 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/sd_card_bmp.v:210)：`if (load_busy && source_done_seen && write_finish_pulse) begin`
- [第 213 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/sd_card_bmp.v:213)：`disp_buf_idx          <= pending_buf_idx;`

## frame_fifo_read.v

[原文件](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/frame_fifo_read.v)

- [第 61 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/frame_fifo_read.v:61)：`reg[1:0]                             read_addr_index_d0;         //synchronize to 'mem_clk' clock domain first`
- [第 92 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/frame_fifo_read.v:92)：`read_addr_index_d0 <= 2'b00;`
- [第 102 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/frame_fifo_read.v:102)：`read_addr_index_d0 <= read_addr_index;`
- [第 103 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/frame_fifo_read.v:103)：`read_addr_index_d1 <= read_addr_index_d0;`
- [第 134 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/hdl_source/SD/frame_fifo_read.v:134)：`if(state == S_ACK)`

## timing.sdc

[原文件](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/constraints_source/timing.sdc)

- [第 45 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/constraints_source/timing.sdc:45)：`#      set_clock_groups -exclusive ...`
- [第 53 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/constraints_source/timing.sdc:53)：`set_clock_groups -exclusive \`
- [第 63 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/constraints_source/timing.sdc:63)：`set_clock_groups -asynchronous \`
- [第 75 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/user_source/constraints_source/timing.sdc:75)：`# set_clock_groups -asynchronous \`

## final_timing.rpt

[原文件](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/final_timing.rpt)

- [第 3 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/final_timing.rpt:3)：`Generated           : Fri Apr 24 18:16:15 2026`
- [第 8 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/final_timing.rpt:8)：`STA coverage        : 95.97%`
- [第 27 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/final_timing.rpt:27)：`SWNS: -6.699ns, STNS: -293.216ns`

## HDMI1.4b_Transmitter_v1.0_phy.area

[原文件](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/HDMI1.4b_Transmitter_v1.0_phy.area)

- [第 11 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/HDMI1.4b_Transmitter_v1.0_phy.area:11)：`#lut                     3971   out of  19600   20.26%`
- [第 12 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/HDMI1.4b_Transmitter_v1.0_phy.area:12)：`#reg                     3790   out of  19600   19.34%`
- [第 14 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/HDMI1.4b_Transmitter_v1.0_phy.area:14)：`#lut only              1347   out of   5137   26.22%`
- [第 15 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/HDMI1.4b_Transmitter_v1.0_phy.area:15)：`#reg only              1166   out of   5137   22.70%`
- [第 17 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/HDMI1.4b_Transmitter_v1.0_phy.area:17)：`#bram                      20   out of     64   31.25%`
- [第 21 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/HDMI1.4b_Transmitter_v1.0_phy.area:21)：`#dsp                        0   out of     29    0.00%`
- [第 26 行](D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯/lab_ex5_i2s/src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1/HDMI1.4b_Transmitter_v1.0_phy.area:26)：`#pll                        3   out of      4   75.00%`

## 官方规则与硬件来源

- [全国大学生嵌入式芯片与系统设计竞赛'2026FPGA赛道选题指南-安路科技 (1).pdf](<D:/fpga/anlu/anlu/anlu/全国大学生嵌入式芯片与系统设计竞赛'2026FPGA赛道选题指南-安路科技 (1).pdf>)
- [赛题解析一.pptx](<D:/fpga/anlu/anlu/anlu/赛题解析一.pptx>)
- [EG4S20数据手册.pdf](<D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/6_EG4S20数据手册/EG4S20数据手册.pdf>)
- [HX4S20开发板手册-HDL版2410.pdf](<D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/9_康芯开发板使用手册及实验平台/HX4S20开发板手册-HDL版2410.pdf>)
- [7_HDMI.pdf](<D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/3_原理图/开发板原理图/7_HDMI.pdf>)
- [4_GPIO.pdf](<D:/fpga/anlu/anlu/anlu/HX4S20_Contest_202606.zip/HX4S20_Contest_202606/HX4S20_Contest_202606/3_原理图/开发板原理图/4_GPIO.pdf>)

指南：PDF 物理页 14–15 为选题一和评分；PPT 第 5、6、18–21 页为基础、扩展及最终集成要求；芯片手册 PDF 物理页 3–4 为资源；板卡手册第 8 页为 HDMI_A（物理页以阅读器显示为准）。

