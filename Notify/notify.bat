@echo off
title Notify
cd /d "%~dp0"

echo Checking and setting up environment...

REM Check for virtual environment
if not exist ".venv" (
    echo Creating virtual environment...
    py -3.11 -m venv .venv
    
    REM Activate new environment
    call .venv\Scripts\activate.bat
    
    REM Only install requirements when creating fresh virtual environment
    REM Check requirements-notify.txt and install if needed
    if exist "requirements-notify.txt" (
        echo Installing dependencies...
        python -m pip install --upgrade pip
        pip install -r requirements-notify.txt
        echo Dependencies installed successfully.
    ) else (
        echo Warning: requirements-notify.txt not found!
        echo Please create requirements-notify.txt in the script directory.
    )
) else (
    echo Virtual environment already exists - skipping requirements check/install.
    REM Activate existing environment
    call .venv\Scripts\activate.bat
)

REM Run...
echo Starting Notify...
echo Command: python notify.py %*
python notify.py %*

echo.
echo Notify complete.
pause

exit /b 0
