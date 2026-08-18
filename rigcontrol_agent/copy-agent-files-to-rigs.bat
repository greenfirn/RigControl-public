@echo off
setlocal enabledelayedexpansion
set AGENT_DIR=%~dp0
set REMOTE_USER=user
set REMOTE_DEST=/home/user
set HOSTS[0]=5950x-4-4070tis 10.20.0.100
set HOSTS[1]=5950x-2 10.10.0.108
set HOSTS[2]=5950x-1-5070ti 10.10.0.101
set HOSTS[3]=5950x-5-5070ti 10.20.0.102
set HOSTS[4]=5950x-6-5070ti 10.20.0.103
set HOSTS[5]=5950x-3 10.10.0.118
set HOSTS[6]=5950x-8-5070ti 10.20.0.105
set HOSTS[7]=5950x-7 10.10.0.112
set HOSTS[8]=7950x-1-3090 10.20.0.101
set HOSTS[9]=5900x-1 10.10.0.124
set HOSTS[10]=5900x-2 10.10.0.109
set HOST_COUNT=11
echo Rig inventory:
for /l %%N in (0,1,10) do (
    for /f "tokens=1,2" %%a in ("!HOSTS[%%N]!") do echo   %%a  -  %%b
)
set FAILED=
for /l %%N in (0,1,10) do (
    for /f "tokens=1,2" %%a in ("!HOSTS[%%N]!") do (
        set NAME=%%a
        set IP=%%b
    )
    echo.
    echo ============================================================
    echo  Copying files to %REMOTE_USER%@!IP! ^(!NAME!^)
    echo ============================================================
    scp "%AGENT_DIR%rigcontrol_agent.sh" "%AGENT_DIR%rigcontrol_agent-service.sh" "%AGENT_DIR%rigcontrol_cmd.sh" "%AGENT_DIR%rigcontrol_telemetry.sh" "%AGENT_DIR%rigcontrol-agent-local.sh" "%AGENT_DIR%rigcontrol_agent_install.sh" %REMOTE_USER%@!IP!:%REMOTE_DEST%/
    if errorlevel 1 (
        echo FAILED to copy files to !NAME! ^(!IP!^)
        set FAILED=!FAILED! !NAME!
    )
)
echo.
echo ============================================================
echo  All rigs processed.
if defined FAILED (
    echo  FAILED/INCOMPLETE:!FAILED!
) else (
    echo  All files copied - run rigcontrol_agent_install.sh on each rig to install.
)
echo ============================================================
pause
