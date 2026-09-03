@echo off
REM Pintasan untuk Command Prompt.
REM
REM   .\cek.cmd           -> cek status sekali
REM   .\cek.cmd -Watch    -> pantau terus sampai pipeline selesai
REM   .\cek.cmd -Fetch    -> ambil dulu keadaan terbaru dari GitHub
REM
REM Pakai awalan ".\". Sebagian sistem menyetel NoDefaultCurrentDirectoryInExePath=1
REM sehingga "cek" saja tidak ditemukan walau file-nya ada di folder ini.
REM
REM Sama saja dengan:
REM   powershell -ExecutionPolicy Bypass -File tekton\status.ps1

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tekton\status.ps1" %*
