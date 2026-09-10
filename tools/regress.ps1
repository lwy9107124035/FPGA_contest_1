# regress.ps1 - full command-set regression over serial. ASCII only.
# v2 (2026-09-05): added NEXT/AUTO slideshow cases (poll-based, deterministic).
# dbg byte (v5f osd/player telemetry, sent as hex by STAT?):
#   bit7 scan_done  bit6 auto_en  bit5 src_done  bit4 wr_done
#   bit3 disp_valid bit2 load_busy bit1..0 img_idx
$sp = New-Object System.IO.Ports.SerialPort "COM4",115200,None,8,One
$sp.ReadTimeout = 1500
$sp.NewLine = "`n"
$sp.Open()
function RR([int]$ms){
  $sb=New-Object System.Text.StringBuilder; $sw=[Diagnostics.Stopwatch]::StartNew()
  while($sw.ElapsedMilliseconds -lt $ms){
    while($sp.BytesToRead -gt 0){[void]$sb.Append([char]$sp.ReadByte())}
    if($sb.ToString().Contains("`n")){break}
    Start-Sleep -m 15
  }
  return $sb.ToString().Trim()
}
function STAT-DBG(){
  # returns hashtable @{cnt=<msgcnt>; dbg=<byte>} or $null on parse fail
  $sp.DiscardInBuffer(); $sp.WriteLine("STAT?"); Start-Sleep -m 60
  $r = RR 400
  $p = $r -split '\s+'
  if($p.Count -ge 3 -and $p[0] -eq "V2"){
    return @{ cnt=[Convert]::ToInt32($p[1],16); dbg=[Convert]::ToInt32($p[2],16) }
  }
  return $null
}
$fails = 0; $total = 0
function T($cmd, $expect, $note){
  $script:total++
  $sp.DiscardInBuffer(); $sp.WriteLine($cmd); Start-Sleep -m 200
  $r = RR 1200
  $okflag = ($r -like "*$expect*")
  if(-not $okflag){ $script:fails++ }
  Write-Host ("{0} [{1}] exp~'{2}' got '{3}'  {4}" -f ($(if($okflag){"PASS"}else{"FAIL"}), $cmd, $expect, $r, $note))
  Start-Sleep -m 300
}
T "STAT?"        "V2"   "baseline"
T "CLR"          "OK"   "the 100%-failing case"
T "CLR"          "OK"   "repeat"
T "clr"          "OK"   "lowercase via upc"
T "EMG1"         "OK"   "hold screen: typhoon banner"
T "MSG ALL CLEAR" "OK"  "hold: bottom line ALL CLEAR, CJK stays"
T "CLR"          "OK"   "exit emg"
T "FOOBAR"       "ERR"  "unknown cmd"
# v6: GB2312 Chinese message, sent as RAW bytes (never embed CJK in ASCII-saved
# scripts -- a previous debug cycle chased '?' ghosts created by file encoding!).
# Frame = "MSG " + "台风蓝色预警" (CC A8 B7 E7 C0 B6 C9 AB D4 A4 BE AF) + \n
$script:total++
$frame = [byte[]](0x4D,0x53,0x47,0x20,0xCC,0xA8,0xB7,0xE7,0xC0,0xB6,0xC9,0xAB,0xD4,0xA4,0xBE,0xAF,0x0A)
$sp.DiscardInBuffer(); $sp.Write($frame, 0, $frame.Length); Start-Sleep -m 300
$r = RR 1200
$cnok = ($r -like "*OK*")
if(-not $cnok){ $script:fails++ }
Write-Host ("{0} [MSG GB2312] ack='{1}'  (Chinese to OSD: tai feng lan se yu jing)" -f ($(if($cnok){"PASS"}else{"FAIL"}), $r))
Start-Sleep -m 300

