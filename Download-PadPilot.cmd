@echo off
setlocal
set "OUT=%~dp0PadPilot_v1_0_Portable.zip"
set "DEST=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$urls = @('https://raw.githubusercontent.com/Neo664evr/PadPilot/main/downloads/PadPilot_v1_0_Portable.zip.b64.001','https://raw.githubusercontent.com/Neo664evr/PadPilot/main/downloads/PadPilot_v1_0_Portable.zip.b64.002','https://raw.githubusercontent.com/Neo664evr/PadPilot/main/downloads/PadPilot_v1_0_Portable.zip.b64.003','https://raw.githubusercontent.com/Neo664evr/PadPilot/main/downloads/PadPilot_v1_0_Portable.zip.b64.004'); $text = ($urls | ForEach-Object { (Invoke-WebRequest -UseBasicParsing $_).Content }) -join ''; [IO.File]::WriteAllBytes($env:OUT, [Convert]::FromBase64String($text)); Expand-Archive -LiteralPath $env:OUT -DestinationPath $env:DEST -Force; Remove-Item -LiteralPath $env:OUT -Force"
if errorlevel 1 (
  echo.
  echo Download failed. Check your internet connection and try again.
  pause
  exit /b 1
)
echo.
echo Pad Pilot is ready in the PadPilot_v1_0_Portable folder.
pause
