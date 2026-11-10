@echo off
rem Compila o WowPilotSync.exe com o csc.exe que ja vem no Windows (.NET Framework 4) — sem instalar nada.
setlocal
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
cd /d "%~dp0WowPilotSync"
"%CSC%" /nologo /codepage:65001 /target:winexe /optimize+ /platform:anycpu /out:..\WowPilotSync.exe /win32icon:app.ico /win32manifest:app.manifest /resource:app.ico,WowPilot.app.ico /resource:..\..\WowPilot.toc,addon.WowPilot.toc /resource:..\..\WowPilot.lua,addon.WowPilot.lua /resource:..\..\WowPilotLive.lua,addon.WowPilotLive.lua /resource:..\..\WowPilotPulse.lua,addon.WowPilotPulse.lua /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll *.cs
exit /b %ERRORLEVEL%