# ---- v7: playback-parameter commands (PLAYER_V7_CONTRACT sec.6) ----
T "SPD 3"        "OK"  "v7 set uniform 3s"
T "T 2 5"        "OK"  "v7 per-image duration"
T "PLY 0F"       "OK"  "v7 subset mask"
T "PLYALL"       "OK"  "v7 all-scanned mask"
T "SCAN4"        "OK"  "v7 scan depth 4"
T "SPD A"        "ERR" "v7 invalid seconds"
T "T 9 1"        "ERR" "v7 image idx out of range"
T "PLY 00"       "ERR" "v7 empty mask rejected"
# Functional: with PLY 03 the player may only ever show img0/img1 -> 4x NEXT
# must stay inside {0,1} (dbg img bits [1:0]) AND actually move at least once.
$sp.DiscardInBuffer(); $sp.WriteLine("PLY 03"); Start-Sleep -m 300; $sp.DiscardInBuffer()
$imgs=@(); $prev=-1; $moved=$false
for($i=0;$i -lt 4;$i++){
  $sp.WriteLine("NEXT"); Start-Sleep -m 2500
  $s = STAT-DBG
  if($s){ $cur = $s.dbg -band 3; $imgs += $cur; if($prev -ge 0 -and $cur -ne $prev){$moved=$true}; $prev=$cur }
}
$insub = ($imgs.Count -gt 0) -and (-not ($imgs | Where-Object { $_ -gt 1 }))
$plyOk = ($insub -and $moved)
$script:total++
if(-not $plyOk){ $script:fails++ }
Write-Host ("{0} [PLY 03] observed imgs=[{1}] in-subset={2} moved={3}  (subset playback)" -f ($(if($plyOk){"PASS"}else{"FAIL"}), ($imgs -join ','), $insub, $moved))
# restore defaults so the classic NEXT/AUTO cases below keep v6 semantics
T "PLY 0F"       "OK"  "v7 restore mask"
T "SPD 1"        "OK"  "v7 restore 1s cadence"
# v7.2: COL palette (visual: msg text color; EMG keeps alarm red by design)
T "COL 3"        "OK"  "v7.2 yellow (check screen)"
T "COL 9"        "ERR" "v7.2 out-of-range rejected"
T "MSG COLOR TEST" "OK" "v7.2 msg after COL stays in palette"
T "COL 0"        "OK"  "v7.2 restore white"
# v9: mixed-case payloads + case-insensitive commands (lowercase now DISPLAYS,
# commands keep working in any case). Uppercase forms above cover the old paths.
T "msg Hello, 42!" "OK" "v9 mixed-case payload (check screen: shows 'Hello, 42!')"
T "msgg hi"      "ERR" "v9 near-miss must not alias msg"
T "spd 2"        "OK"  "v9 lowercase cmd"
T "SPD 1"        "OK"  "restore 1s cadence"
T "col 3"        "OK"  "v9 lowercase col (yellow on screen)"
T "COL 0"        "OK"  "restore white"
T "ply 7f"       "OK"  "v9 lowercase hex mask"
T "PLYALL"       "OK"  "restore full mask"
# v9.1: decimal PLY (1-digit = "first N", 2-digit = decimal mask; A-F still hex)
T "PLY 3"        "OK"  "v9.1 first-3 (mask 07)"
T "PLY 12"       "OK"  "v9.1 decimal mask 0C"
T "PLY 99"       "OK"  "v9.1 max decimal 0x63"
T "PLY 0"        "ERR" "v9.1 zero rejected"
T "PLY 100"      "ERR" "v9.1 three-digit rejected"
T "ply 7f"       "OK"  "v9.1 letters keep hex path"
T "PLYALL"       "OK"  "restore full mask"
# v9.1 INFO? human frame: "V2 <ddd> <8-binary>" + cnt must agree with STAT? hex cnt
$script:total++
$sp.DiscardInBuffer(); $sp.WriteLine("INFO?"); Start-Sleep -m 250
$r = RR 1200; $p = $r -split '\s+'
$shape = ($p.Count -ge 3 -and $p[0] -eq "V2" -and $p[1] -match '^\d{3}$' -and $p[2] -match '^[01]{8}$')
$sc = STAT-DBG
$agree = ($shape -and $sc -and ([int]$p[1] -eq $sc.cnt))
if(-not $agree){ $script:fails++ }
Write-Host ("{0} [INFO?] got '{1}' shape={2} cnt-matches-STAT={3}" -f ($(if($agree){"PASS"}else{"FAIL"}), $r, $shape, $agree))
Start-Sleep -m 300
# counter check: V2 <2hex> <2hex> format + msgcnt strictly increasing (was: assume cnt<10,
# now NEXT/AUTO/LOAD also count so it can exceed 0x0F -- format assertion instead)
$script:total++
$c1 = STAT-DBG; $sp.WriteLine("CLR"); Start-Sleep -m 150; $sp.DiscardInBuffer()
$c2 = STAT-DBG
$cok = ($c1 -and $c2 -and ($c2.cnt -gt $c1.cnt -or ($c2.cnt -lt 16 -and $c1.cnt -gt 240)))
if(-not $cok){ $script:fails++ }
Write-Host ("{0} [COUNTER] {1} -> {2} increasing={3}" -f ($(if($cok){"PASS"}else{"FAIL"}), $c1.cnt, $c2.cnt, $cok))

