@echo off
rem ==============================================================================================================
rem  Moon: installs, updates or removes on YOUR computer what you need to play on RiversideMoon:
rem    1. the suppressor mod "Simple Suppressors (Moon IT)", in %UserProfile%\Zomboid\mods
rem    2. ZomBOT's windows for the bases' stocks (ZomBotData.lua and ZomBotStockUI.lua), in the game's folder.
rem       Only the server's admins see them: to everyone else they show nothing.
rem  Double click it. If the game is not in a Steam library, drag the ProjectZomboid folder onto this file.
rem  The file must keep Windows line endings (CRLF): see .gitattributes.
rem ==============================================================================================================
setlocal EnableExtensions
for /f "tokens=2 delims=:." %%c in ('chcp') do set "OLDCP=%%c"
chcp 65001 >nul
title Moon - RiversideMoon

set "HERE=%~dp0"
set "MODNAME=SimpleSuppressorsMoon"
set "MODSRC=%HERE%mods\%MODNAME%"
set "ZBSRC=%HERE%zombot"

if not exist "%MODSRC%\42\mod.info" goto not_extracted
if not exist "%ZBSRC%\client\ZomBotStockUI.lua" goto not_extracted
if not exist "%ZBSRC%\shared\ZomBotData.lua" goto not_extracted
if not defined USERPROFILE goto no_profile

set "ZOMBOID=%USERPROFILE%\Zomboid"
set "MODDEST=%ZOMBOID%\mods\%MODNAME%"
set "VERSION="
for /f "tokens=1,* delims==" %%a in ('findstr /b /c:"modversion=" "%MODSRC%\42\mod.info"') do set "VERSION=%%b"

rem the game: the folder dragged onto this file, then Steam's own folder, then every Steam library
set "GAME="
set "DRAGGED_WRONG="
if not "%~1"=="" call :try_game "%~1"
if not "%~1"=="" if not defined GAME set "DRAGGED_WRONG=1"
if not defined GAME call :try_game "%ProgramFiles(x86)%\Steam\steamapps\common\ProjectZomboid"
if not defined GAME call :find_steam

:menu
cls
echo.
echo   ==================================================
echo    Moon - per giocare su RiversideMoon
echo   ==================================================
echo.
echo   Mod dei silenziatori: Simple Suppressors (Moon IT) %VERSION%
echo   Cartella delle mod:   %ZOMBOID%\mods
if defined GAME echo   Gioco trovato in:     %GAME%
if not defined GAME echo   Gioco: NON TROVATO. La mod si installa lo stesso, le finestre degli admin no.
if not defined GAME echo   Per installarle trascina la cartella ProjectZomboid su installa.bat.
if defined DRAGGED_WRONG echo   Attenzione: la cartella trascinata non contiene Project Zomboid.
echo.
echo   [I] Installa o aggiorna
echo   [D] Disinstalla tutto
echo   [E] Esci senza fare nulla
echo.
choice /c IDE /n /m "  Scegli (I, D o E): "
if errorlevel 3 goto quit
if errorlevel 2 goto uninstall
goto install

:install
call :wait_game_closed
echo.
echo   Installo la mod dei silenziatori...
if not exist "%ZOMBOID%\mods\" mkdir "%ZOMBOID%\mods" || goto failed_mods
robocopy "%MODSRC%" "%MODDEST%" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 goto failed_mods
echo   Fatto: %MODDEST%
if not defined GAME goto install_done
echo.
echo   Installo le finestre di ZomBOT per gli admin...
copy /y "%ZBSRC%\shared\ZomBotData.lua" "%GAME%\media\lua\shared\ZomBotData.lua" >nul || goto failed_game
copy /y "%ZBSRC%\client\ZomBotStockUI.lua" "%GAME%\media\lua\client\ZomBotStockUI.lua" >nul || goto failed_game
echo   Fatto: %GAME%\media\lua
:install_done
echo.
echo   Tutto pronto. Avvia Project Zomboid ed entra su RiversideMoon come sempre:
echo   la mod la attiva il server, non devi fare altro.
echo   Gli admin trovano le finestre di ZomBOT col tasto destro sul pavimento: "ZomBOT: basi...".
echo   Quando esce una nuova versione, scaricala e rilancia questo file.
goto end_pause

