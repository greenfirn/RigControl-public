@echo off
rem Copies a worker's client certificate pair (mutual TLS) from a windows pc to a linux worker.
rem usage: copy-client-cert.bat WORKER_NAME user@WORKER [CERT_DIR]
rem   WORKER_NAME = certificate name (the name used with mosquitto-client-cert.sh)
rem   user@WORKER = ssh login of the worker
rem   CERT_DIR    = folder with WORKER_NAME.crt / WORKER_NAME.key (default C:\temp\clients)
if "%~2"=="" (
    echo usage: %~nx0 WORKER_NAME user@WORKER [CERT_DIR]
    echo example: %~nx0 rig01 user@192.168.1.50 C:\temp\clients
    exit /b 1
)
set NAME=%~1
set TARGET=%~2
set CERT_DIR=%~3
if "%CERT_DIR%"=="" set CERT_DIR=C:\temp\clients
if "%CERT_DIR:~-1%"=="\" set CERT_DIR=%CERT_DIR:~0,-1%
if not exist "%CERT_DIR%\%NAME%.crt" (
    echo not found: %CERT_DIR%\%NAME%.crt
    exit /b 1
)
if not exist "%CERT_DIR%\%NAME%.key" (
    echo not found: %CERT_DIR%\%NAME%.key
    exit /b 1
)
scp "%CERT_DIR%\%NAME%.crt" "%CERT_DIR%\%NAME%.key" %TARGET%:/tmp/
if errorlevel 1 exit /b 1
ssh -t %TARGET% "sudo mkdir -p /etc/rigcontrol && sudo mv /tmp/%NAME%.crt /etc/rigcontrol/client.crt && sudo mv /tmp/%NAME%.key /etc/rigcontrol/client.key && sudo chown root:root /etc/rigcontrol/client.* && sudo chmod 600 /etc/rigcontrol/client.key"
if errorlevel 1 exit /b 1
echo copied %NAME% to %TARGET%:/etc/rigcontrol/ (client.crt, client.key)
