`timescale 1ns/1ps
//=============================================================================
// tb_v103_pix —— vout_fx（扩展2 转场 + 扩展4 调色）与 v103_overlay（时钟/进度条/VU）
// 期望值全部手算标注。关键金样：全默认（br5 gn5 fd0 en=0）→ 逐位直通。
//=============================================================================
module tb;
    reg clk=0, rst_n=0;
    always #20 clk = ~clk;                 // 25MHz 近似
    reg de=1;
    reg [9:0] px=0; reg [8:0] py=0;
    reg [2:0] disp_idx=0;
    reg [3:0] br=5, gn=5;
    reg [1:0] fd=0;
    reg frame_start=0;
    reg aud_v=0; reg [23:0] aud_l=0;
    reg [23:0] rgb_in=0;
    wire [23:0] rgb_out;
    wire [3:0] v0,v1,v2,v3,v4,v5,v6,v7;

    vout_fx dut_fx(
        .clk(clk), .rst_n(rst_n), .de(de), .px(px), .py(py),
        .disp_idx(disp_idx), .br_lvl(br), .gn_lvl(gn), .fd_mode(fd),
        .frame_start(frame_start), .audio_valid(aud_v), .audio_left(aud_l),
        .vu_lvl0(v0), .vu_lvl1(v1), .vu_lvl2(v2), .vu_lvl3(v3),
        .vu_lvl4(v4), .vu_lvl5(v5), .vu_lvl6(v6), .vu_lvl7(v7),
        .rgb_in(rgb_in), .rgb_out(rgb_out));

    integer checks=0, fails=0;
    task ck(input [8*46-1:0] name, input cond);
        begin checks=checks+1;
            if(cond) $display("PASS %0s", name);
            else begin fails=fails+1; $display("FAIL %0s  got=%h", name, rgb_out); end
        end
    endtask
    task fr1; begin @(negedge clk); frame_start=1; @(negedge clk); frame_start=0; end endtask

    // 叠加层端口
    reg oen=0, ven=0; reg [3:0] vol=6;
    wire [23:0] ov_out;
    v103_overlay dut_ov(.clk(clk), .rst_n(rst_n), .de(de),
        .x({2'd0,px}), .y({3'd0,py}), .rgb_in(24'hABCDEF), .rgb_out(ov_out),
        .clk_en(oen), .vu_en(ven),
        .vu0(v0),.vu1(v1),.vu2(v2),.vu3(v3),.vu4(v4),.vu5(v5),.vu6(v6),.vu7(v7),
        .br_lvl(br), .gn_lvl(gn), .vol_lvl(vol));

    integer i;
    integer vsum, i2;
    task calc_vsum; begin vsum = 0; for(i2=0;i2<8;i2=i2+1) vsum = vsum +
        (i2==0?v0:i2==1?v1:i2==2?v2:i2==3?v3:i2==4?v4:i2==5?v5:i2==6?v6:v7); end endtask
    initial begin
        rst_n=0; repeat(5) @(posedge clk); rst_n=1;
        @(posedge clk);

        // ---- K01 金样：默认档逐位直通 ----
        rgb_in=24'h123456; px=300; py=200; br=5; gn=5; fd=0; disp_idx=0;
        #1 ck("K01 default bit-exact passthrough", rgb_out===24'h123456);
        rgb_in=24'hFF8800; #1 ck("K01b default passthrough #2", rgb_out===24'hFF8800);

        // ---- 扩展4 调色 ----
        br=9; gn=5;
        rgb_in = {8'd100, 8'd200, 8'd50};
        #1 begin
            // br=9 => v+80 clamp: 100->180(0xB4) 200->255 50->130(0x82)
            ck("E4 br=9 R=180 G=255 B=130", rgb_out===24'hB4FF82);
        end
        br=1; rgb_in={8'd200,8'd50,8'd128};
        #1 ck("E4 br=1: 200->120,50->0,128->48", rgb_out===24'h780030);
        br=5; gn=9; rgb_in={8'd200,8'd100,8'd128};
        #1 ck("E4 gn=9: 200->255,100->75,128->128", rgb_out===24'hFF4B80);
        br=5; gn=5; // 复位

        // ---- 扩展2 转场：淡入 ----
        fd=1; disp_idx=0; #1;
        rgb_in={8'd200,8'd200,8'd200}; px=10;
        // 触发换图 → arm，下一帧 t=0
        disp_idx=1; fr1;   // frame_start: arm&&frame_start → t=0
        #1 ck("E2 fade t=0 → black", rgb_out===24'h000000);
        repeat(16) fr1;    // t += 8*16 =128
        rgb_in=24'hFFFFFF; #1
        // fade = (255*(128+1))>>8 = 128 → 0x80
        ck("E2 fade mid ~0x80", rgb_out[23:16]>=8'h70 && rgb_out[23:16]<=8'h90);
        repeat(20) fr1;    // t 到 255
        rgb_in=24'h0F0F0F; #1
        ck("E2 fade done → passthrough", rgb_out===24'h0F0F0F);

        // ---- 扩展2 转场：擦拭 ----
        fd=2; disp_idx=0; #1; repeat(3) fr1;  // 让 t 归位到 255（已完成）
        disp_idx=2; fr1;                        // 触发, t=0
        repeat(16) fr1;                         // t=128 → 擦除边界 = 128*5/2=320
        px=200; rgb_in=24'hFF00FF; #1 ck("E2 wipe px<b → show", rgb_out===24'hFF00FF);
        px=400; rgb_in=24'hFF00FF; #1 ck("E2 wipe px>=b → black", rgb_out===24'h000000);
        repeat(20) fr1;                         // 收尾

        // ---- 扩展2 转场：百叶窗 ----
        fd=3; disp_idx=0; #1; repeat(3) fr1;
        disp_idx=3; fr1;
        repeat(8) fr1;      // t≈64 → slat_thr: slat0(24)开, slat1(48)开, slat2(72)未开
        px=0;   rgb_in=24'hA5A5A5; #1 ck("E2 blinds slat0 open", rgb_out===24'hA5A5A5);
        px=192;               // slat3 (192/64=3) thr=96 > 64 未开
        rgb_in=24'hA5A5A5; #1 ck("E2 blinds slat3 closed", rgb_out===24'h000000);
        repeat(25) fr1;

        // ---- 扩展5 VU 包络：灌大振幅样本 ----
        fd=0; disp_idx=0; repeat(3) fr1;
        for(i=0;i<300;i=i+1) begin @(negedge clk); aud_v=1; aud_l=24'sd2000000; end
        #1 calc_vsum;
        ck("E5 VU bars rise with loud tone", vsum > 24);
        // 静音（持续送 valid 但幅度 0）后衰减
        for(i=0;i<2000;i=i+1) begin @(negedge clk); aud_v=1; aud_l=24'sd0; end
        #1 calc_vsum; ck("E5 VU bars decay on silence", vsum < 8);

        // ---- 叠加层金样：全关 → 逐位透传 24'hABCDEF ----
        oen=0; ven=0; vol=6; br=5; gn=5;
        px=250; py=20; #1 ck("OV all-off passthrough (mid)", ov_out===24'hABCDEF);
        px=50;  py=15; #1 ck("OV all-off passthrough (pbar off)", ov_out===24'hABCDEF);
        px=500; py=20; #1 ck("OV all-off passthrough (clock off)", ov_out===24'hABCDEF);

        // ---- 时间戳使能后，时钟区应出现白字（非全透传）----
        oen=1; dut_ov.ss=8'd5; dut_ov.mm=8'd9; dut_ov.hh=8'd23;
        px=500; py=16; #1 ck("OV clock-on (region may be white or bg)", ov_out===24'hABCDEF || ov_out===24'hFFFFFF);
        // 扫描时钟带 496..623 x 8..39 至少一个白像素
        begin : clocksweep
            integer xx,yy,whitec; whitec=0;
            for(yy=8;yy<40;yy=yy+1) for(xx=496;xx<624;xx=xx+1) begin
                px=xx[9:0]; py=yy[8:0]; #0.5;
                if(ov_out===24'hFFFFFF) whitec=whitec+1;
            end
            ck("OV clock band has lit pixels", whitec>10);
        end

        // ---- 进度条：调参后应出现彩条 ----
        oen=0; br=5; gn=5; vol=6; @(posedge clk);
        br=8; @(posedge clk); @(posedge clk);  // 触发 latched
        begin : pbsweep
            integer xx,yy,lit; lit=0;
            for(yy=8;yy<32;yy=yy+1) for(xx=8;xx<88;xx=xx+1) begin
                px=xx[9:0]; py=yy[8:0]; #0.5;
                if(ov_out!==24'hABCDEF) lit=lit+1;
            end
            ck("OV progress bar lit after change", lit>30);
        end

        // ---- VU 使能：底部应有彩条 ----
        ven=1; for(i=0;i<400;i=i+1) begin @(negedge clk); aud_v=1; aud_l=24'sd2000000; end
        begin : vusweep
            integer xx,yy,lit; lit=0;
            for(yy=366;yy<=413;yy=yy+1) for(xx=16;xx<272;xx=xx+1) begin
                px=xx[9:0]; py=yy[8:0]; #0.5;
                if(ov_out!==24'hABCDEF) lit=lit+1;
            end
            ck("OV VU bars drawn", lit>20);
        end

        $display("=== SUMMARY: %0d checks, %0d FAIL ===", checks, fails);
        $finish;
    end
endmodule
