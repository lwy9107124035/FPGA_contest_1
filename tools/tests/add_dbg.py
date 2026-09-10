# -*- coding: utf-8 -*-
import io, re
P = r"C:\td_batch\lab_pro\tools\tests\tb_img_scaler.v"
s = io.open(P, encoding="utf-8").read()
old = """dut.rows_done, dut.syc, dut.sxc);"""
new = """dut.rows_done, dut.syc, dut.sxc);
                        $display("   DBG geo sx_step=%0d sy_step=%0d offx=%0d offy=%0d dstw=%0d dsth=%0d w0=%0d h0=%0d wide=%0d geo_q=%0d pass=%0d sq=%0d obx=%0d oby=%0d", dut.sx_step, dut.sy_step, dut.offx, dut.offy, dut.dst_w, dut.dst_h, dut.w0, dut.h0, dut.wide, dut.geo_q, dut.pass, dut.sq, obx, oby);"""
if "DBG geo" not in s:
    assert s.count(old) == 1
    s = s.replace(old, new, 1)
    io.open(P, "w", encoding="utf-8", newline="\n").write(s)
    print("DBG inserted")
else:
    print("DBG already present")
