@echo off
setlocal
set "OUT=%~dp0PadPilot_v1_0_Portable.zip"
set "DEST=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$urls = @('https://raw.githubusercontent.com/Neo664evr/PadPilot/831d552746a985575795539f73dd35f51002f7ce/downloads/PadPilot_v1_0_Portable.zip.b64.001','https://raw.githubusercontent.com/Neo664evr/PadPilot/50e83d2325efd25a76d1f66fdffcae00850bcd75/downloads/PadPilot_v1_0_Portable.zip.b64.002','https://raw.githubusercontent.com/Neo664evr/PadPilot/e99518e596f36a1e41f34ecadedbca477b6e811c/downloads/PadPilot_v1_0_Portable.zip.b64.003','https://raw.githubusercontent.com/Neo664evr/PadPilot/506a9e340cd2a37cd794a52b8028147a19a2cf73/downloads/PadPilot_v1_0_Portable.zip.b64.004'); $stream = [IO.File]::Open($env:OUT, [IO.FileMode]::Create); try { foreach ($url in $urls) { $bytes = [Convert]::FromBase64String((Invoke-WebRequest -UseBasicParsing $url).Content); $stream.Write($bytes, 0, $bytes.Length) } } finally { $stream.Dispose() }; Expand-Archive -LiteralPath $env:OUT -DestinationPath $env:DEST -Force; Remove-Item -LiteralPath $env:OUT -Force"
if errorlevel 1 (
  echo.
  echo Download failed. Check your internet connection and try again.
  pause
  exit /b 1
)
echo.
echo Pad Pilot is ready in the PadPilot_v1_0_Portable folder.
pause
