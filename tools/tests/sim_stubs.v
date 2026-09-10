// sim_stubs.v — v10.2 仿真替身：替代加密 IP（sdr_as_ram / EG_PHY_SDRAM_2M_32 的
// .enc.v iverilog 解析不了）。tb_chain / tb_mask32 都 force 播放器边界信号，
// SDRAM 链路不承载被测逻辑，唯 Sdr_init_done 必须恒 1（bmp_read 等它才开扫）。
// 编译配方（PowerShell，仓库根 C:\td_batch\lab_pro）：
//   $src = (Get-ChildItem user_source\hdl_source\SD -Filter *.v | % FullName) +
//          @(hdl_source\msg_ink.v, IP\afifo_16_32_256.v, IP\afifo_32_16_256.v,
//            tools\tests\sim_stubs.v)
//   iverilog -g2005 -I user_source\hdl_source\SD -I td_project -o x.vvp tools\tests\tb_chain.v $src
module sdr_as_ram #(
    parameter self_refresh_open = 1'b1
)(
    input  wire        Sdr_clk,
    input  wire        Sdr_clk_sft,
    input  wire        Rst,
    output wire        Sdr_init_done,
    output wire        Sdr_init_ref_vld,
    output wire        Sdr_busy,
    input  wire        App_ref_req,
    input  wire        App_wr_en,
    input  wire [21:0] App_wr_addr,
    input  wire [3:0]  App_wr_dm,
    input  wire [31:0] App_wr_din,
    input  wire        App_rd_en,
    input  wire [21:0] App_rd_addr,
    input  wire        Sdr_rd_en,
    output wire [31:0] Sdr_rd_dout,
    output wire        SDRAM_CLK,
    output wire        SDR_RAS,
    output wire        SDR_CAS,
    output wire        SDR_WE,
    output wire [1:0]  SDR_BA,
    output wire [12:0] SDR_ADDR,
    output wire [3:0]  SDR_DM,
    inout  wire [31:0] SDR_DQ
);
    assign Sdr_init_done  = 1'b1;    // 关键：让 SD 栈认为内存就绪
    assign Sdr_init_ref_vld = 1'b0;
    assign Sdr_busy       = 1'b0;
    assign Sdr_rd_dout    = 32'd0;
    assign SDRAM_CLK      = 1'b0;
    assign SDR_RAS = 1'b0; assign SDR_CAS = 1'b0; assign SDR_WE = 1'b0;
    assign SDR_BA  = 2'd0; assign SDR_ADDR = 13'd0; assign SDR_DM = 4'd0;
endmodule

module EG_PHY_SDRAM_2M_32 (
    input  wire        clk,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [10:0] addr,
    input  wire [1:0]  ba,
    inout  wire [31:0] dq,
    input  wire        cs_n,
    input  wire        dm0,
    input  wire        dm1,
    input  wire        dm2,
    input  wire        dm3,
    input  wire        cke
);
endmodule
