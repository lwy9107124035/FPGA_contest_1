//=============================================================================
// sdiv24 —— 24÷16 迭代 restoring 除法器（扩展3 缩放器几何计算专用）
//   q = floor(num/den)，r = num - q*den。start 拉高一拍锁存 → 24 拍后 done 拉高。
//   v10.3b-6：start 不再被 busy 门控（时间表驱动可精确重开）；done 仅状态输出。
//   【TD 铁律·本轮探针实证】上层绝不可把本实例的 done/quo 再组合回本实例的
//   start/num/den（哪怕经由寄存器）——"实例输出锥喂回实例输入"会让
//   TD 6.2.168 elaborate 收尾 coredump（H6 纯消费输出则健康）。
//   缩放器已改为固定时间表时序：除法完成拍由计数器算出，无需握手回环。
//=============================================================================
`default_nettype none
module sdiv24(
    input  wire        clk, rst_n,
    input  wire        start,
    input  wire [23:0] num,
    input  wire [15:0] den,
    output reg         done,
    output reg  [23:0] quo,
    output reg  [15:0] rem
);
    reg [23:0] n;      // 被除数（逐位左出，最高位先进）
    reg [16:0] a;      // 部分余数（17bit：足够比较 16bit 除数）
    reg [23:0] q;
    reg [4:0]  cnt;
    reg        busy;
    wire [15:0] d = (den==16'd0)?16'd1:den;
    wire [16:0] shifted = {a[15:0], n[23]};      // 注入下一被除数位
    wire        sub     = (shifted >= {1'b0,d});
    wire [16:0] na      = sub ? (shifted - {1'b0,d}) : shifted;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin busy<=0; done<=0; quo<=0; rem<=0; a<=0; q<=0; n<=0; cnt<=0; end
        else begin
            done <= 1'b0;
            if (start) begin                    // 无条件重开（时间表驱动，永不自反馈）
                n <= num; a <= 17'd0; q <= 24'd0; cnt <= 5'd0; busy <= 1'b1;
            end else if (busy) begin
                a <= na;
                q <= {q[22:0], sub};
                n <= {n[22:0],1'b0};
                if (cnt == 5'd23) begin
                    busy <= 1'b0; done <= 1'b1;
                    quo  <= {q[22:0], sub};      // 第 24 位在本拍产生
                    rem  <= na[15:0];
                end
                cnt <= cnt + 5'd1;
            end
        end
    end
endmodule
`default_nettype wire
