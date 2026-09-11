@echo off
cd %~dp0
cls

if not exist C:\Temp mkdir C:\Temp

:loop

powershell -NoProfile -Command "& { .\quanpool-miner-6.2.0-windows-x86_64.exe serve --node-addr 51.222.9.98:9834 --auth-token wallet.worker --tls-cert-sha256 87dc37af6096a3ddc860b94368ca087775f3ad3e0c4e9bcff3b07ea08d8abef6 2>&1 | Tee-Object -FilePath 'C:\Temp\gpu-miner.log' -Append; exit $LASTEXITCODE }"



if ERRORLEVEL 1 goto custom
timeout /t 5
goto loop

:custom
echo Custom command here
timeout /t 5
goto loop
