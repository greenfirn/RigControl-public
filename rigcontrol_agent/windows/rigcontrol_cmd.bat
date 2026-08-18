@echo off
setlocal enabledelayedexpansion
set LOG="%USERPROFILE%\rigcontrol_cmd.log"
set GPU_SERVICE="docker_events_gpu"
set CPU_SERVICE="docker_events_cpu"
set AUX_SERVICE="docker_events_aux"
set STATE_DIR="%ProgramData%\RigControl"
if not exist %STATE_DIR% mkdir %STATE_DIR% > nul 2>&1
set GPU_STOP_FLAG="%ProgramData%\RigControl\stop_gpu.flag"
set CPU_STOP_FLAG="%ProgramData%\RigControl\stop_cpu.flag"
set AUX_STOP_FLAG="%ProgramData%\RigControl\stop_aux.flag"
REM Read entire command from STDIN (multi-line safe)
set "RAW_CMD="
set "LINE="
:read_stdin
set "temp_line="
set /p "temp_line="
if not defined temp_line goto end_read
if not defined RAW_CMD (
    set "RAW_CMD=!temp_line!"
) else (
    for /f %%a in ('copy /Z "%~dpf0" nul') do set "CR=%%a"
    set "RAW_CMD=!RAW_CMD!!CR!!temp_line!"
)
goto read_stdin
:end_read
if "!RAW_CMD!"=="" (
    echo No command received
    exit /b 1
)
for /f "tokens=1* delims=:" %%i in ('echo !RAW_CMD!') do (
    set "FIRST_LINE=%%j"
    if "!FIRST_LINE!"=="" set "FIRST_LINE=%%i"
)
echo ================================================== >> !LOG!
echo %date% %time% >> !LOG!
echo !RAW_CMD! >> !LOG!
REM Parse first line for structured commands
for /f "tokens=1,*" %%a in ("!FIRST_LINE!") do (
    set "CMD=%%a"
    set "ARG=%%b"
)
set "CMD_LOWER=!CMD!"
set "CMD_LOWER=!CMD_LOWER:A=a!"
set "CMD_LOWER=!CMD_LOWER:B=b!"
set "CMD_LOWER=!CMD_LOWER:C=c!"
set "CMD_LOWER=!CMD_LOWER:D=d!"
set "CMD_LOWER=!CMD_LOWER:E=e!"
set "CMD_LOWER=!CMD_LOWER:F=f!"
set "CMD_LOWER=!CMD_LOWER:G=g!"
set "CMD_LOWER=!CMD_LOWER:H=h!"
set "CMD_LOWER=!CMD_LOWER:I=i!"
set "CMD_LOWER=!CMD_LOWER:J=j!"
set "CMD_LOWER=!CMD_LOWER:K=k!"
set "CMD_LOWER=!CMD_LOWER:L=l!"
set "CMD_LOWER=!CMD_LOWER:M=m!"
set "CMD_LOWER=!CMD_LOWER:N=n!"
set "CMD_LOWER=!CMD_LOWER:O=o!"
set "CMD_LOWER=!CMD_LOWER:P=p!"
set "CMD_LOWER=!CMD_LOWER:Q=q!"
set "CMD_LOWER=!CMD_LOWER:R=r!"
set "CMD_LOWER=!CMD_LOWER:S=s!"
set "CMD_LOWER=!CMD_LOWER:T=t!"
set "CMD_LOWER=!CMD_LOWER:U=u!"
set "CMD_LOWER=!CMD_LOWER:V=v!"
set "CMD_LOWER=!CMD_LOWER:W=w!"
set "CMD_LOWER=!CMD_LOWER:X=x!"
set "CMD_LOWER=!CMD_LOWER:Y=y!"
set "CMD_LOWER=!CMD_LOWER:Z=z!"
if "!CMD_LOWER!"=="gpu.start" goto gpu_start
if "!CMD_LOWER!"=="gpu.stop" goto gpu_stop
if "!CMD_LOWER!"=="gpu.restart" goto gpu_restart
if "!CMD_LOWER!"=="cpu.start" goto cpu_start
if "!CMD_LOWER!"=="cpu.stop" goto cpu_stop
if "!CMD_LOWER!"=="cpu.restart" goto cpu_restart
if "!CMD_LOWER!"=="aux.start" goto aux_start
if "!CMD_LOWER!"=="aux.stop" goto aux_stop
if "!CMD_LOWER!"=="aux.restart" goto aux_restart
if "!CMD_LOWER!"=="mode.set" goto mode_set
if "!CMD_LOWER!"=="reboot" goto reboot_system
if "!CMD_LOWER!"=="miners" goto MINERS
if "!CMD_LOWER!"=="gpustatus" goto GPU_STATUS
if "!CMD_LOWER!"=="processes" goto PROCESSES
if "!CMD_LOWER!"=="network" goto NETWORK
if "!CMD_LOWER!"=="disks" goto DISKS
goto raw_execution
REM GPU Miner Controls
:gpu_start
if exist !GPU_STOP_FLAG! del !GPU_STOP_FLAG! > nul 2>&1
sc start !GPU_SERVICE!
echo Started !GPU_SERVICE!
goto :eof
:gpu_stop
echo stop> !GPU_STOP_FLAG!
sc stop !GPU_SERVICE!
echo Stopped !GPU_SERVICE!
goto :eof
:gpu_restart
if exist !GPU_STOP_FLAG! del !GPU_STOP_FLAG! > nul 2>&1
sc stop !GPU_SERVICE!
timeout /t 2 /nobreak > nul
sc start !GPU_SERVICE!
echo Restarted !GPU_SERVICE!
goto :eof
REM CPU Miner Controls
:cpu_start
if exist !CPU_STOP_FLAG! del !CPU_STOP_FLAG! > nul 2>&1
sc start !CPU_SERVICE!
echo Started !CPU_SERVICE!
goto :eof
:cpu_stop
echo stop> !CPU_STOP_FLAG!
sc stop !CPU_SERVICE!
echo Stopped !CPU_SERVICE!
goto :eof
:cpu_restart
if exist !CPU_STOP_FLAG! del !CPU_STOP_FLAG! > nul 2>&1
sc stop !CPU_SERVICE!
timeout /t 2 /nobreak > nul
sc start !CPU_SERVICE!
echo Restarted !CPU_SERVICE!
goto :eof
REM AUX Service Controls
:aux_start
if exist !AUX_STOP_FLAG! del !AUX_STOP_FLAG! > nul 2>&1
sc start !AUX_SERVICE!
echo Started !AUX_SERVICE!
goto :eof
:aux_stop
echo stop> !AUX_STOP_FLAG!
sc stop !AUX_SERVICE!
echo Stopped !AUX_SERVICE!
goto :eof
:aux_restart
if exist !AUX_STOP_FLAG! del !AUX_STOP_FLAG! > nul 2>&1
sc stop !AUX_SERVICE!
timeout /t 2 /nobreak > nul
sc start !AUX_SERVICE!
echo Restarted !AUX_SERVICE!
goto :eof
REM MODE SWITCHING
:mode_set
set "MODE=!ARG!"
set "MODE=!MODE:a=A!"
set "MODE=!MODE:b=B!"
set "MODE=!MODE:c=C!"
set "MODE=!MODE:d=D!"
set "MODE=!MODE:e=E!"
set "MODE=!MODE:f=F!"
set "MODE=!MODE:g=G!"
set "MODE=!MODE:h=H!"
set "MODE=!MODE:i=I!"
set "MODE=!MODE:j=J!"
set "MODE=!MODE:k=K!"
set "MODE=!MODE:l=L!"
set "MODE=!MODE:m=M!"
set "MODE=!MODE:n=N!"
set "MODE=!MODE:o=O!"
set "MODE=!MODE:p=P!"
set "MODE=!MODE:q=Q!"
set "MODE=!MODE:r=R!"
set "MODE=!MODE:s=S!"
set "MODE=!MODE:t=T!"
set "MODE=!MODE:u=U!"
set "MODE=!MODE:v=V!"
set "MODE=!MODE:w=W!"
set "MODE=!MODE:x=X!"
set "MODE=!MODE:y=Y!"
set "MODE=!MODE:z=Z!"
echo stop> !CPU_STOP_FLAG!
echo stop> !GPU_STOP_FLAG!
sc stop !CPU_SERVICE! > nul 2>&1
sc stop !GPU_SERVICE! > nul 2>&1
sc config !CPU_SERVICE! start= disabled > nul 2>&1
sc config !GPU_SERVICE! start= disabled > nul 2>&1
if "!MODE!"=="CPU" (
    if exist !CPU_STOP_FLAG! del !CPU_STOP_FLAG! > nul 2>&1
    sc config !CPU_SERVICE! start= auto > nul 2>&1
    sc start !CPU_SERVICE!
    echo Mode changed ^-> CPU
    goto :eof
)
if "!MODE!"=="GPU" (
    if exist !GPU_STOP_FLAG! del !GPU_STOP_FLAG! > nul 2>&1
    sc config !GPU_SERVICE! start= auto > nul 2>&1
    sc start !GPU_SERVICE!
    echo Mode changed ^-> GPU
    goto :eof
)
echo Invalid mode: !ARG!
exit /b 1
REM SYSTEM REBOOT
:reboot_system
echo Rebooting system...
shutdown /r /t 0
goto :eof
:MINERS
echo [Monitoring] miners >> !LOG!
echo Checking for miner processes...
echo.
echo ===== NVIDIA GPU Processes =====
where nvidia-smi >nul 2>nul
if !ERRORLEVEL! equ 0 (
    nvidia-smi --query-compute-apps=pid,process_name,gpu_uuid --format=csv,noheader
) else (
    echo nvidia-smi not available
)
echo.
echo ===== Windows Processes =====
tasklist | findstr /i "xmrig t-rex nbminer lolminer bzminer rigel SRBMiner SRBMiner-MULTI gminer onezerominer wildrig"
echo.
echo ===== Mining Services =====
sc query | findstr /i "miner xmrig t-rex trex nbminer lolminer bzminer rigel SRBMiner SRBMiner-MULTI gminer onezerominer wildrig"
exit /b 0
:GPU_STATUS
echo [Monitoring] gpustatus >> !LOG!
where nvidia-smi >nul 2>nul
if !ERRORLEVEL! equ 0 (
    echo ===== NVIDIA GPU Status =====
    nvidia-smi
) else (
    echo NVIDIA GPU not detected or nvidia-smi not available
    echo.
    echo ===== Generic GPU Info =====
    wmic path win32_videocontroller get name,adapterram,driverversion /format:list
)
exit /b 0
:PROCESSES
echo [Monitoring] processes >> !LOG!
echo ===== Top Processes by CPU =====
powershell "Get-Process | Sort-Object CPU -Descending | Select-Object -First 20 ProcessName,CPU,WorkingSet64,Id | Format-Table -AutoSize"
echo.
echo ===== Top Processes by Memory =====
powershell "Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 20 ProcessName,CPU,WorkingSet64,Id | Format-Table -AutoSize"
exit /b 0
:NETWORK
echo [Monitoring] network >> !LOG!
echo ===== Network Adapters =====
ipconfig | findstr /v /c:"Media disconnected"
echo.
echo ===== Active Connections =====
netstat -an | findstr /i "established"
exit /b 0
:DISKS
echo [Monitoring] disks >> !LOG!
echo ===== Disk Usage =====
wmic logicaldisk get size,freespace,caption
echo.
echo ===== Detailed Disk Info =====
powershell "Get-WmiObject Win32_LogicalDisk | Format-Table DeviceID, @{Name='Size(GB)';Expression={[math]::round($_.Size/1GB,2)}}, @{Name='Free(GB)';Expression={[math]::round($_.FreeSpace/1GB,2)}}, @{Name='Free(%)';Expression={[math]::round(($_.FreeSpace/$_.Size)*100,2)}} -AutoSize"
exit /b 0
REM RAW MULTI-LINE SHELL COMMAND (DEFAULT)
:raw_execution
echo [Raw Execution] >> !LOG!
echo Executing raw command: !RAW_CMD!
echo.
echo !RAW_CMD! | findstr /i "^powershell " >nul
if !ERRORLEVEL! equ 0 (
    !RAW_CMD!
    exit /b !ERRORLEVEL!
)
echo !RAW_CMD! | findstr /i "^cmd " >nul
if !ERRORLEVEL! equ 0 (
    !RAW_CMD!
    exit /b !ERRORLEVEL!
)
echo !RAW_CMD! | findstr /i "get- \| select- format- where- " >nul
if !ERRORLEVEL! equ 0 (
    powershell "!RAW_CMD!"
    exit /b !ERRORLEVEL!
)
for /f "tokens=1,* delims= " %%a in ("!RAW_CMD!") do (
    set "EXE=%%a"
    set "ARGS=%%b"
)
where "!EXE!" >nul 2>nul
if !ERRORLEVEL! equ 0 (
    !RAW_CMD!
    exit /b !ERRORLEVEL!
)
!RAW_CMD!
exit /b !ERRORLEVEL!
goto :eof
