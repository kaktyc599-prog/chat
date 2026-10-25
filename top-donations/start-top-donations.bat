@echo off
chcp 65001 >nul
title Top donations - real-time listener
echo Listening for DonationAlerts donations...
echo Every new donation updates the top instantly.
echo Keep this window open while streaming.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0top-donations-listen.ps1"
echo.
echo Listener stopped. Press any key to close.
pause >nul
