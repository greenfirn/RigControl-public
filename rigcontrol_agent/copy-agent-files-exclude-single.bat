@echo off
setlocal enabledelayedexpansion
set AGENT_DIR=%~dp0
set REMOTE_USER=user
set REMOTE_DEST=/home/user
set NAME=worker
set IP=10.10.0.111
echo.
echo ============================================================
echo  Copying files to %REMOTE_USER%@%IP% (%NAME%, EXCLUDE_FROM_TOTALS)
echo ============================================================
set OK=1
scp "%AGENT_DIR%rigcontrol_agent.sh" "%AGENT_DIR%rigcontrol_agent-service.sh" "%AGENT_DIR%rigcontrol_cmd.sh" "%AGENT_DIR%rigcontrol_agent_install.sh" %REMOTE_USER%@%IP%:%REMOTE_DEST%/
if errorlevel 1 set OK=0
scp "%AGENT_DIR%rigcontrol-agent-local-keryxd.sh" %REMOTE_USER%@%IP%:%REMOTE_DEST%/rigcontrol-agent-local.sh
if errorlevel 1 set OK=0
scp "%AGENT_DIR%rigcontrol_telemetry-exclude.sh" %REMOTE_USER%@%IP%:%REMOTE_DEST%/rigcontrol_telemetry.sh
if errorlevel 1 set OK=0
echo.
echo ============================================================
if "%OK%"=="0" (
    echo  FAILED to copy one or more files to %NAME% ^(%IP%^)
) else (
    echo  All files copied - run rigcontrol_agent_install.sh on %NAME% to install.
)
echo ============================================================
pause
