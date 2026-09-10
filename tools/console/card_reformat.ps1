# card_reformat.ps1 —— TF 卡一键修复：备份隐藏区 → 格成标准单分区 FAT32 → 写回 13 张图（5 老图 + 8 多分辨率演示图）
# 由 TF卡一键修复.bat 提权后调用。小白解释：FPGA 板子只会从头 64MB 顺序找图，
# 之前这张卡被切成 3 个分区（像树莓派卡），新图全落在 1GB 之外，板子物理上"看不见"。
$ErrorActionPreference = "Stop"

# ===== 提权自门（9/7 第6轮加固）=====
# 教训：日志显示有一次 diskpart 报 "Access is denied" —— 脚本在未真正提权的窗口里跑了，
# 结果只做了备份就中断，卡没格也没写图（板子读 0 张）。根因是提权判断放在外层 .bat，
# 换任何别的入口（右键"使用 PowerShell 运行"、命令行直跑）都会绕过它。
# 现在把管理员自检挪进脚本第一行：不是管理员 → 自己弹 UAC 重启自己；被拒 → 明确中止，绝不半途。
$ID  = [Security.Principal.WindowsIdentity]::GetCurrent()
$PR  = New-Object Security.Principal.WindowsPrincipal($ID)
if (-not $PR.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "需要管理员权限（diskpart 重分区）。正在弹出 UAC，请在弹窗点【是】..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath "powershell" -Verb RunAs -ArgumentList @(
            "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"")
    } catch {
        Write-Host "提权被取消或失败：没有管理员权限无法修卡。请右键本脚本【以管理员身份运行】，或双击桌面 TF卡一键修复.bat 并在 UAC 点【是】。" -ForegroundColor Red
        exit 1
    }
    Write-Host "已另开管理员窗口继续（若没看到窗口=UAC 被取消，请重跑）。本窗口可关闭。" -ForegroundColor Green
    exit 0
}
# ====================================

Start-Transcript -Path (Join-Path $env:USERPROFILE "Desktop\TF卡修复日志.txt") -Force | Out-Null
$bak  = Join-Path $env:USERPROFILE "Desktop\FPGA卡备份_20260906"
$imgdir = Join-Path $bak "隐藏分区镜像"
$src  = "C:\td_batch\lab_pro\tools\console\card_backup"
$msrc = "C:\td_batch\lab_pro\tools\multires_demo"
$py   = "C:\Users\lwy\miniconda3\envs\fpga_batch\python.exe"
New-Item -ItemType Directory -Force $imgdir | Out-Null

"=== 安全校验：确认磁盘 1 是那张 TF 卡 ==="
$d = Get-Disk -Number 1
"磁盘1: $($d.FriendlyName)  容量 $([math]::Round($d.Size/1GB,1))GB  可移动=$($d.IsRemovable)  分区表=$($d.PartitionStyle)"
if ($d.Size -lt 4GB -or $d.Size -gt 64GB) { "中止：磁盘1容量不像 TF 卡($($d.Size) 字节)"; Stop-Transcript; Read-Host "回车退出"; exit 1 }
if (-not $d.IsRemovable) {
  "注意：这块盘没被系统标成'可移动'（内置读卡器常见），但容量像 16G 卡。"
  $ans = Read-Host "请确认磁盘1就是你的 TF 卡：输入小写 yes 继续，其它任意键中止"
  if ($ans -ne "yes") { "已中止，什么都没改。"; Stop-Transcript; Read-Host "回车退出"; exit 0 }
}
"OK: 目标 = 磁盘1 $($d.FriendlyName)"

"`n[1/3] 备份卡头 640MB 原始镜像 -> $imgdir (F盘文件已提前备份好)"
$worker = @'
import ctypes, sys
k=ctypes.windll.kernel32
k.CreateFileW.restype=ctypes.c_void_p
k.SetFilePointerEx.argtypes=[ctypes.c_void_p,ctypes.c_longlong,ctypes.c_void_p,ctypes.c_uint]
h=k.CreateFileW(r"\\.\PhysicalDrive1", 0x80000000, 3, None, 3, 0, None)
if h in (0,None,ctypes.c_void_p(-1).value):
    print("镜像跳过(打不开裸盘 gle=%d)" % k.GetLastError()); sys.exit(0)
