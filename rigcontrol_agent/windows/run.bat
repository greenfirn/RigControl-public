@echo off
title RigCloud Agent
cd /d "%~dp0"

echo Checking and setting up environment...

REM Check for virtual environment
if not exist ".venv" (
    echo Creating virtual environment...
    py -3.11 -m venv .venv
    
    REM Activate new environment
    call .venv\Scripts\activate.bat
    
    REM Only install requirements when creating fresh virtual environment
    REM Check requirements.txt and install if needed
    if exist "requirements.txt" (
        echo Installing dependencies...
        python -m pip install --upgrade pip
        pip install -r requirements.txt
        echo Dependencies installed successfully.
    ) else (
        echo Warning: requirements.txt not found!
        echo Please create requirements.txt in the script directory.
    )
) else (
    echo Virtual environment already exists - skipping requirements check/install.
    REM Activate existing environment
    call .venv\Scripts\activate.bat
)

REM Run the agent
echo Starting RigControl Agent...
python rigcontrol_agent_win.py

echo.
echo Agent has stopped.
pause

exit

:: run hidden
call .venv\Scripts\activate.bat
powershell -NoProfile -Command "Start-Process python -ArgumentList 'rigcloud_agent_win.py' -WindowStyle Hidden"