@echo off
cd %~dp0
cls
timeout /t 10
set KERYX_LOG_PATH=%~dp0gpu_miner.log
set STOP_FLAG="%ProgramData%\RigControl\stop_gpu.flag"
:loop
if exist %STOP_FLAG% (
    echo Stop flag detected - exiting loop cleanly.
    goto end
)
powershell -NoProfile -Command "& { .\keryx-miner.exe --mining-address keryx:qz0qun5xt8vr7qkqxyq87dxtfwrskz4va7y4xlvnkmtnrpruwrcuzdw2fzkwg --keryxd-address 10.10.0.126:22110 2>&1 | Tee-Object -FilePath '%KERYX_LOG_PATH%' -Append; exit $LASTEXITCODE }"
if exist %STOP_FLAG% (
    echo Stop flag detected after miner exit - exiting loop cleanly.
    goto end
)
if ERRORLEVEL 1 goto custom
timeout /t 5
goto loop
:custom
echo Custom command here
timeout /t 5
goto loop
:end
echo Miner loop stopped.
exit /b 0
