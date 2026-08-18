@echo off
setlocal
set "ROOT=%~dp0"
if not exist "%ROOT%build\ReimuWatch.exe" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%build.ps1"
  if errorlevel 1 exit /b %errorlevel%
)
start "" "%ROOT%build\ReimuWatch.exe"
