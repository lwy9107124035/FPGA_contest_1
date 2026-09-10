`timescale 1 ns / 1 ps
// =============================================================================
// alarm_tone.v — HDMI 应急警报音源 (OSD v4, 2026-09-04)
// 原理承袭官方 lab_ex5_i2s/hdmi_audio_tone_pcm_scale.v（48kHz 分数分频 +
// 相位累加器方波），三点自研升级：
//   1) 音容从"八音盒旋律"换成**两音警笛**：880Hz / 622Hz 各 0.25s 交替，
//      即经典"哇——哦——"应急 sirens 听感；
//   2) 音量 AMP 由编译期参数改为**运行时 VOL[3:0] 输入**（0~9 十级，
//      数字衰减，纯乘法无失真），来自串口命令 "VOL <0-9>"；
//   3) tone_en=0 时样本强制静音但 **audio_valid 持续打点** —— HDMI 音频
//      通道与 ACR 时钟再生握手不中断，避免显示器在应急切换瞬间出现
//      "音频流断开"提示或爆音。
// 相位增量 = round(f × 2^32 / 48000)：880→78741067, 622→55655618。
// 时钟域：video_clk 25.175MHz（与 HDMI 内核像素时钟同域，无需跨域）。
// =============================================================================
module alarm_tone (
    input  wire        I_clk,            // video_clk 25.175MHz
    input  wire        I_rst,            // 高有效（rst_all）
    input  wire        tone_en,          // 1=播放警笛（EMG 模式），0=静音但保持流
    input  wire [3:0]  vol,              // 音量 0..9（>9 视为静音）
    output reg         O_audio_valid,    // 每 48kHz 一拍
    output reg  [23:0] O_audio_left_data,
    output reg  [23:0] O_audio_right_data
);
    localparam integer CLK_HZ        = 25_175_000;
    localparam integer SAMPLE_RATE   = 48_000;
    localparam integer HOLD_SAMPLES  = 12_000;           // 0.25s @48k
    localparam [31:0]  INC_HI        = 32'd78741067;     // 880Hz
    localparam [31:0]  INC_LO        = 32'd55655618;     // 622Hz

    // 音量十级（24bit 有符号满幅 ±8388607；9 级=26% 幅，与官方 2000000 同量级偏上）
    function [23:0] amp_lut;
        input [3:0] v;
    begin
        case (v)
            4'd0:    amp_lut = 24'd0;
            4'd1:    amp_lut = 24'd300_000;
            4'd2:    amp_lut = 24'd500_000;
            4'd3:    amp_lut = 24'd750_000;
            4'd4:    amp_lut = 24'd1_050_000;
            4'd5:    amp_lut = 24'd1_400_000;
            4'd6:    amp_lut = 24'd1_800_000;
            4'd7:    amp_lut = 24'd2_250_000;
            4'd8:    amp_lut = 24'd2_750_000;
            4'd9:    amp_lut = 24'd3_300_000;
            default: amp_lut = 24'd0;
        endcase
    end
    endfunction

    reg  [31:0] S_sample_acc;
    reg  [31:0] S_phase_acc;
    reg  [31:0] S_hold_cnt;
    reg         S_toggle;                 // 0=低音 622, 1=高音 880
    reg  [23:0] S_amp_r;                  // 寄存后的幅值（切断 LUT 到输出的组合路径）

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            O_audio_valid      <= 1'b0;
            O_audio_left_data  <= 24'd0;
            O_audio_right_data <= 24'd0;
            S_sample_acc       <= 32'd0;
            S_phase_acc        <= 32'd0;
            S_hold_cnt         <= 32'd0;
            S_toggle           <= 1'b0;
            S_amp_r            <= 24'd1_800_000;          // 默认 vol6 对应幅值
        end else begin
            O_audio_valid <= 1'b0;
            // 音量变化 1 拍生效（寄存，无毛刺）
            S_amp_r <= amp_lut(vol);

            if (S_sample_acc + SAMPLE_RATE >= CLK_HZ) begin
                S_sample_acc  <= S_sample_acc + SAMPLE_RATE - CLK_HZ;
                O_audio_valid <= 1'b1;                    // 流永不断（特性3）

                // 相位推进：两音交替
                S_phase_acc <= S_phase_acc + (S_toggle ? INC_HI : INC_LO);

                // 方波样本：phase MSB 定正负；tone_en=0 强制静音
                if (tone_en && S_phase_acc[31]) begin
                    O_audio_left_data  <=  S_amp_r;
                    O_audio_right_data <=  S_amp_r;
                end else begin
                    O_audio_left_data  <= -S_amp_r;       // tone_en=0 且 amp 可为0 → 静音
                    O_audio_right_data <= -S_amp_r;
                end
                if (!tone_en) begin
                    O_audio_left_data  <= 24'd0;
                    O_audio_right_data <= 24'd0;
                end

                // 0.25s 换音
                if (S_hold_cnt >= HOLD_SAMPLES - 1) begin
                    S_hold_cnt <= 32'd0;
                    S_toggle   <= ~S_toggle;
                end else begin
                    S_hold_cnt <= S_hold_cnt + 32'd1;
                end
            end else begin
                S_sample_acc <= S_sample_acc + SAMPLE_RATE;
            end
        end
    end
endmodule
