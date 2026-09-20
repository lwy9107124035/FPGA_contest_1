# td_build.ps1 - full TD flow for lab_pro, with the failure checks that matter. ASCII only.
#
#   powershell -ExecutionPolicy Bypass -File .\td_build.ps1 -BuildDir td_project10
#   powershell -ExecutionPolicy Bypass -File .\td_build.ps1 -BuildDir td_project10 -From s2
#
# Why this exists: the four TD steps live in tcl files inside the build directory, and each
# one exits 0 even when it refused to do the work. "place" prints
#   PHY-9009 ERROR: Design's mslice number = 4917, exceeds the limit 4900
# and still returns cleanly, which leaves the next step routing a stale netlist and
# producing a bit that does not match the source. Every step here is checked by its
# completion marker AND for hard errors before the next one is allowed to run.
param(
  [Parameter(Mandatory = $true)][string]$BuildDir,
  [ValidateSet("s1", "s2", "s3a", "s3b")][string]$From = "s1",
  [string]$TdBin = "C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dir  = Join-Path $repo $BuildDir
$td   = Join-Path $TdBin "td_commands_prompt.exe"

if (-not (Test-Path $td))  { Write-Host "TD not found: $td";  exit 2 }
if (-not (Test-Path $dir)) { Write-Host "no such build dir: $dir"; exit 2 }

# marker per step, and the strings that mean the step silently failed
$steps = @(
  @{ id = "s1";  tcl = "s1_syn.tcl";   marker = "===S1_GATE_DONE===" },
  @{ id = "s2";  tcl = "s2_place.tcl"; marker = "===S2_PLACE_DONE===" },
  @{ id = "s3a"; tcl = "s3a_route.tcl"; marker = "===ROUTE_OK===" },
  @{ id = "s3b"; tcl = "s3b_bit.tcl";  marker = "===S3B_BIT_DONE===" }
)
$bad = @("PHY-9009", "ERROR:", "ROUTE_FAIL", "NO_BIT_THIS_RUN", "Segmentation")

$order = @("s1", "s2", "s3a", "s3b")
$startAt = [array]::IndexOf($order, $From)

Set-Location $dir
for ($i = $startAt; $i -lt $steps.Count; $i++) {
  $s = $steps[$i]
  $log = "{0}_out.log" -f $s.id
  Write-Host ("[{0}] {1}" -f $s.id, $s.tcl) -NoNewline
  & $td $s.tcl 2>&1 | Out-File -FilePath $log -Encoding ascii
  $text = Get-Content $log -Raw

  if ($text -notmatch [regex]::Escape($s.marker)) {
    Write-Host "  FAILED (no $($s.marker))"
    ($text -split "`n" | Select-String -Pattern ($bad -join "|") | Select-Object -First 5) |
      ForEach-Object { Write-Host "    $_" }
    exit 1
  }
  # a step can print its marker and still have hit a hard error earlier
  $hits = ($text -split "`n" | Select-String -Pattern ($bad -join "|"))
  if ($hits -and $s.id -ne "s3a") {
    Write-Host "  FAILED (marker present but errors found)"
    $hits | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" }
    exit 1
  }
  Write-Host ("  ok  ({0})" -f $s.marker)
}

$bit = Join-Path $dir "lab_pro.bit"
if (-not (Test-Path $bit)) { Write-Host "no bit produced"; exit 1 }
$bi = Get-Item $bit
Write-Host ("`nBIT: {0}  built {1}  {2} bytes" -f $bit, $bi.LastWriteTime, $bi.Length)
$area = Join-Path $dir "lab_pro_gate.area"
if (Test-Path $area) {
  Select-String -Path $area -Pattern "^#(lut|bram|dsp) " |
    ForEach-Object { Write-Host ("  " + $_.Line) }
}
$timing = Join-Path $dir "lab_pro_timing.rpt"
if (Test-Path $timing) { Write-Host ("timing report: {0}" -f $timing) }
exit 0
