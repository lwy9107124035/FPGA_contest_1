`timescale 1ns/1ps
//=============================================================================
// tb_marquee —— 实测扩展1平滑滚动：驱动 sr_spd，验证 MSG 带像素按【整像素】左移。
// 手法：同一帧在 sr_spd=0 与 sr_spd=k 下渲染，逐像素比较 —— 用"第1帧 off 的
// (x+k) 像素"应等于"滚动帧第 x 像素"这一平移不变性验证（跑马灯是纯横向平移）。
// 另验 msg_off 计帧：给 N 帧应推进 N*k（mod 352）。
//=============================================================================
module tb;
    reg clk=0, rst_n=0;
    always #20 clk = ~clk;                 // 25MHz 半周期 20ns
    // 640x480 逐像素扫描，line=688 拍(含消隐)，frame=688*525
    integer LINE=688;

    reg         de;
    reg  [11:0] x, y;
    reg  [2:0]  sr;
    reg  [23:0] rgb_in;
    wire [23:0] rgb_out;
    // msg_ink 写口（TB 直接驱动 msg 槽）
    reg         msg_we=0; reg [4:0] msg_wslot=0; reg [15:0] msg_wcode=0; reg msg_commit=0;
    reg         emg=0;    reg [1:0] esel=0;  reg [2:0] tcol=0; reg colexec=0;
    reg         xcd_new=0; wire xcd_req; wire [19:0] xcd_addr; wire xcd_busy; reg xcd_busy_r=0;
    wire [255:0] xcd_out=256'd0;

    osd_banner dut(
        .clk(clk), .rst_n(rst_n), .de(de), .x(x), .y(y),
        .rgb_in(rgb_in), .rgb_out(rgb_out),
        .msg_we(msg_we), .msg_wslot(msg_wslot), .msg_wcode(msg_wcode), .msg_commit(msg_commit),
        .emg_mode(emg), .emg_sel(esel), .txt_col_sel(tcol), .col_exec(colexec),
        .sr_spd(sr),
        .xcd_req_v(xcd_req), .xcd_addr_v(xcd_addr), .xcd_new_v(xcd_new), .xcd_out_v(xcd_out),
        .xcd_busy_v(xcd_busy_r), .loader_inhibit(1'b0)
    );
    assign xcd_busy = xcd_busy_r;

    // 一帧渲染：扫 640x480 活动像素，抓 MSG 行(y=448..455, msg 带)像素到数组
    // 简化：只抓一行 MSG (dy=0 => y=BANNER_Y0=416) 的 640 像素
    reg [23:0] linebuf0 [0:639];
    reg [23:0] linebuf1 [0:639];

    task render_row(input integer use_buf);
        integer p; begin
            // y=BANNER_Y0+? MSG 半字行：用 y=420（在 banner 内 dy=4, line1?）
            @(posedge clk);
            y <= 12'd424;    // dy=8 → line_sel=0（LINE0/EMG）；MSG 带需 dy>=32
            // 实际 MSG 行：BANNER_Y0=416, dy=y-416, line_sel=dy[5] → dy>=32 即 y>=448
            y <= 12'd450;    // dy=34 → line_sel=1 (MSG), glyph_row=dy[4:1]=1
            de  <= 1'b1;
            for(p=0;p<640;p=p+1) begin
                x <= p[11:0];
                @(posedge clk);
                if(use_buf==0) linebuf0[p] = rgb_out;
                else           linebuf1[p] = rgb_out;
            end
            de <= 1'b0;
        end
    endtask

    // 帧顶脉冲（x=0,y=0,de=1）推进 msg_off
    task pulse_top;
        integer p; begin
            @(posedge clk); y<=12'd0; de<=1'b1;
            for(p=0;p<3;p=p+1) begin x<=p[11:0]; @(posedge clk); end
            de<=1'b0;
        end
    endtask
    task frames(input integer n); integer j; begin for(j=0;j<n;j=j+1) pulse_top; end endtask

    integer checks=0, fails=0, i, shift, first0;
    task ck(input [8*40-1:0] nm, input cond);
        begin checks=checks+1; if(cond) $display("PASS %0s",nm);
            else begin fails=fails+1; $display("FAIL %0s",nm); end end
    endtask

    initial begin
        // 预置一条 MSG：slot0..7 = 大写字母 A..H 的 ASCII（半角），其余空
        rst_n=0; repeat(4) @(posedge clk);
        // 直接写 glyph_ram 无法（私有）；改用 msg_we/commit 引擎——需 de=0 且多拍，成本高。
        // 简化验证目标：只验"平移不变性 + msg_off 计帧"，与内容无关（内容可为空白→平移仍成立）。
        // 用非平凡底图 rgb_in 制造可辨像素：不依赖字形。
        rst_n=1; sr=0; emg=0; tcol=0;
        // 预清 glyph_ram（iverilog 无初值 RAM 读出 X，会污染比较；置 0=空白字形）
        begin : zipe
            integer zz; for(zz=0; zz<352; zz=zz+1) dut.glyph_ram[zz] = 16'h0000;
        end
        repeat(2) @(posedge clk);

        // 关滚动，渲染一帧作为 baseline（内容用 rgb_in 图案，不涉字形）
        rgb_in = 24'h000000;
        render_row(0);      // 热身：清 rd_word/ascii_q 里预置 RAM 前锁存的 X
        render_row(0);      // linebuf0 = sr=0 基线
        // 开滚动跑 N 帧，再渲染
        sr=3'd3;
        frames(5);          // msg_off 应 = 15
        render_row(1);      // linebuf1

        // 平移不变性：banner 内非字形像素全为 bg_dark(rgb_in>>1) 或 text，
        // 与 x 无关（bg 均匀）→ 两帧该行应完全一致（证明滚动【没有】破坏均匀背景，
        // 也证明 render 路径稳定）。真正的字形平移用 msg 内容才有，但均匀图可验
        // "滚动只移动字形窗口、不改背景/时序"。
        begin : uni
            integer diff, fd; diff=0; fd=-1;
            for(i=0;i<640;i=i+1) if(linebuf0[i]!==linebuf1[i]) begin diff=diff+1; if(fd<0) begin fd=i; $display("M01 first stray @x=%0d base=%h scr=%h", i, linebuf0[i], linebuf1[i]); end end
            ck("M01 uniform bg stable under scroll (0 stray pixels)", diff==0);
        end
        ck("M02 msg_off advanced by N*spd", dut.msg_off == 10'd15);
        // ---- M05/M06：真平移证据：屏位 5 放全角"全亮字模"，量它左移精确 8px ----
        dut.msg_flat_a[(336-5*16) +: 16] = 16'hC4E3;   // GB 全角码（双字节均>=A1 才走 m_full）
        dut.msg_flat_b[(336-5*16) +: 16] = 16'hC4E3;
        dut.msg_flat_c[(336-5*16) +: 16] = 16'hC4E3;
        dut.glyph_ram[5*16 + 1] = 16'hFFFF;            // 渲染行 y=450 → dy=34 → glyph_row=1
        dut.msg_off = 10'd0;
        sr=3'd0; frames(1); render_row(0);             // 基线（off=0，静止）
        begin : find0
            integer p0; p0=0; while(p0<640 && linebuf0[p0]!==24'hFFFFFF) p0=p0+1;
            first0 = p0;
        end
        dut.msg_off = 10'd0; sr=3'd4; frames(2);       // 干净起滚：off=8
        render_row(1);
        begin : find1
            integer p1; p1=0; while(p1<640 && linebuf1[p1]!==24'hFFFFFF) p1=p1+1;
            $display("M0x first-white baseline=%0d scrolled=%0d", first0, p1);
            ck("M05 baseline lit starts at slot5 (x=80)", first0 == 80);
            ck("M06 exact 8px leftward shift (smooth)", (p1 + 8) == first0);
        end
        // 关滚动 → msg_off 冻结
        sr=3'd0; dut.msg_off = 10'd15; frames(4);
        ck("M03 msg_off frozen when sr=0", dut.msg_off == 10'd15);
        // 溢出回绕：设 msg_off=350，跑2帧(+3*2=+6)=356 → 356-352=4
        dut.msg_off = 10'd350; sr=3'd3; frames(2);
        ck("M04 wrap mod 352", dut.msg_off == 10'd4);

        $display("=== SUMMARY: %0d checks, %0d FAIL ===", checks, fails);
        $finish;
    end
endmodule
