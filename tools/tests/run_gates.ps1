# run_gates.ps1 - one command to re-prove the SD/BMP chain before a board session. ASCII only.
#
#   powershell -ExecutionPolicy Bypass -File .\run_gates.ps1
#   powershell -ExecutionPolicy Bypass -File .\run_gates.ps1 -WithOldRtl
#
# Gate list and the pass signatures each one is expected to print:
#   tb_bmpgate   v13.0 header gate       "RESULT: PASS"        14 checks
#   tb_bmpscan   sector walk + register  "errors=0"            11 checks, ~2 min
#   tb_chain     SD load chain           "30 checks, 0 FAIL"
#   tb_mask32    mask/commit path        "11090 checks, 0 FAIL"
#   tb_dc3_link  DC3 byte pipe, CDC, READY  "RESULT: PASS"  13 checks
# -WithOldRtl additionally runs tb_bmpgate against the frozen pre-v13 snapshot. That is an
# expected-FAIL demo of the original bug (C2/C3/C4/C5), never a gate.
param(
  [string]$Icarus = "C:\iverilog\bin",
  [switch]$WithOldRtl
)

$ErrorActionPreference = "Stop"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$root   = Resolve-Path (Join-Path $here "..\..")
$src    = Join-Path $root "user_source\hdl_source"
$iver   = Join-Path $Icarus "iverilog.exe"
$vvp    = Join-Path $Icarus "vvp.exe"
$tmp    = Join-Path $env:TEMP "lab_pro_gates"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

if (-not (Test-Path $iver)) { Write-Host "iverilog not found at $iver"; exit 2 }

# Every bench below only needs the SD subtree. Listing it beats walking the whole tree,
# which drags in vendor *_sim.v models and unresolvable `include files.
$sdTree = @(
  (Join-Path $src "SD\sd_card_bmp.v"),
  (Join-Path $src "SD\bmp_read.v"),
  (Join-Path $src "SD\sd_card_top.v"),
  (Join-Path $src "SD\sd_card_cmd.v"),
  (Join-Path $src "SD\spi_master.v"),
  (Join-Path $src "SD\sd_card_sec_read_write.v")
)

function Invoke-Gate {
  param([string]$Name, [string]$Top, [string[]]$Sources, [string]$Expect, [bool]$Required = $true)
  $out = Join-Path $tmp ("{0}.vvp" -f $Name)
  Write-Host ("--- {0} " -f $Name) -NoNewline
  $log = & $iver -g2005 -o $out $Top @Sources 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "COMPILE FAIL"; $log | Select-Object -First 6 | ForEach-Object { Write-Host "    $_" }
    return $false
  }
  $run = (& $vvp $out 2>&1) -join "`n"
  if ($run -match [regex]::Escape($Expect)) { Write-Host "PASS ($Expect)"; return $true }
  Write-Host "FAIL (expected '$Expect')"
  ($run -split "`n" | Select-String -Pattern "FAIL|error" | Select-Object -First 6) |
    ForEach-Object { Write-Host "    $_" }
  return $false
}

$results = @()
$results += Invoke-Gate "tb_bmpgate_new" (Join-Path $here "tb_bmpgate.v") `
            @((Join-Path $src "SD\bmp_read.v")) "RESULT: PASS"
$results += Invoke-Gate "tb_bmpscan"     (Join-Path $here "tb_bmpscan.v") `
            @((Join-Path $src "SD\bmp_read.v")) "tb_bmpscan done: errors=0"
$results += Invoke-Gate "tb_chain"       (Join-Path $here "tb_chain.v") `
            $sdTree "30 checks, 0 FAIL"
$results += Invoke-Gate "tb_mask32"      (Join-Path $here "tb_mask32.v") `
            $sdTree "11090 checks, 0 FAIL"

# The DC3 link is standalone for now (nothing in top instantiates it yet), so it needs
# only its own file - and it is the one part of the dual-board plan provable without a
# second board on the bench.
$results += Invoke-Gate "tb_dc3_link"    (Join-Path $here "tb_dc3_link.v") `
            @(Join-Path $src "link\dc3_link.v") "RESULT: PASS"

if ($WithOldRtl) {
  Write-Host ""
  Write-Host "  pre-v13 A/B demo (expected to FAIL; this is the bug the gate fixes):"
  Invoke-Gate "tb_bmpgate_old" (Join-Path $here "tb_bmpgate.v") `
            @((Join-Path $here "bmp_read_pre_v13.v")) "RESULT: PASS" $false | Out-Null
}

$failed = @($results | Where-Object { $_ -eq $false }).Count
Write-Host ("`n=== gates: {0} passed, {1} failed ===" -f ($results.Count - $failed), $failed)
if ($failed -gt 0) { exit 1 } else { exit 0 }
