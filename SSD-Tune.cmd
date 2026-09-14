@echo off
REM ---------------------------------------------------------------------
REM  Starter fuer SSD-Tune.ps1
REM
REM  Nimmt beide Stolpersteine ab: holt sich selbst Administratorrechte
REM  und startet das Skript mit -ExecutionPolicy Bypass. Das gilt nur fuer
REM  diesen einen Aufruf - an der Einstellung des Systems aendert sich
REM  nichts, und es muss vorher auch nichts von Hand gesetzt werden.
REM
REM  Doppelklick   = nur Analyse
REM  Argumente werden durchgereicht, z. B. aus einer Eingabeaufforderung:
REM      SSD-Tune.cmd -Apply
REM      SSD-Tune.cmd -Apply -BenchGB 20
REM ---------------------------------------------------------------------
setlocal
cd /d "%~dp0"

if not exist "%~dp0SSD-Tune.ps1" (
    echo FEHLER: SSD-Tune.ps1 wurde nicht gefunden.
    echo Erwartet im selben Ordner wie diese Datei:
    echo     %~dp0
    echo.
    pause
    exit /b 1
)

REM Laufen wir schon erhoeht? net session gelingt nur mit Adminrechten.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Administratorrechte werden angefordert - bitte mit Ja bestaetigen.
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SSD-Tune.ps1" %*

echo.
echo ---------------------------------------------------------------------
echo Fertig. Fenster kann geschlossen werden.
pause
