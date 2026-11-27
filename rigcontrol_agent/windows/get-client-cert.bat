@echo off
rem Copies a worker's client certificate pair (mutual TLS) from the server to this windows worker.
rem usage: get-client-cert.bat WORKER_NAME user@SERVER PARENT_FOLDER [DEST_DIR]
rem   WORKER_NAME   = certificate name (the name used with mosquitto-client-cert.sh)
rem   user@SERVER   = ssh login of the server
rem   PARENT_FOLDER = parent folder of mosquitto on the server (certificates are in PARENT_FOLDER/mosquitto/config/certs/clients)
rem   DEST_DIR      = where client.crt / client.key are written (default C:\rigcontrol)
if "%~3"=="" (
    echo usage: %~nx0 WORKER_NAME user@SERVER PARENT_FOLDER [DEST_DIR]
    echo example: %~nx0 rig01 user@192.168.1.10 /srv/stack C:\rigcontrol
    exit /b 1
)
set NAME=%~1
set TARGET=%~2
set PARENT=%~3
set DEST=%~4
if "%DEST%"=="" set DEST=C:\rigcontrol
if "%DEST:~-1%"=="\" set DEST=%DEST:~0,-1%
if not exist "%DEST%" mkdir "%DEST%"
scp "%TARGET%:%PARENT%/mosquitto/config/certs/clients/%NAME%.crt" "%DEST%\client.crt"
if errorlevel 1 exit /b 1
scp "%TARGET%:%PARENT%/mosquitto/config/certs/clients/%NAME%.key" "%DEST%\client.key"
if errorlevel 1 exit /b 1
echo copied %NAME% to %DEST% (client.crt, client.key)
