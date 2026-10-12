@echo off
rem Opens the app at http://localhost:8765 (needed for Windows notifications)
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0server.ps1"
