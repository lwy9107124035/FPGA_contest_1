//=============================================================================
// vout_fx —— v10.3 像素特效级（扩展2 转场 + 扩展4 亮度/对比度 + 扩展5 包络）
// 位置：TOP 里 vout_base →【本模块】→ u_osd_banner.rgb_in（效果层永远在字幕之下）
// 小白解释见各段注释；综合目标 <300 slices + 少量 DSP（28 个空闲）。
//=============================================================================
`default_nettype none
module vout_fx #(
    parameter FX_BLINDS = 1'b1        // 降级开关：综合超预算时置 0 断掉百叶窗
) (
    input  wire        clk,          // video_clk 25.175MHz
    input  wire        rst_n,
    input  wire        de,
    input  wire [9:0]  px,           // osd_x 0..639
    input  wire [8:0]  py,           // osd_y 0..479
    input  wire [2:0]  disp_idx,     // 显示缓冲号（sd_card_bmp.disp_buf_idx 直出）
    input  wire [3:0]  br_lvl,       // 亮度 0..9（5=标准）
    input  wire [3:0]  gn_lvl,       // 对比度 0..9（5=标准）
    input  wire [1:0]  fd_mode,      // 0 硬切 1 淡入 2 擦拭 3 百叶窗
    input  wire        frame_start,  // 每帧一拍
    input  wire        audio_valid,  // 48k 样本节拍（alarm_tone，同域）
    input  wire [23:0] audio_left,   // 有符号样本
    output wire [3:0]  vu_lvl0, output wire [3:0] vu_lvl1,
    output wire [3:0]  vu_lvl2, output wire [3:0] vu_lvl3,
    output wire [3:0]  vu_lvl4, output wire [3:0] vu_lvl5,
    output wire [3:0]  vu_lvl6, output wire [3:0] vu_lvl7,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);
    //-------------------------------------------------------------------------
    // 1) 亮度/对比度（扩展4）：y=(v-128)*gain/64 + 128 + bias，饱和
    //-------------------------------------------------------------------------
    reg signed [8:0] gain_s;         // 对比度增益 ×64
    always @(*) case (gn_lvl)
        4'd0: gain_s = 9'sd16;   4'd1: gain_s = 9'sd32;
        4'd2: gain_s = 9'sd48;   4'd3: gain_s = 9'sd56;
        4'd4: gain_s = 9'sd60;   4'd5: gain_s = 9'sd64;   // 标准
        4'd6: gain_s = 9'sd72;   4'd7: gain_s = 9'sd88;
        4'd8: gain_s = 9'sd104;  4'd9: gain_s = 9'sd120;
        default: gain_s = 9'sd64;
    endcase
    wire signed [8:0] bias_s = ($signed({5'b0, br_lvl}) - 9'sd5) * 9'sd20; // 亮度偏置 ±80

    function automatic [7:0] fx_ch;
        input [7:0] v; input signed [8:0] g; input signed [8:0] b;
        reg signed [17:0] t;
    begin
        // NOTE: 符号扩展必须包在 $signed() 里；写成 {$signed(10'b0),v} 会使
        // 拼接结果为无符号，减法在负值时环绕成大正数→三通道全饱和 FF（真 bug）。
        t = (($signed({10'b0, v}) - 18'sd128) * g) >>> 6;   // *gain/64（算术移位）
        t = t + 18'sd128 + b;
        fx_ch = (t < 18'sd0) ? 8'd0 : (t > 18'sd255) ? 8'd255 : t[7:0];
    end
    endfunction
    wire enh_bypass = (br_lvl == 4'd5) && (gn_lvl == 4'd5);
    wire [23:0] enh_px = enh_bypass ? rgb_in
        : { fx_ch(rgb_in[23:16], gain_s, bias_s),
            fx_ch(rgb_in[15:8],  gain_s, bias_s),
            fx_ch(rgb_in[7:0],   gain_s, bias_s) };

    //-------------------------------------------------------------------------
    // 2) 转场（扩展2）：换图后 32 帧（≈0.53s）从黑场揭开新图，帧首发车无撕裂
    //-------------------------------------------------------------------------
    reg [2:0] idx_d;
    reg       arm;
    reg [7:0] t;                     // 进度 0..255（255=完成直通）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin idx_d <= 3'd7; arm <= 1'b0; t <= 8'd255; end
        else begin
            idx_d <= disp_idx;
            if (disp_idx != idx_d) arm <= 1'b1;
            if (frame_start) begin
                if (arm)              begin t <= 8'd0;   arm <= 1'b0; end
                else if (t == 8'd248) t <= 8'd255;
                else if (t < 8'd255)  t <= t + 8'd8;
            end
        end
    end
    wire xfx_on = (t != 8'd255) && (fd_mode != 2'd0);

    // 淡入：v*ta/256（ta=t+1，移位截位近似，0 除法器）
    wire [7:0] ta = t + 8'd1;
    wire [15:0] er = enh_px[23:16] * ta;
    wire [15:0] eg = enh_px[15:8]  * ta;
    wire [15:0] eb = enh_px[7:0]   * ta;
    wire [23:0] fade_px = { er[15:8], eg[15:8], eb[15:8] };
    // 擦拭：边界 b=(t*5)>>1（=t*640/256），x<b 显示，其余黑
    wire [10:0] wipe_b = {1'b0, t, 2'b00} + {2'b0, t};       // t*4 + t = t*5
    wire        wipe_ok = ({1'b0, px} < (wipe_b >> 1));
    // 百叶窗：10 竖条×64px，条 i 于 t>=(i+1)*24 揭开
    function automatic [7:0] slat_thr;
        input [3:0] i;
    begin
        case (i)
            4'd0: slat_thr = 8'd24;  4'd1: slat_thr = 8'd48;
            4'd2: slat_thr = 8'd72;  4'd3: slat_thr = 8'd96;
            4'd4: slat_thr = 8'd120; 4'd5: slat_thr = 8'd144;
            4'd6: slat_thr = 8'd168; 4'd7: slat_thr = 8'd192;
            4'd8: slat_thr = 8'd216; default: slat_thr = 8'd240;
        endcase
    end
    endfunction
    wire blinds_ok = (t >= slat_thr(px[9:6]));

    wire [23:0] mask_px = (fd_mode == 2'd1) ? fade_px
                        : (fd_mode == 2'd2) ? (wipe_ok  ? enh_px : 24'd0)
                        : (fd_mode == 2'd3) ? ((FX_BLINDS && blinds_ok) ? enh_px : 24'd0)
                        : enh_px;
    assign rgb_out = xfx_on ? mask_px : enh_px;

    //-------------------------------------------------------------------------
    // 3) 音频包络 + 8 柱伪频谱（扩展5；接 PCM 音乐时只改本段，接口不变）
    //-------------------------------------------------------------------------
    wire [23:0] ampx = audio_left[23] ? (~audio_left + 24'd1) : audio_left;
    wire [5:0]  amp6 = (ampx[23:17] > 7'd25) ? 6'd25 : ampx[22:17]; // 0..25 定标
    reg  [5:0]  env;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) env <= 6'd0;
        else if (audio_valid) begin
            if (amp6 > env)   env <= amp6;             // 快攻：直接跟
            else if (env)     env <= env - 6'd1;       // 慢放：48k/s 衰减
        end
    end
    function automatic [3:0] bar_lvl;
        input [2:0] i; input [5:0] e;   // env ??????????????
        reg [3:0] w; reg [12:0] v;
    begin
        case (i)
            3'd0: w = 4'd7; 3'd1: w = 4'd9; 3'd2: w = 4'd5; 3'd3: w = 4'd8;
            3'd4: w = 4'd6; 3'd5: w = 4'd9; 3'd6: w = 4'd4; default: w = 4'd7;
        endcase
        v = ({8'd0, e} * {5'd0, w}) >> 4;              // env*w/16
        bar_lvl = (v > 13'd9) ? 4'd9 : v[3:0];
    end
    endfunction
    assign vu_lvl0 = bar_lvl(3'd0, env);  assign vu_lvl1 = bar_lvl(3'd1, env);
    assign vu_lvl2 = bar_lvl(3'd2, env);  assign vu_lvl3 = bar_lvl(3'd3, env);
    assign vu_lvl4 = bar_lvl(3'd4, env);  assign vu_lvl5 = bar_lvl(3'd5, env);
    assign vu_lvl6 = bar_lvl(3'd6, env);  assign vu_lvl7 = bar_lvl(3'd7, env);
endmodule
`default_nettype wire
