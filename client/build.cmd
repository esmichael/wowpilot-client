@echo off
rem Compila o WowPilotSync.exe com o csc.exe que ja vem no Windows (.NET Framework 4) — sem instalar nada.
rem O SDK do WebView2 (client\webview2) vai embutido: o .exe continua um arquivo so.
setlocal
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
cd /d "%~dp0WowPilotSync"
"%CSC%" /nologo /codepage:65001 /target:winexe /optimize+ /platform:anycpu /out:..\WowPilotSync.exe /win32icon:app.ico /win32manifest:app.manifest /resource:app.ico,WowPilot.app.ico /resource:..\..\WowPilot.toc,addon.WowPilot.toc /resource:..\..\WowPilot.lua,addon.WowPilot.lua /resource:..\..\WowPilotLive.lua,addon.WowPilotLive.lua /resource:..\..\WowPilotPulse.lua,addon.WowPilotPulse.lua /resource:..\..\WowPilotGuides.lua,addon.WowPilotGuides.lua /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:..\webview2\Microsoft.Web.WebView2.Core.dll /r:..\webview2\Microsoft.Web.WebView2.WinForms.dll /resource:..\webview2\Microsoft.Web.WebView2.Core.dll,webview2.Microsoft.Web.WebView2.Core.dll /resource:..\webview2\Microsoft.Web.WebView2.WinForms.dll,webview2.Microsoft.Web.WebView2.WinForms.dll /resource:..\webview2\x64\WebView2Loader.dll,webview2.x64.WebView2Loader.dll /resource:..\webview2\x86\WebView2Loader.dll,webview2.x86.WebView2Loader.dll /resource:..\webview2\arm64\WebView2Loader.dll,webview2.arm64.WebView2Loader.dll *.cs
exit /b %ERRORLEVEL%
