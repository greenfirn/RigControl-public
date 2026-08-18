@echo off
setlocal enabledelayedexpansion
set AGENT_DIR=%~dp0
set REMOTE_USER=user
set REMOTE_DEST=/home/user
set HOSTS[0]=5900x-3 10.10.0.126
set HOSTS[1]=i9-12900 10.10.0.x
set HOST_COUNT=2
echo Rig inventory:
for /l %%N in (0,1,1) do (
    for /f "tokens=1,2" %%a in ("!HOSTS[%%N]!") do echo   %%a  -  %%b
)
set FAILED=
for /l %%N in (0,1,1) do (
    for /f "tokens=1,2" %%a in ("!HOSTS[%%N]!") do (
        set NAME=%%a
        set IP=%%b
    )
    echo.
    echo ============================================================
    echo  Copying files to %REMOTE_USER%@!IP! ^(!NAME!, EXCLUDE_FROM_TOTALS^)
    echo ============================================================
    set OK=1
    scp "%AGENT_DIR%rigcontrol_agent.sh" "%AGENT_DIR%rigcontrol_agent-service.sh" "%AGENT_DIR%rigcontrol_cmd.sh" "%AGENT_DIR%rigcontrol_agent_install.sh" %REMOTE_USER%@!IP!:%REMOTE_DEST%/
    if errorlevel 1 set OK=0
    scp "%AGENT_DIR%rigcontrol-agent-local-keryxd.sh" %REMOTE_USER%@!IP!:%REMOTE_DEST%/rigcontrol-agent-local.sh
    if errorlevel 1 set OK=0
    scp "%AGENT_DIR%rigcontrol_telemetry-exclude.sh" %REMOTE_USER%@!IP!:%REMOTE_DEST%/rigcontrol_telemetry.sh
    if errorlevel 1 set OK=0
    if "!OK!"=="0" (
        echo FAILED to copy one or more files to !NAME! ^(!IP!^)
        set FAILED=!FAILED! !NAME!
    )
)
echo.
echo ============================================================
if defined FAILED (
    echo  FAILED/INCOMPLETE:!FAILED!
) else (
    echo  All files copied - run rigcontrol_agent_install.sh on each rig to install.
)
echo ============================================================
pause