# ---------- slideshow cases (v5f) ----------
# NEXT: img (dbg bit1..0) must change within 6s of command
$script:total++
$a = STAT-DBG; $sp.WriteLine("NEXT"); Start-Sleep -m 200
$sw=[Diagnostics.Stopwatch]::StartNew(); $moved=$false
while($sw.Elapsed.TotalSeconds -lt 6){
  Start-Sleep -m 400; $b = STAT-DBG
  if($b -and (($b.dbg -band 3) -ne ($a.dbg -band 3))){ $moved=$true; break }
}
if(-not $moved){ $script:fails++ }
Write-Host ("{0} [NEXT] img {1} -> moved={2}  (slideshow manual advance)" -f ($(if($moved){"PASS"}else{"FAIL"}), ($a.dbg -band 3), $moved))

# ---- v10.1b 加固：AUTO 前置同步——toggle 语义要求入口必为 OFF（防外部脚本残留 ON 态假失败）----
$b = STAT-DBG
if($b -and (($b.dbg -shr 6) -band 1)){
    Write-Host "  (pre: auto bit=1 -> 同步回 OFF)" -ForegroundColor DarkYellow
    $sp.WriteLine("AUTO"); Start-Sleep -m 400; $sp.DiscardInBuffer()
    $b = STAT-DBG
    if($b -and (($b.dbg -shr 6) -band 1)){ $sp.WriteLine("AUTO"); Start-Sleep -m 400; $sp.DiscardInBuffer() }
    $b = STAT-DBG
    if($b -and (($b.dbg -shr 6) -band 1)){
        Write-Host "FAIL [auto-pre-sync] auto bit 无法归零" -ForegroundColor Red; $script:total++; $script:fails++
    }
}

# AUTO ON: img must advance at least once in 5s, and auto bit must be 1
$script:total++
$sp.WriteLine("AUTO"); Start-Sleep -m 200; $sp.DiscardInBuffer()
$a = STAT-DBG; $sw=[Diagnostics.Stopwatch]::StartNew(); $adv=$false; $autobit=$false
while($sw.Elapsed.TotalSeconds -lt 5){
  Start-Sleep -m 400; $b = STAT-DBG
  if($b){ $autobit = (($b.dbg -shr 6) -band 1) -eq 1
          if((($b.dbg -band 3) -ne ($a.dbg -band 3))){ $adv=$true; break } }
}
if(-not ($adv -and $autobit)){ $script:fails++ }
Write-Host ("{0} [AUTO on] auto_bit={1} advanced={2}  (slideshow auto cycle)" -f ($(if($adv -and $autobit){"PASS"}else{"FAIL"}), $autobit, $adv))

# AUTO OFF: img must stay put for 4s
$script:total++
$sp.WriteLine("AUTO"); Start-Sleep -m 200; $sp.DiscardInBuffer()
Start-Sleep -m 2500   # let any in-flight load finish first
$a = STAT-DBG; Start-Sleep -m 4000; $b = STAT-DBG
$stable = ($a -and $b -and (($a.dbg -band 3) -eq ($b.dbg -band 3)) -and ((($b.dbg -shr 6) -band 1) -eq 0))
if(-not $stable){ $script:fails++ }
Write-Host ("{0} [AUTO off] img hold {1} stable={2}  (no ghost advances)" -f ($(if($stable){"PASS"}else{"FAIL"}), ($a.dbg -band 3), $stable))

