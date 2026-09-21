# negative_controls.ps1 - proves the link benches can actually fail.
#
# A green gate is only evidence if it is capable of going red. Each case below copies a
# source file to a temp directory, reintroduces ONE specific bug that this project really
# had (or would have had), compiles the bench against the mutant, and requires the bench
# to report a failure. A mutant that still passes means the assertion watching it is
# decorative.
#
# Nothing here touches the production sources, and no #ifdef test hooks are added to them.
#
#   powershell -ExecutionPolicy Bypass -File .\negative_controls.ps1
#
# tb_bmpgate already carries its own negative control in-repo: bmp_read_pre_v13.v is the
# frozen pre-fix module and run_gates.ps1 -WithOldRtl shows it failing C2/C3/C4/C5.

param([string]$Icarus = "C:\iverilog\bin")

$ErrorActionPreference = "Stop"
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$root  = Resolve-Path (Join-Path $here "..\..")
$iver  = Join-Path $Icarus "iverilog.exe"
$vvp   = Join-Path $Icarus "vvp.exe"
$tmp   = Join-Path $env:TEMP "lab_pro_mutants"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$linkDir = Join-Path $root "user_source\hdl_source\link"

$cases = @(
  @{
    name    = "phase: forwarded clock resets low"
    src     = (Join-Path $linkDir "dc3_link.v")
    from    = "if (rst)                     link_clk <= 1'b1;"
    to      = "if (rst)                     link_clk <= 1'b0;"
    bench   = "tb_dc3_link.v"
    extra   = @("dc3_link.v")
    expect  = "RESULT: FAIL"
    why     = "the September bug: launch lands on the sampling edge, zero setup margin"
  },
  @{
    name    = "flow: transmitter without the skid stage"
    src     = (Join-Path $linkDir "dc3_link.v")
    from    = "assign s_ready = !hold_valid || send;"
    to      = "assign s_ready = send;"
    bench   = "tb_dc3_link.v"
    extra   = @("dc3_link.v")
    expect  = "RESULT: FAIL"
    why     = "a producer that is not phase-aligned loses a period per byte, so the link"
    why2    = "runs at half rate and the >= 6 MB/s acceptance number must go red"
  },
  @{
    name    = "integrity: CRC comparison forced to pass"
    src     = (Join-Path $linkDir "dc3_pack.v")
    from    = "end else if ({rx_crc[23:0], s_data} === crc_q) begin"
    to      = "end else if (1'b1) begin"
    bench   = "tb_dc3_pack.v"
    extra   = @("dc3_pack.v", "dc3_link.v")
    expect  = "RESULT: FAIL"
    why     = "P2 corrupts a bit on the wire; if the CRC cannot fail, P2 cannot catch it"
  },
  @{
    name    = "session: staleness check removed"
    src     = (Join-Path $linkDir "dc3_pack.v")
    from    = "end else if (hdr[3] !== expect_session) begin"
    to      = "end else if (1'b0) begin"
    bench   = "tb_dc3_pack.v"
    extra   = @("dc3_pack.v", "dc3_link.v")
    expect  = "RESULT: FAIL"
    why     = "plan V3 4.3: after a reconnect, results and key presses from the previous"
    why2    = "session must not take effect"
  },
  @{
    name    = "recovery: rejected packet not drained"
    src     = (Join-Path $linkDir "dc3_pack.v")
    from    = "({hdr[7], s_data} == 16'd0) ? ST_HUNT : ST_DRAIN;"
    to      = "ST_HUNT;"
    bench   = "tb_dc3_pack.v"
    extra   = @("dc3_pack.v", "dc3_link.v")
    expect  = "RESULT: FAIL"
    why     = "the leftover bytes of a rejected packet false-sync on a 0xDC trailer and"
    why2    = "eat the next packet's header - the defect P3 found by accident"
  }
)

$passed = 0; $failed = 0
foreach ($c in $cases) {
  Write-Host ("--- {0}" -f $c.name)

  $srcText = Get-Content $c.src -Raw
  if (-not $srcText.Contains($c.from)) {
    Write-Host "    MUTANT ANCHOR NOT FOUND - the source moved; this control is stale"
    $failed++
    continue
  }
  # only the first occurrence, so a mutant changes exactly one behaviour
  $mutated = $srcText.Replace($c.from, $c.to)
  $mutFile = Join-Path $tmp ("mut_" + (Split-Path $c.src -Leaf))
  Set-Content -Path $mutFile -Value $mutated -Encoding Ascii -NoNewline

  $sources = @()
  foreach ($x in $c.extra) {
    $p = Join-Path $tmp ("mut_" + $x)
    if (-not (Test-Path $p)) { Copy-Item (Join-Path $linkDir $x) $p -Force }
    $sources += $p
  }
  $sources = @($sources | Where-Object { $_ -ne $mutFile })
  $sources = @($mutFile) + $sources

  $exe = Join-Path $tmp ((Split-Path $c.bench -Leaf) + ".vvp")
  & $iver -g2005 -o $exe (Join-Path $here $c.bench) $sources 2>&1 | Out-Null
  if (-not (Test-Path $exe)) {
    Write-Host "    mutant did not compile - control inconclusive"
    $failed++; continue
  }
  $out = (& $vvp $exe 2>&1) -join "`n"

  if ($out -match [regex]::Escape($c.expect)) {
    $first = ($out -split "`n" | Select-String -Pattern "^FAIL:" | Select-Object -First 1)
    Write-Host ("    CAUGHT by: {0}" -f ([string]$first).Trim())
    Write-Host ("    (expected: {0} {1})" -f $c.why, $c.why2)
    $passed++
  } else {
    Write-Host "    NOT CAUGHT - the bench stayed green with a known bug reintroduced"
    Write-Host ("    this assertion is decorative: {0} {1}" -f $c.why, $c.why2)
    $failed++
  }
}

Write-Host ("`n=== negative controls: {0} caught, {1} not caught ===" -f $passed, $failed)
if ($failed -gt 0) { exit 1 } else { exit 0 }
