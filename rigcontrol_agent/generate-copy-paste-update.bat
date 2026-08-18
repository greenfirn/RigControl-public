@echo off
setlocal
cd /d %~dp0
set OUT=copy-paste-update.sh
for %%F in (rigcontrol-agent-local.sh rigcontrol_telemetry.sh rigcontrol_cmd.sh rigcontrol_agent.sh rigcontrol_agent-service.sh) do (
    if not exist "%%F" (
        echo ERROR: %%F not found in %cd% - aborting, nothing written.
        pause
        exit /b 1
    )
)
(
    echo #sudo systemctl stop rigcloud-agent.service
    echo #sudo systemctl disable rigcloud-agent.service
    echo.
    type "rigcontrol-agent-local.sh"
    echo.
    type "rigcontrol_telemetry.sh"
    echo.
    type "rigcontrol_cmd.sh"
    echo.
    type "rigcontrol_agent.sh"
    echo.
    type "rigcontrol_agent-service.sh"
) > "%OUT%"
echo.
echo Wrote %OUT%:
for %%A in ("%OUT%") do @echo %%~tA  %%~zA bytes  %%~nxA
pause
