// tb_masktree —— 播放器"优先链→对数树"手术提案的等价性证明台（只读分析，不碰冻结源）
// 左列 = sd_card_bmp.v 现行函数原样拷贝；右列 = 拟议 log-tree 实现。
// 覆盖：next/prev：32 个 cur × 全部 popcount<=2 掩码(529 种，含 0)【穷举相对距离结构】
//       + 10 万随机三元组；first：全部 popcount<=2 + 10 万随机。
// 编译：iverilog -g2005 -s tb -o %TEMP%\mt.vvp tools/tests/tb_masktree.v && vvp 之
`timescale 1ns/1ps
module tb;
  // ================= 原样：现行实现（逐行抄自 sd_card_bmp.v L390-437） =================
  function [4:0] next_masked_o;
    input [4:0]  cur;  input [31:0] avail;  integer d;  reg [5:0] p;  reg [4:0] r;
    begin
      r = cur;
      for (d = 31; d >= 1; d = d - 1) begin
        p = {1'b0, cur} + d[5:0];
        if (p >= 6'd32) p = p - 6'd32;
        if (avail[p[4:0]]) r = p[4:0];
      end
      next_masked_o = r;
    end
  endfunction
  function [4:0] prev_masked_o;
    input [4:0]  cur;  input [31:0] avail;  integer d;  reg [5:0] p;  reg [4:0] r;
    begin
      r = cur;
      for (d = 31; d >= 1; d = d - 1) begin
        p = {1'b0, cur} + 6'd32 - d[5:0];
        if (p >= 6'd32) p = p - 6'd32;
        if (avail[p[4:0]]) r = p[4:0];
      end
      prev_masked_o = r;
    end
  endfunction
  function [4:0] first_masked_o;
    input [31:0] avail;  integer k;  reg [4:0] r;
    begin
      r = 5'd0;
      for (k = 31; k >= 0; k = k - 1)
        if (avail[k]) r = k[4:0];
      first_masked_o = r;
    end
  endfunction

  // ================= 拟议：对数树实现（合成期零变量下标读） =================
  // one-hot -> 5bit 下标（tree，5 级）；全 0 输入 -> 0（与 first 原版语义一致）
  function [4:0] onehot_idx;
    input [31:0] low;  reg [31:0] g;  reg b4,b3,b2,b1,b0;  reg [15:0] h4;  reg [7:0] h3;  reg [3:0] h2;  reg [1:0] h1;
    begin
      b4 = |low[31:16]; h4 = b4 ? low[31:16] : low[15:0];
      b3 = |h4[15:8];   h3 = b3 ? h4[15:8]   : h4[7:0];
      b2 = |h3[7:4];    h2 = b2 ? h3[7:4]    : h3[3:0];
      b1 = |h2[3:2];    h1 = b1 ? h2[3:2]    : h2[1:0];
      b0 = h1[1];
      onehot_idx = {b4,b3,b2,b1,b0};
    end
  endfunction
  // 最高置位 -> 下标（tree，5 级）；全 0 -> 0
  function [4:0] highbit_idx;
    input [31:0] v;  reg b4,b3,b2,b1,b0;  reg [15:0] h4;  reg [7:0] h3;  reg [3:0] h2;  reg [1:0] h1;
    begin
      b4 = |v[31:16]; h4 = b4 ? v[31:16] : v[15:0];
      b3 = |h4[15:8]; h3 = b3 ? h4[15:8] : h4[7:0];
      b2 = |h3[7:4];  h2 = b2 ? h3[7:4]  : h3[3:0];
      b1 = |h2[3:2];  h1 = b1 ? h2[3:2]  : h2[1:0];
      b0 = h1[1];
      highbit_idx = {b4,b3,b2,b1,b0};
    end
  endfunction
  // rot[i] = avail[(cur+i) mod 32]，rot[0]=自己 -> 去掉自己后最低=最近后继 / 最高=最近前驱
  function [31:0] rot_self;
    input [4:0] cur;  input [31:0] avail;  reg [63:0] dbl;
    begin
      dbl = {avail, avail};
      rot_self = (dbl >> {2'd0, cur}) & 32'hFFFF_FFFF;
    end
  endfunction
  function [4:0] next_masked_n;
    input [4:0] cur;  input [31:0] avail;  reg [31:0] m;  reg [4:0] d;  reg [5:0] s;
    begin
      m = rot_self(cur, avail) & 32'hFFFF_FFFE;      // 去 bit0=自己
      if (m == 32'd0) next_masked_n = cur;
      else begin
        d = onehot_idx(m & (~m + 32'd1));            // 最低置位距离
        s = {1'b0, cur} + {1'b0, d};
        if (s >= 6'd32) s = s - 6'd32;
        next_masked_n = s[4:0];
      end
    end
  endfunction
  function [4:0] prev_masked_n;
    input [4:0] cur;  input [31:0] avail;  reg [31:0] m;  reg [4:0] d;  reg [5:0] s;
    begin
      m = rot_self(cur, avail) & 32'hFFFF_FFFE;      // 去 bit0=自己
      if (m == 32'd0) prev_masked_n = cur;
      else begin
        d = highbit_idx(m);                          // 最高置位 = 绕回后最近前驱
        s = {1'b0, cur} + {1'b0, d};
        if (s >= 6'd32) s = s - 6'd32;
        prev_masked_n = s[4:0];
      end
    end
  endfunction
  function [4:0] first_masked_n;
    input [31:0] avail;
    begin
      first_masked_n = onehot_idx(avail & (~avail + 32'd1));  // 最低置位 one-hot -> idx
    end
  endfunction

  integer errors = 0, checks = 0;
  reg [31:0] mask;  integer c, i, j, t;
  reg [31:0] seed = 32'h5EED_2026;

  task ck3(input [4:0] cur, input [31:0] av);
    reg [4:0] a, b, cc, d, e, f;
    begin
      checks = checks + 3;
      a = next_masked_o(cur, av); b = next_masked_n(cur, av);
      if (a !== b) begin errors=errors+1; $display("FAIL next cur=%0d av=%h o=%0d n=%0d", cur, av, a, b); end
      cc = prev_masked_o(cur, av); d = prev_masked_n(cur, av);
      if (cc !== d) begin errors=errors+1; $display("FAIL prev cur=%0d av=%h o=%0d n=%0d", cur, av, cc, d); end
      e = first_masked_o(av);     f = first_masked_n(av);
      if (e !== f) begin errors=errors+1; $display("FAIL first av=%h o=%0d n=%0d", av, e, f); end
    end
  endtask

  initial begin
    // A) 穷举：全部 cur(0..31，用 integer c 避免 5bit 回绕死循环) × 全部 popcount<=2 掩码（0 + 32 单位 + 496 双位）
    ck3(5'd0, 32'd0);                                  // 空掩码（first 原版约定返回 0）
    for (i = 0; i < 32; i = i + 1)
      for (c = 0; c < 32; c = c + 1) begin
        ck3(c[4:0], 32'd1 << i);                          // 单位
        for (j = i+1; j < 32; j = j + 1)
          ck3(c[4:0], (32'd1 << i) | (32'd1 << j));       // 双位
      end
    $display("[A] exhaustive popcount<=2 done, checks=%0d errors=%0d", checks, errors);
    // B) 随机：2 万个任意密度掩码
    for (t = 0; t < 20000; t = t + 1) begin
      seed = seed * 32'h0000_343F + 32'h26;
      mask = seed;
      ck3(seed[9:5], mask);
    end
    // C) 全 1 掩码与相邻极端
    for (c = 0; c < 32; c = c + 1) ck3(c[4:0], 32'hFFFF_FFFF);
    if (errors == 0) $display("=== TBMASKTREE ALL PASS: %0d checks / 0 FAIL ===", checks);
    else             $display("=== TBMASKTREE FAILED: %0d errors of %0d checks ===", errors, checks);
    $finish;
  end
endmodule
