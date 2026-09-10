# auto_demo.ps1 - flash CURRENT lab_pro.bit, serial self-test, trigger EMG banner. ASCII only.
# NOTE: always burns the LATEST bit file at this path (mtime is printed). v7 era.
param([switch]$SkipEmg)
$ErrorActionPreference = "Stop"

$bitFile = "C:\td_batch\lab_pro\td_project\lab_pro.bit"
$bi = Get-Item $bitFile
Write-Host ("[1/4] flash lab_pro.bit  built: {0}  size: {1}" -f $bi.LastWriteTime, $bi.Length)
& C:\Users\lwy\miniconda3\envs\fpga_batch\python.exe C:\td_batch\tf_test\dl_tf.py C:\td_batch\lab_pro\td_project\lab_pro.bit
if ($LASTEXITCODE -ne 0) { Write-Host "FLASH FAILED"; exit 1 }

Write-Host "[2/4] wait 3s for FPGA to come up..."
Start-Sleep -Seconds 3

Write-Host "[3/4] serial self-test COM4@115200..."
$sp = New-Object System.IO.Ports.SerialPort "COM4",115200,None,8,One
$sp.ReadTimeout = 1500
$sp.WriteTimeout = 1000
$sp.NewLine = "`n"
$sp.Open()

function Read-Reply([int]$budget_ms) {
    $sb = New-Object System.Text.StringBuilder
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $budget_ms) {
        while ($sp.BytesToRead -gt 0) { [void]$sb.Append([char]$sp.ReadByte()) }
        if ($sb.ToString().Contains("`n")) { break }
        Start-Sleep -Milliseconds 20
    }
    return $sb.ToString().Trim()
}

$sp.DiscardInBuffer()
$sp.WriteLine("STAT?")
$r = Read-Reply 2000
Write-Host ("    STAT? reply: '{0}'" -f $r) -ForegroundColor Yellow
if ($r -match "^V2") { Write-Host "    RX+TX LINK ALIVE" -ForegroundColor Green }
else { Write-Host "    !! NO ACK - serial path broken" -ForegroundColor Red }

if (-not $SkipEmg) {
    Write-Host "[4/4] send EMG1 (Chinese typhoon banner + buzzer)..."
    $sp.WriteLine("EMG1")
    Start-Sleep -Milliseconds 300
    $ra = Read-Reply 1500
    Write-Host ("    EMG1 reply: '{0}'" -f $ra) -ForegroundColor Yellow
    $sp.Close()
    Write-Host "DONE. Expect on screen: big Chinese phrase top row, EMERGENCY BROADCAST ACTIVE bottom row, buzzer (SW7 on)." -ForegroundColor Green
} else {
    $sp.Close()
    Write-Host "DONE (self-test only)."
}
