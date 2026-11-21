@echo off
cd /d "%~dp0"
cls
setlocal
title Suprminer Neptune (NEB)

REM Replace the wallet below with your own NEB mainnet address (starts with neb1).
set "WALLET=YOUR_NEB_WALLET_ADDRESS"
set "WORKER=%COMPUTERNAME%"
set "POOL=stratum+tcp://stratum-ca.suprnova.cc:7804"

if /I "%WALLET%"=="YOUR_NEB_WALLET_ADDRESS" (
    echo Edit WALLET near the top of this file, save it, then run it again.
    pause
    exit /b 64
)

REM Full path to the exe (PowerShell does not search the current directory).
set "MINER_EXE=%~dp0suprminer-neptune.exe"
if not exist "%MINER_EXE%" (
    echo Extract the whole Windows miner ZIP before starting this file.
    echo Keep this file next to suprminer-neptune.exe and its DLLs.
    pause
    exit /b 66
)

REM Log in C:\Temp, appended across runs, trimmed to the last 2000 lines
REM once it passes 10MB (checked on each launch).
set "LOGDIR=C:\Temp"
set "LOGFILE=%LOGDIR%\gpu-miner.log"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

set MAX_LOG_BYTES=10485760
set LOGSIZE=0
if exist "%LOGFILE%" for %%A in ("%LOGFILE%") do set LOGSIZE=%%~zA

if %LOGSIZE% GTR %MAX_LOG_BYTES% (
    echo Log exceeded 10MB - trimming to the most recent lines...
    powershell -NoProfile -Command "& { $c = Get-Content -Path '%LOGFILE%' -Tail 2000; Set-Content -Path '%LOGFILE%' -Value $c -Encoding utf8 }"
)

echo. >> "%LOGFILE%"
echo ================================================================ >> "%LOGFILE%"
echo Starting suprminer-neptune at %DATE% %TIME% >> "%LOGFILE%"
echo Wallet: %WALLET%.%WORKER% >> "%LOGFILE%"
echo Pool:   %POOL% >> "%LOGFILE%"
echo ================================================================ >> "%LOGFILE%"

echo Starting suprminer-neptune as %WALLET%.%WORKER%
echo Pool: %POOL%
echo Logging to: %LOGFILE%
echo.

REM stderr is merged by cmd.exe (2>&1) so PowerShell only sees plain text
REM (avoids NativeCommandError noise); each line is shown live and appended.
"%MINER_EXE%" -a neb -o "%POOL%" -u "%WALLET%.%WORKER%" -p x 2>&1 | powershell -NoProfile -Command "$input | ForEach-Object { $_; Add-Content -Path '%LOGFILE%' -Value $_ -Encoding utf8 }"

echo.
echo ================================================================
echo  The miner STOPPED or CRASHED - read the messages above for the
echo  reason. Full history also saved to: %LOGFILE%
echo  This window stays open on purpose. Press any key to close.
echo ================================================================
pause
