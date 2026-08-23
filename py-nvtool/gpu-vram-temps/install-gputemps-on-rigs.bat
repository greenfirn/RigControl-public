@echo off
setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0
set REMOTE_USER=user
set REMOTE_DEST=/home/user
set HOSTS[0]=5950x-4-4070tis 10.20.0.100
set HOSTS[1]=5950x-6-5070ti 10.20.0.103
echo set HOSTS[2]=5950x-1-5070ti 10.10.0.101
set HOSTS[2]=5950x-8-5070ti 10.20.0.105
set HOSTS[3]=5950x-5-5070ti 10.20.0.102
set HOSTS[4]=7950x-1-3090 10.20.0.101
set HOST_COUNT=5
echo NVIDIA rig inventory (gputemps is NVIDIA-only - not for AMD rigs):
for /l %%N in (0,1,4) do (
    for /f "tokens=1,2" %%a in ("!HOSTS[%%N]!") do echo   %%a  -  %%b
)
set FAILED=
for /l %%N in (0,1,4) do (
    for /f "tokens=1,2" %%a in ("!HOSTS[%%N]!") do (
        set NAME=%%a
        set IP=%%b
    )
    echo.
    echo ============================================================
    echo  Installing gputemps on %REMOTE_USER%@!IP! ^(!NAME!^)
    echo ============================================================
    scp "%SCRIPT_DIR%install-gputemps.sh" %REMOTE_USER%@!IP!:%REMOTE_DEST%/
    if errorlevel 1 (
        echo FAILED to copy install-gputemps.sh to !NAME! ^(!IP!^)
        set FAILED=!FAILED! !NAME!
    ) else (
        ssh -t %REMOTE_USER%@!IP! "bash %REMOTE_DEST%/install-gputemps.sh"
        if errorlevel 1 (
            echo FAILED to run install-gputemps.sh on !NAME! ^(!IP!^)
            set FAILED=!FAILED! !NAME!
        )
    )
)
echo.
echo ============================================================
echo  All rigs processed.
if defined FAILED (
    echo  FAILED/INCOMPLETE:!FAILED!
) else (
    echo  gputemps installed on all rigs - check each rig's self-test output above for real vs null VRAM readings.
)
echo ============================================================
pause
