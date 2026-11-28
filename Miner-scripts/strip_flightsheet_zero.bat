@echo off
REM ================================================================================
REM WARNING - FOR TESTING / EXPERIMENTAL PURPOSES ONLY
REM OctaSpace gives a clear warning about mining outside of its own idle mining
REM platform (idle jobs). A miner or other heavy workload started on a node any
REM other way keeps running during a rental and takes the GPU, CPU or memory the
REM renter paid for, and a node caught doing this can be taken off the marketplace.
REM https://docs.octa.space/idle-jobs  (section: Do not run workloads outside idle jobs)
REM Use at your own risk.
REM ================================================================================
setlocal
title Strip Flightsheet '0' Column
set DB_PATH=%~dp0rigcloud_flightsheets.db
set SCRIPT_PATH=%~dp0strip_flightsheet_zero.py
if not exist "%DB_PATH%" (
    echo ERROR: DB file not found at:
    echo   %DB_PATH%
    echo Edit DB_PATH at the top of this .bat to point at the right file.
    echo.
    pause
    exit /b 1
)
if not exist "%SCRIPT_PATH%" (
    echo ERROR: strip_flightsheet_zero.py not found at:
    echo   %SCRIPT_PATH%
    echo Put it in the same folder as this .bat, or edit SCRIPT_PATH above.
    echo.
    pause
    exit /b 1
)
echo ================================================================
echo  DRY RUN - showing what would change, nothing written yet
echo  DB:     %DB_PATH%
echo ================================================================
echo.
python "%SCRIPT_PATH%" "%DB_PATH%"
echo.
echo ================================================================
echo  Review the diff above carefully.
echo ================================================================
set /p CONFIRM="Apply these changes to the DB now? (y/N): "
if /i "%CONFIRM%"=="y" (
    echo.
    echo Writing changes...
    python "%SCRIPT_PATH%" "%DB_PATH%" --write
    echo.
    echo Done.
) else (
    echo.
    echo No changes written.
)
echo.
pause