k.SetFilePointerEx(h, 0, None, 0)
CH=4*1024*1024
out=open(sys.argv[1],"wb"); tot=0
for i in range(160):
    buf=ctypes.create_string_buffer(CH); got=ctypes.c_ulong(0)
    ok=k.ReadFile(h,buf,CH,ctypes.byref(got),None)
    if not ok or got.value==0: break
    out.write(buf.raw[:got.value]); tot+=got.value
out.close(); k.CloseHandle(h)
print("镜像完成: %.1f MB" % (tot/1048576))
'@
$wf = Join-Path $env:TEMP "card_img_worker.py"
$worker | Set-Content -Encoding Ascii $wf
$imgOut = Join-Path $imgdir "disk1_first_640MB.img"
try { & $py $wf "`"$imgOut`"" } catch { "镜像步骤失败（继续格式化）: $_" }

"`n[2/3] diskpart 重置：256MB FAT16 小分区（图片数据区落在最前面 ~0.2MB，板子 4 秒自愈看门狗也追得上——9/7 板测日实测：FAT32 大分区元数据占 15~30MB，把图推到看门狗够不着的地方，板子扫描永远被打回）"
$dp = Join-Path $env:TEMP "card_dp.txt"
@'
select disk 1
clean
convert mbr
create partition primary size=256
select partition 1
format fs=fat16 quick unit=8192 label=FPGABMP
active
assign
'@ | Set-Content -Encoding Ascii $dp
diskpart /s $dp
if ($LASTEXITCODE -ne 0) { "diskpart 失败！"; Read-Host "回车退出"; exit 1 }

Start-Sleep 3
"`n[3/3] 写回图片：5 张标准老图(BMP0000..04) + 8 张多分辨率演示图(BMP0005..12)"
$vol = Get-Volume | Where-Object { $_.FileSystemLabel -eq "FPGABMP" } | Select-Object -First 1
$letter = ($vol.DriveLetter)
$root = "$letter`:\"
"新卡盘符: $letter ；写入到 $root"
$i = 0
# (A) 已知良好的标准 640x480 图，用于确认"修卡成功"
$order = @("00_00_testA.bmp","01_01_apple.bmp","02_02_strawberry.bmp","03_03_watermelon.bmp","BMP0000.BMP")
foreach ($f in $order) {
  $s = Join-Path $src $f
  if (Test-Path $s) {
    Copy-Item $s (Join-Path $root ("BMP{0:d4}.BMP" -f $i)) -Force
    "  $f -> BMP{0:d4}.BMP" -f $i
    $i++
  }
}
# (B) 扩展3 多分辨率演示图（1280x720/400x800/1024x768/320x240 缩放 + b-19 起扁条带也走缩放居中）
foreach ($f in (Get-ChildItem $msrc -Filter "BMP*.BMP" | Sort-Object Name)) {
  Copy-Item $f.FullName (Join-Path $root ("BMP{0:d4}.BMP" -f $i)) -Force
  "  (演示)$($f.Name) -> BMP{0:d4}.BMP" -f $i
  $i++
}
# 让 Windows 把目录项刷齐（真正落盘靠随后的"安全弹出"）
[System.IO.Directory]::GetFiles($root) | Out-Null

"`n完成！卡现在是 256MB FAT16 小分区（图全在前排），含 $i 张图（物理连续低区）。"
"前 5 张是标准图（应先能正常轮播）= 修卡成功；后 8 张是扩展3缩放演示图。"
"请把卡【安全弹出】后插回 FPGA 板子。"
"!! 插板后第一件事（顺序有讲究，仿真已证明）：先开【缩放 SC 1】，再点【扫满 32 张】。"
"   SC=0 时扫描器只登记 640x480 标准图 —— 8 张缩放演示图会被'登记门'直接拒掉；"
"   不发 SCAN 则默认只扫前 4 张。两步都做了，LIST? 才会回 13 张。详见 17 号手册第 0 步。"
Stop-Transcript
Read-Host "按回车关闭本窗口"
