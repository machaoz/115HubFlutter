@echo off
setlocal EnableExtensions
set "BASH_EXE="

REM step1: bash in PATH
where bash >nul 2>nul && set "BASH_EXE=bash"

REM step2: common Git for Windows install paths
if not defined BASH_EXE if exist "C:/Program Files/Git/bin/bash.exe" set "BASH_EXE=C:/Program Files\Git\bin\bash.exe"
if not defined BASH_EXE if exist "C:/Program Files/Git/usr/bin/bash.exe" set "BASH_EXE=C:/Program Files\Git\usr\bin\bash.exe"
if not defined BASH_EXE if exist "C:/Program Files (x86)/Git/bin/bash.exe" set "BASH_EXE=C:/Program Files (x86)\Git\bin\bash.exe"
if not defined BASH_EXE if exist "C:/Program Files (x86)/Git/usr/bin/bash.exe" set "BASH_EXE=C:/Program Files (x86)\Git\usr\bin\bash.exe"

REM step3: derive from git --exec-path
if not defined BASH_EXE for /f "delims=" %%E in ('git --exec-path 2^>nul') do if not defined BASH_EXE if exist "%%E\..\..\bin\bash.exe" set "BASH_EXE=%%E\..\..\bin\bash.exe"

REM step4: derive from where git
if not defined BASH_EXE for /f "delims=" %%G in ('where git 2^>nul') do if not defined BASH_EXE ( if exist "%%~dpG..\bin\bash.exe" set "BASH_EXE=%%~dpG..\bin\bash.exe" & if not defined BASH_EXE if exist "%%~dpG..\..\bin\bash.exe" set "BASH_EXE=%%~dpG..\..\bin\bash.exe" & if not defined BASH_EXE if exist "%%~dpG..\usr\bin\bash.exe" set "BASH_EXE=%%~dpG..\usr\bin\bash.exe" )

if not defined BASH_EXE (
  echo [fail] bash not found. Install Git for Windows, or run ./lunch inside Git Bash.
  exit /b 1
)

"%BASH_EXE%" "%~dp0lunch" %*
