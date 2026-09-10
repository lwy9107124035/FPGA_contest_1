# -*- coding: utf-8 -*-
import io
p = r"C:\td_batch\lab_pro\user_source\hdl_source\SD\sd_card_bmp.v"
lines = io.open(p, encoding="utf-8").read().split("\n")
# target: the plain "else: load_timeout_cnt<=0" tail of the load FSM chain,
# unique context: after "end else begin" at old L646. Find index of the exact pair:
#   "            end else begin"  /  "                load_timeout_cnt <= 32'd0;"  /  "            end"
idx = None
for i in range(len(lines) - 2):
    if (lines[i].strip() == "end else begin" and lines[i].startswith("            ")
        and lines[i+1].strip() == "load_timeout_cnt <= 32'd0;"
        and lines[i+2].strip() == "end"):
        idx = i; break
assert idx is not None, "anchor not found"
watch = [
 "            // v7.3a watchdog: retry armed but bmp_ready never returns within 0.3s",
 "            //   => stall lives in bmp/SD side -> escalate to legacy full rescan.",
 "            end else if (retry_req && !bmp_ready) begin",
 "                if (retry_wait >= 25'd30_000_000) begin",
 "                    retry_wait <= 25'd0;",
 "                    retry_req  <= 1'b0;",
 "                    retry_cnt  <= 2'd0;",
 "                    load_abort <= 1'b1;",
 "                end else begin",
 "                    retry_wait <= retry_wait + 25'd1;",
 "                end",
 "            end else begin",
 "                retry_wait       <= 25'd0;",
 "                load_timeout_cnt <= 32'd0;",
]
# replace lines[idx:idx+3] (the old else-tail) -- keep final 'end'
new = lines[:idx] + watch + ["            end"] + lines[idx+3:]
io.open(p, "w", encoding="utf-8", newline="\n").write("\n".join(new))
# reset clears: add retry_wait to rst / !sd_init / kick-adjacent blocks
txt = "\n".join(new)
n1 = txt.count("retry_req             <= 1'b0;   // v7.3")
txt = txt.replace("retry_req             <= 1'b0;   // v7.3",
                  "retry_req             <= 1'b0;   // v7.3\n            retry_wait            <= 25'd0;  // v7.3a")
n2 = txt.count("retry_req             <= 1'b0;   // v7.3\n        ")
txt = txt.replace("retry_req             <= 1'b0;   // v7.3\n        ",
                  "retry_req             <= 1'b0;   // v7.3\n        retry_wait            <= 25'd0;  // v7.3a\n        ")
io.open(p, "w", encoding="utf-8", newline="\n").write(txt)
print("watchdog inserted at line", idx+1, "| v7.3 rst-block clears found:", n1, "| indent-8 clears:", n2)