:uninstall
call :wait_game_closed
echo.
if exist "%MODDEST%\" rmdir /s /q "%MODDEST%"
if exist "%MODDEST%\" goto failed_mods
echo   Tolta la mod dei silenziatori.
if not defined GAME goto uninstall_done
if exist "%GAME%\media\lua\shared\ZomBotData.lua" del /q "%GAME%\media\lua\shared\ZomBotData.lua"
if exist "%GAME%\media\lua\client\ZomBotStockUI.lua" del /q "%GAME%\media\lua\client\ZomBotStockUI.lua"
if exist "%GAME%\media\lua\shared\ZomBotData.lua" goto failed_game
if exist "%GAME%\media\lua\client\ZomBotStockUI.lua" goto failed_game
echo   Tolte le finestre di ZomBOT.
:uninstall_done
echo.
echo   Fatto. Senza la mod non puoi entrare su RiversideMoon: per tornare a giocare rilancia questo file e premi I.
goto end_pause

:not_extracted
echo.
echo   Accanto a installa.bat mancano i file da installare (le cartelle "mods" e "zombot").
echo   Se l'hai aperto dallo ZIP: tasto destro sullo ZIP, "Estrai tutto...", poi lancia installa.bat
echo   dalla cartella estratta.
goto end_pause

:no_profile
echo.
echo   Non trovo la cartella del tuo utente di Windows: lancia installa.bat con un doppio clic.
goto end_pause

:failed_mods
echo.
echo   Non riesco a scrivere in "%ZOMBOID%\mods". Chiudi il gioco e riprova.
goto end_pause

:failed_game
echo.
echo   Non riesco a scrivere nella cartella del gioco: "%GAME%\media\lua".
echo   Chiudi il gioco e riprova, oppure tasto destro su installa.bat, "Esegui come amministratore".
goto end_pause

:end_pause
echo.
pause
:quit
if defined OLDCP chcp %OLDCP% >nul
endlocal
exit /b 0

rem ---------------------------------------------------------------------------------------------------------------

:try_game
rem %1 is the game when it has the game's Lua folder and its launcher
if exist "%~1\media\lua\client\" if exist "%~1\ProjectZomboid64.exe" set "GAME=%~1"
exit /b 0

:find_steam
rem Steam's own folder from the registry (forward slashes), then the libraries listed in libraryfolders.vdf
set "STEAM="
for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\Valve\Steam" /v SteamPath 2^>nul ^| findstr /i "SteamPath"') do set "STEAM=%%b"
if defined STEAM set "STEAM=%STEAM:/=\%"
if defined STEAM call :try_game "%STEAM%\steamapps\common\ProjectZomboid"
if defined GAME exit /b 0
if not defined STEAM set "STEAM=%ProgramFiles(x86)%\Steam"
if not exist "%STEAM%\steamapps\libraryfolders.vdf" exit /b 0
for /f "usebackq tokens=1,*" %%a in (`findstr /c:"\"path\"" "%STEAM%\steamapps\libraryfolders.vdf"`) do (
    if not defined GAME call :try_library %%b
)
exit /b 0

:try_library
rem libraryfolders.vdf writes the paths with doubled backslashes: "D:\\SteamLibrary"
set "LIB=%~1"
set "LIB=%LIB:\\=\%"
call :try_game "%LIB%\steamapps\common\ProjectZomboid"
exit /b 0

:wait_game_closed
tasklist /fi "imagename eq ProjectZomboid64.exe" 2>nul | find /i "ProjectZomboid64.exe" >nul
if errorlevel 1 exit /b 0
echo.
echo   Project Zomboid è aperto: chiudilo, poi premi un tasto per continuare.
pause >nul
goto wait_game_closed
