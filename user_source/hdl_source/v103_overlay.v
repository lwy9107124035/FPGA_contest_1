//=============================================================================
// v103_overlay —— v10.3 顶层叠加层（扩展1 时间戳 + 扩展4 调参进度条 + 扩展5 VU柱）
// 像素链：vout_base → vout_fx(转场/调色) → osd_banner(字幕层) → 【本模块】 → HDMI
//   多图层混合（扩展1）：图片层 → 效果层 → 字幕层 → 状态层，四级叠加。
// 默认全关（clk_en=0,vu_en=0,无人调参→进度条不出现）→ 未启用时像素逐位零改变。
//=============================================================================
`default_nettype none
module v103_overlay #(
    parameter [24:0] SEC_DIV = 25174999   // 25.175MHz 整分频（TB 用小值加速仿真）
) (
    input  wire        clk,          // video_clk 25.175MHz
    input  wire        rst_n,
    input  wire        de,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,
    input  wire        clk_en,       // "CK 1" 时间戳
    input  wire        vu_en,        // "VU 1" 频谱柱
    input  wire [3:0]  vu0, vu1, vu2, vu3, vu4, vu5, vu6, vu7,
    input  wire [3:0]  br_lvl,
    input  wire [3:0]  gn_lvl,
    input  wire [3:0]  vol_lvl
);
    //-------------------------------------------------------------------------
    // 秒时基（上电 00:00:00 起）
    //-------------------------------------------------------------------------
    reg [24:0] div1s;  reg tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin div1s <= 25'd0; tick <= 1'b0; end
        else begin
            tick <= 1'b0;
            if (div1s >= 25'd25_174_999) begin div1s <= 25'd0; tick <= 1'b1; end
            else div1s <= div1s + 25'd1;
        end
    end
    reg [7:0] ss, mm, hh;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin ss <= 8'd0; mm <= 8'd0; hh <= 8'd0; end
        else if (tick) begin
            if (ss == 8'd59) begin
                ss <= 8'd0;
                if (mm == 8'd59) begin
                    mm <= 8'd0;
                    hh <= (hh == 8'd23) ? 8'd0 : hh + 8'd1;
                end else mm <= mm + 8'd1;
            end else ss <= ss + 8'd1;
        end
    end
    function [3:0] hi_of; input [7:0] v;
        hi_of = (v>=8'd50)?4'd5:(v>=8'd40)?4'd4:(v>=8'd30)?4'd3:(v>=8'd20)?4'd2:(v>=8'd10)?4'd1:4'd0;
    endfunction
    function automatic [3:0] lo_of; input [7:0] v; reg [3:0] h;
    begin h = hi_of(v); lo_of = v - {h,3'd0} - {h,1'b0}; end
    endfunction
    function automatic [3:0] clk_idx; input [2:0] i;
    begin
        case (i)
            3'd0: clk_idx = hi_of(hh);  3'd1: clk_idx = lo_of(hh);
            3'd2: clk_idx = 4'd10;      3'd3: clk_idx = hi_of(mm);
            3'd4: clk_idx = lo_of(mm);  3'd5: clk_idx = 4'd10;
            3'd6: clk_idx = hi_of(ss);  3'd7: clk_idx = lo_of(ss);
            default: clk_idx = 4'd10;
        endcase
    end
    endfunction
    // 数字/冒号 8x16 字模：10 个有效行（原 glyph 第2..11行），MSB=第2行
    function automatic [79:0] font10; input [3:0] g;
    begin
        case (g)
            4'd0:  font10 = 80'h386CC6C6D6D6C6C66C38;
            4'd1:  font10 = 80'h1838781818181818187E;
            4'd2:  font10 = 80'h7CC6060C183060C0C6FE;
            4'd3:  font10 = 80'h7CC606063C060606C67C;
            4'd4:  font10 = 80'h0C1C3C6CCCFE0C0C0C1E;
            4'd5:  font10 = 80'hFEC0C0C0FC060606C67C;
            4'd6:  font10 = 80'h3860C0C0FCC6C6C6C67C;
            4'd7:  font10 = 80'hFEC606060C1830303030;
            4'd8:  font10 = 80'h7CC6C6C67CC6C6C6C67C;
            4'd9:  font10 = 80'h7CC6C6C67E0606060C78;
            default: font10 = 80'h00001818000000181800; // ':'
        endcase
    end
    endfunction
    // 时钟区：x 496..623（8字×16px, 2x横放），y 8..39（2x纵放，字模行落在 r=2..11）
    wire       ck_xok  = de && clk_en && (x>=12'd496) && (x<12'd624) && (y>=12'd8) && (y<12'd40);
    wire [7:0] ck_lx   = x[7:0] - 8'd240;               // (x-496) mod 256 = 0..127 in-band
    wire [3:0] ck_frow = ((y - 12'd8) >> 1);            // 0..15 (2x)
    wire [2:0] ck_ch   = ck_lx[6:4];                     // 字符 0..7
    wire [2:0] ck_col  = ~ck_lx[4:1];                    // 字内列 0..7
    // 取字模第 (ck_frow-2) 行（0..9），仅在 2..11 有效
    wire       ck_ry   = (ck_frow >= 4'd2) && (ck_frow <= 4'd11);
    wire [3:0] ck_ridx = ck_frow - 4'd2;                 // 0..9
    wire [7:0] ck_bm   = font10(clk_idx(ck_ch)) >> ({1'b0, 4'd9 - ck_ridx, 3'b000});
    wire       ck_bit  = ck_bm[ck_col];
    wire [23:0] ck_col24 = 24'hFFFFFF;

    //-------------------------------------------------------------------------
    // 进度条（左上）：3 行 VOL绿/BR黄/GN青，10段×8px，调参后 3s 自动隐藏
    //-------------------------------------------------------------------------
    reg [26:0] free27;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) free27 <= 27'd0; else free27 <= free27 + 27'd1;
    reg [11:0] cur_set;  reg [26:0] latched;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cur_set <= {4'd6,4'd5,4'd5}; latched <= 27'd0; end
        else begin
            if ({vol_lvl,br_lvl,gn_lvl} != cur_set) begin
                cur_set <= {vol_lvl,br_lvl,gn_lvl};
                latched <= free27;
            end
        end
    end
    wire pbar_live = ((free27 - latched) < 27'd75_000_000);  // 回绕安全减法 ≈3.0s
    wire in_pb = de && pbar_live && (y>=12'd8) && (y<12'd32) && (x>=12'd8) && (x<12'd88);
    wire [1:0] pb_row = y[4:3] - 2'd1;                      // 8px 行：y8..15→0,16..23→1,24..31→2
    wire [3:0] pb_lvl = (pb_row==2'd0)?cur_set[11:8]:(pb_row==2'd1)?cur_set[7:4]:cur_set[3:0];
    wire [3:0] pb_seg = (x - 12'd8) >> 3;                   // 0..9
    wire       pb_band = (y[2:0] <= 3'd6);
    wire       pb_lit  = (pb_seg < pb_lvl);
    wire [23:0] pb_col = (pb_row==2'd0)?24'h40FF70:(pb_row==2'd1)?24'hFFE000:24'h40E0FF;
    wire [23:0] pb_back= {2'b0,rgb_in[23:17],2'b0,rgb_in[15:9],2'b0,rgb_in[7:1]}; // 半暗底
    wire       pb_draw = in_pb && pb_band;

    //-------------------------------------------------------------------------
    // VU 柱（底部 8 根，基线 y=413，柱宽24/间距32，高=lvl*5≤45）
    //-------------------------------------------------------------------------
    wire [31:0] vu_all = {vu7,vu6,vu5,vu4,vu3,vu2,vu1,vu0};
    wire [8:0]  vlx    = x - 12'd16;
    wire        in_vu  = vu_en && de && (y>=12'd366) && (y<=12'd413) && (x>=12'd16) && (x<12'd272);
    wire [2:0]  vu_bar = vlx[8:5];                            // (x-16)>>5 0..7
    wire [4:0]  vu_sub = vlx[4:0];                            // (x-16)&31
    wire [3:0]  vu_lvl = vu_all[vu_bar*4 +: 4];
    wire [6:0]  vu_h   = {1'b0,vu_lvl,2'b00} + {3'b0,vu_lvl}; // lvl*4 + lvl = lvl*5 (max 45)
    wire [8:0]  vu_rel = 9'd413 - y;
    wire        vu_draw= in_vu && (vu_lvl != 4'd0) && (vu_sub < 12'd24) && (vu_rel <= {2'b0, vu_h});
    wire [23:0] vu_col = (vu_rel<=9'd15)?24'hFF5050:(vu_rel<=9'd30)?24'hFFE000:24'h30E060;

    //-------------------------------------------------------------------------
    // 顶层混合：时钟 > 进度条 > VU > 透传
    //-------------------------------------------------------------------------
    assign rgb_out = (ck_xok && ck_ry && ck_bit) ? ck_col24
                   : pb_draw ? (pb_lit ? pb_col : pb_back)
                   : vu_draw ? vu_col
                   : rgb_in;
endmodule
`default_nettype wire
