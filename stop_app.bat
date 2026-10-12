@echo off
rem Stops the local app server
for /f "tokens=5" %%p in ('netstat -ano ^| findstr "127.0.0.1:8765" ^| findstr LISTENING') do taskkill /PID %%p /F >nul 2>&1
echo Stopped.
timeout /t 2 >nul
