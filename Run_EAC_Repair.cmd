@echo off
setlocal
if not exist "%~dp0EAC_Repair.ps1" (
    echo ERROR: EAC_Repair.ps1 must be in the same folder as this launcher.
    pause
    exit /b 1
)
rem Only this PowerShell process bypasses the script execution policy.
rem The PowerShell script requests UAC elevation when needed.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0EAC_Repair.ps1"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
    echo.
    echo The repair tool exited with code %RESULT%.
    pause
)
exit /b %RESULT%
