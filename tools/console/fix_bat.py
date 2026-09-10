# -*- coding: utf-8 -*-
# 把桌面「TF卡一键修复.bat」重写为纯 ASCII + CRLF（cmd 批处理硬性要求：
# 不能带 BOM、不能有中文、必须 CRLF，否则 cmd 按字节解析会错位啃掉命令）。
# 所有中文提示都在被调用的 card_reformat.ps1 里（UTF-8 BOM，PowerShell 可正确读）。
import io

BAT_PATH = "C:\\Users\\lwy\\OneDrive\\Desktop\\TF卡一键修复.bat"
PS1 = "C:\\td_batch\\lab_pro\\tools\\console\\card_reformat.ps1"

lines = [
    "@echo off",
    "chcp 65001 >nul",
    "title TF Card Fix",
    'set "PS=' + PS1 + '"',
    'if "%~1"=="RUNAS_DONE" goto :haveadmin',
    "net session >nul 2>&1",
    "if %errorlevel% neq 0 (",
    "  echo Requesting administrator rights... click [Yes] on the UAC popup.",
    "  timeout /t 2 >nul",
    "  powershell -NoProfile -Command \"Start-Process -FilePath '%~f0' -ArgumentList 'RUNAS_DONE' -Verb RunAs\"",
    "  echo A new elevated window is opening. This one closes in 5 seconds.",
    "  timeout /t 5 >nul",
    "  exit /b",
    ")",
    ":haveadmin",
    "echo [ADMIN OK] running card_reformat.ps1 ...",
    "echo (prompts + log file are handled inside the PowerShell script)",
    "echo.",
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%PS%"',
    "echo.",
    "echo ==== card_reformat.ps1 finished, exit code %errorlevel% ====",
    "pause",
]
blob = "\r\n".join(lines) + "\r\n"
assert all(ord(c) < 128 for c in blob), "bat must be pure ASCII"
with io.open(BAT_PATH, "wb") as f:
    f.write(blob.encode("ascii"))
print("OK wrote %d bytes  CRLF=%d  pure-ASCII  no-BOM" % (len(blob), blob.count("\r\n")))