# ---------- v10 / v10.1 cases ----------
# WHY? blackbox: "W hh hh hh ddd" (query must NOT bump msgcnt)
$script:total++
$c1 = STAT-DBG
$sp.DiscardInBuffer(); $sp.WriteLine("WHY?"); Start-Sleep -m 250
$r = RR 900; $p = ($r.Trim() -split '\s+')
$c2 = STAT-DBG
$shape = ($p.Count -eq 5 -and $p[0] -eq "W" -and $p[1] -match '^[0-9A-F]{2}$' -and $p[2] -match '^[0-9A-F]{2}$' -and $p[3] -match '^[0-9A-F]{2}$' -and $p[4] -match '^\d{3}$')
$free  = ($c1 -and $c2 -and $c1.cnt -eq $c2.cnt)
$whyok = ($shape -and $free)
if(-not $whyok){ $script:fails++ }
Write-Host ("{0} [WHY?] got '{1}' shape={2} cnt-neutral={3}  (v10 blackbox)" -f ($(if($whyok){"PASS"}else{"FAIL"}), $r, $shape, $free))
Start-Sleep -m 200

# scan timing: SCAN7 (target 7 > 4 imgs on card) MUST return fast with v10.1
function SCAN-T([string]$cmd,[double]$limit){
  $script:total++
  $sp.DiscardInBuffer(); $sp.WriteLine($cmd); Start-Sleep -m 150; $sp.DiscardInBuffer()
  $sw=[Diagnostics.Stopwatch]::StartNew(); $back=$false
  while($sw.Elapsed.TotalSeconds -lt $limit){
    Start-Sleep -m 200; $s = STAT-DBG
    if($s -and (($s.dbg -shr 7) -band 1)){ $back=$true; break }
  }
  $t=[Math]::Round($sw.Elapsed.TotalSeconds,1)
  if(-not $back){ $script:fails++ }
  Write-Host ("{0} [{1}] scan_done back in {2}s (limit {3}s)  (v10.1 walk stop-loss)" -f ($(if($back){"PASS"}else{"FAIL"}), $cmd, $t, $limit))
}
SCAN-T "SCAN7"  8
SCAN-T "SCAN32" 12
# VID pacing: VID 4 forces fast auto -> >=2 frame commits (busy rises) in 8s
$script:total++
$sp.WriteLine("VID 4"); Start-Sleep -m 300; $sp.DiscardInBuffer()
$busy=0; $prevb=$false; $sw=[Diagnostics.Stopwatch]::StartNew()
while($sw.Elapsed.TotalSeconds -lt 8){
  Start-Sleep -m 60; $s=STAT-DBG
  if($s){ $b=(($s.dbg -shr 2) -band 1) -eq 1; if($b -and -not $prevb){$busy++}; $prevb=$b }
}
$sp.WriteLine("VID 0"); Start-Sleep -m 300
$vidok = ($busy -ge 2)
if(-not $vidok){ $script:fails++ }
Write-Host ("{0} [VID 4] busy-episodes={1} in 8s (need>=2)  (v10 video mode)" -f ($(if($vidok){"PASS"}else{"FAIL"}), $busy))
# COL during EMG (v10.1): acks must be OK; red-unlock itself is visual (human check)
T "EMG1"           "OK" "v10.1 enter emg (red default)"
T "COL 2"          "OK" "v10.1 COL during emg accepted"
T "MSG COLOR LIVE" "OK" "v10.1 text after COL (screen: green not red)"
T "CLR"            "OK" "exit emg"
T "COL 0"          "OK" "restore white"
T "SCAN4"          "OK" "restore default scan depth (functional check next)"
Start-Sleep -m 1800
$script:total++
$s = STAT-DBG
$scanok = ($s -and (($s.dbg -shr 7) -band 1))
if(-not $scanok){ $script:fails++ }
Write-Host ("{0} [SCAN4 settled] dbg={1:X2}  (default healthy state restored)" -f ($(if($scanok){"PASS"}else{"FAIL"}), $s.dbg))

$sp.Close()
if($fails -eq 0){ Write-Host ("REGRESSION {0}/{0} PASS" -f $total) } else { Write-Host ("REGRESSION FAILED: {0} of {1}" -f $fails, $total) }
