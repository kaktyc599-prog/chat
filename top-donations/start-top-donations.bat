@echo off
chcp 65001 >nul
title Top donations updater
echo Updating top donations from DonationAlerts...
echo Keep this window open while streaming.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0top-donations-update.ps1"
echo.
echo Updater stopped. Press any key to close.
pause >nul
