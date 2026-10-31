@echo off
rem kitplayer starter for Windows (double-click). Plays the "最適化後" folder next to this file.
chcp 65001 >nul
cd /d "%~dp0"
kitplayer.exe %*
pause
