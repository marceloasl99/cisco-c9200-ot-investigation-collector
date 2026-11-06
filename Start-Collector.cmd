@echo off
REM Launch Cisco C9200 OT Investigation Collector GUI
REM Requires Windows PowerShell 5.1 (built-in on Win10/11/Server 2016+)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0CiscoC9200-OT-Investigation.ps1"
