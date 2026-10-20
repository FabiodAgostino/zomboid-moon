@echo off
rem ==============================================================================================================
rem  Moon: installs, updates or removes on YOUR computer the mods for playing on RiversideMoon:
rem    Silenziatori  - the suppressor mod (a fixed, Italian copy of Kiidxatlas' Simple Suppressors), copied into
rem                    %UserProfile%\Zomboid\mods. Everybody needs it: the server runs it.
rem    Admin-Scorte  - ZomBOT's windows for the bases' stocks (ZomBotData.lua and ZomBotStockUI.lua), copied into
rem                    the game's media\lua folders. They show something only to the server's admins, and the server
rem                    refuses their changes from anyone else. It is not a mod of the server's list on purpose: then
rem                    everybody would have to install it to join.
rem  Double click it. If the game is not in a Steam library, drag the ProjectZomboid folder onto this file.
rem  The file must keep Windows line endings (CRLF): see .gitattributes. Colours need Windows 10 or later.
rem ==============================================================================================================
setlocal EnableExtensions DisableDelayedExpansion
for /f "tokens=2 delims=:." %%c in ('chcp') do set "OLDCP=%%c"
chcp 65001 >nul
title Moon - le mod per RiversideMoon
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
set "N=%ESC%[0m"
set "B=%ESC%[1m"
set "D=%ESC%[90m"
set "G=%ESC%[92m"
set "Y=%ESC%[93m"
set "R=%ESC%[91m"
set "C=%ESC%[96m"
set "OK=%G%√%N%"
set "KO=%R%×%N%"

set "HERE=%~dp0"
set "SILSRC=%HERE%mods\Silenziatori"
set "ADMSRC=%HERE%admin-scorte"
if not exist "%SILSRC%\42\mod.info" goto not_extracted
if not exist "%ADMSRC%\client\ZomBotStockUI.lua" goto not_extracted
if not exist "%ADMSRC%\shared\ZomBotData.lua" goto not_extracted
if not defined USERPROFILE goto no_profile

set "ZOMBOID=%USERPROFILE%\Zomboid"
set "SILDEST=%ZOMBOID%\mods\Silenziatori"
set "VERSION="
for /f "tokens=1,* delims==" %%a in ('findstr /b /c:"modversion=" "%SILSRC%\42\mod.info"') do set "VERSION=%%b"
set "NFILES=0"
for /f %%n in ('dir /s /b /a-d "%SILSRC%" ^| find /c /v ""') do set "NFILES=%%n"

rem the game: the folder dragged onto this file, then Steam's own folder, then every Steam library
set "GAME="
set "DRAGGED_WRONG="
if not "%~1"=="" call :try_game "%~1"
if not "%~1"=="" if not defined GAME set "DRAGGED_WRONG=1"
if not defined GAME call :try_game "%ProgramFiles(x86)%\Steam\steamapps\common\ProjectZomboid"
if not defined GAME call :find_steam

rem ==============================================================================================================
:menu
call :status
cls
call :banner
echo   %B%Sul tuo computer%N%
echo.
echo     Silenziatori      %SILSTATE%
echo     Admin-Scorte      %ADMSTATE%
echo     Project Zomboid   %GAMESTATE%
if defined DRAGGED_WRONG echo     %Y%La cartella che hai trascinato non contiene Project Zomboid.%N%
echo.
echo   %B%Cosa vuoi fare?%N%
echo.
echo     %C%[1]%N%  Installa o aggiorna le mod per giocare      %D%Silenziatori%N%
echo     %C%[2]%N%  Installa o aggiorna tutto, anche da admin   %D%Silenziatori + Admin-Scorte%N%
echo     %C%[3]%N%  Disinstalla
echo     %C%[0]%N%  Esci
echo.
choice /c 1230 /n /m "  Premi il numero: "
if errorlevel 4 goto quit
if errorlevel 3 goto uninstall_menu
if errorlevel 2 goto install_all
goto install_user

rem ==============================================================================================================
:install_user
set "WITH_ADMIN="
set "STEPS=3"
goto install

:install_all
set "WITH_ADMIN=1"
set "STEPS=4"

:install
cls
call :banner
if defined WITH_ADMIN (echo   %B%Installo Silenziatori e Admin-Scorte%N%) else echo   %B%Installo Silenziatori%N%
echo.
echo   %C%[1/%STEPS%]%N% Controllo che Project Zomboid sia chiuso
echo         %D%i file di una mod non si possono cambiare mentre il gioco li sta usando%N%
call :wait_game_closed
echo         %OK% il gioco è chiuso
echo.
echo   %C%[2/%STEPS%]%N% Preparo la cartella delle mod
echo         %D%» %ZOMBOID%\mods%N%
if not exist "%ZOMBOID%\mods\" mkdir "%ZOMBOID%\mods" 2>nul
if not exist "%ZOMBOID%\mods\" goto failed_mods
echo         %OK% pronta
echo.
echo   %C%[3/%STEPS%]%N% Installo %B%Silenziatori%N% %D%%VERSION%%N%
echo         %D%i silenziatori per le armi, in italiano e senza i bug dell'originale%N%
call :installed_version
if defined INSTALLED echo         %D%» sostituisco la versione %INSTALLED% che hai già%N%
echo         %D%» copio %NFILES% file in %SILDEST%%N%
robocopy "%SILSRC%" "%SILDEST%" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 goto failed_mods
echo         %OK% Silenziatori installata
if not defined WITH_ADMIN goto install_done
echo.
echo   %C%[4/%STEPS%]%N% Installo %B%Admin-Scorte%N%
echo         %D%le finestre di ZomBOT per gestire le basi e le loro scorte%N%
echo         %D%funzionano solo se sei admin sul server: per gli altri non fanno niente%N%
if not defined GAME goto install_no_game
echo         %D%» ZomBotData.lua     in %GAME%\media\lua\shared%N%
copy /y "%ADMSRC%\shared\ZomBotData.lua" "%GAME%\media\lua\shared\ZomBotData.lua" >nul 2>nul || goto failed_game
echo         %D%» ZomBotStockUI.lua  in %GAME%\media\lua\client%N%
copy /y "%ADMSRC%\client\ZomBotStockUI.lua" "%GAME%\media\lua\client\ZomBotStockUI.lua" >nul 2>nul || goto failed_game
echo         %OK% Admin-Scorte installata
goto install_done

:install_no_game
echo         %KO% non trovo Project Zomboid: Admin-Scorte non è installata
echo         %D%chiudi questa finestra e trascina la cartella ProjectZomboid su mod-moon-server.bat%N%
echo.
echo   %Y%Silenziatori è pronta, Admin-Scorte no.%N%
goto back_to_menu

:install_done
echo.
echo   %G%╔════════════════════════════════════════════════════════╗%N%
echo   %G%║%N%  %B%Tutto pronto.%N%                                         %G%║%N%
echo   %G%╚════════════════════════════════════════════════════════╝%N%
echo.
echo   Avvia Project Zomboid ed entra su RiversideMoon come sempre:
echo   le mod le attiva il server, non devi attivare niente tu.
if defined WITH_ADMIN echo   Da admin: tasto destro sul pavimento, %C%«ZomBOT: basi...»%N%.
echo   Quando esce una nuova versione, scaricala e rilancia questo file.
goto back_to_menu

rem ==============================================================================================================
:uninstall_menu
cls
call :banner
echo   %B%Disinstalla%N%
echo.
echo     %C%[1]%N%  Togli solo Admin-Scorte
echo     %C%[2]%N%  Togli tutto                %D%Silenziatori + Admin-Scorte%N%
echo     %C%[0]%N%  Torna indietro
echo.
echo   %D%Senza Silenziatori non puoi entrare su RiversideMoon.%N%
echo.
choice /c 120 /n /m "  Premi il numero: "
if errorlevel 3 goto menu
if errorlevel 2 goto uninstall_all
goto uninstall_admin

:uninstall_admin
set "STEPS=2"
cls
call :banner
echo   %B%Tolgo Admin-Scorte%N%
echo.
echo   %C%[1/%STEPS%]%N% Controllo che Project Zomboid sia chiuso
call :wait_game_closed
echo         %OK% il gioco è chiuso
echo.
echo   %C%[2/%STEPS%]%N% Tolgo %B%Admin-Scorte%N% dalla cartella del gioco
call :remove_admin || goto failed_game
goto uninstall_done

:uninstall_all
set "STEPS=3"
cls
call :banner
echo   %B%Tolgo tutto%N%
echo.
echo   %C%[1/%STEPS%]%N% Controllo che Project Zomboid sia chiuso
call :wait_game_closed
echo         %OK% il gioco è chiuso
echo.
echo   %C%[2/%STEPS%]%N% Tolgo %B%Silenziatori%N%
echo         %D%» %SILDEST%%N%
if exist "%SILDEST%\" rmdir /s /q "%SILDEST%"
if exist "%SILDEST%\" goto failed_mods
echo         %OK% Silenziatori tolta
echo.
echo   %C%[3/%STEPS%]%N% Tolgo %B%Admin-Scorte%N% dalla cartella del gioco
call :remove_admin || goto failed_game

:uninstall_done
echo.
echo   %G%╔════════════════════════════════════════════════════════╗%N%
echo   %G%║%N%  %B%Fatto.%N%                                                %G%║%N%
echo   %G%╚════════════════════════════════════════════════════════╝%N%
echo.
echo   Per rimettere le mod rilancia questo file e premi 1 o 2.
goto back_to_menu

rem ==============================================================================================================
:not_extracted
echo.
echo   %R%Accanto a mod-moon-server.bat mancano le cartelle "mods" e "admin-scorte".%N%
echo   Se l'hai aperto dallo ZIP: tasto destro sullo ZIP, "Estrai tutto...",
echo   poi lancia mod-moon-server.bat dalla cartella estratta.
goto end_pause

:no_profile
echo.
echo   %R%Non trovo la cartella del tuo utente di Windows.%N%
echo   Lancia mod-moon-server.bat con un doppio clic.
goto end_pause

:failed_mods
echo.
echo   %KO% %R%Non riesco a scrivere in "%ZOMBOID%\mods".%N%
echo   Chiudi il gioco e riprova.
goto back_to_menu

:failed_game
echo.
echo   %KO% %R%Non riesco a scrivere nella cartella del gioco: "%GAME%\media\lua".%N%
echo   Chiudi il gioco e riprova, oppure tasto destro su mod-moon-server.bat, "Esegui come amministratore".
goto back_to_menu

:back_to_menu
echo.
echo   %D%Premi un tasto per tornare al menu.%N%
pause >nul
goto menu

:end_pause
echo.
pause
:quit
if defined OLDCP chcp %OLDCP% >nul
endlocal
exit /b 0

rem ==============================================================================================================
rem subroutines

:banner
echo.
echo   %C%╔════════════════════════════════════════════════════════╗%N%
echo   %C%║%N%  %B%MOON%N%  ·  le mod per giocare su %B%RiversideMoon%N%          %C%║%N%
echo   %C%╚════════════════════════════════════════════════════════╝%N%
echo   %D%Silenziatori %VERSION%  ·  Admin-Scorte%N%
echo.
exit /b 0

:status
rem what is on this computer now, as the menu shows it
call :installed_version
if not defined INSTALLED (set "SILSTATE=%Y%non installata%N%") else if "%INSTALLED%"=="%VERSION%" (set "SILSTATE=%G%installata%N% %D%versione %INSTALLED%%N%") else set "SILSTATE=%Y%da aggiornare%N% %D%hai la %INSTALLED%, c'è la %VERSION%%N%"
if not defined GAME (
    set "GAMESTATE=%R%non trovato%N% %D%trascina la cartella ProjectZomboid su mod-moon-server.bat%N%"
    set "ADMSTATE=%D%serve la cartella del gioco%N%"
    exit /b 0
)
set "GAMESTATE=%D%%GAME%%N%"
set "ADMSTATE=%D%non installata, serve solo agli admin%N%"
set "ADMIN_FILES=0"
if exist "%GAME%\media\lua\shared\ZomBotData.lua" set /a ADMIN_FILES+=1
if exist "%GAME%\media\lua\client\ZomBotStockUI.lua" set /a ADMIN_FILES+=1
if "%ADMIN_FILES%"=="0" exit /b 0
set "ADMSTATE=%Y%da aggiornare%N%"
fc /b "%ADMSRC%\shared\ZomBotData.lua" "%GAME%\media\lua\shared\ZomBotData.lua" >nul 2>nul || exit /b 0
fc /b "%ADMSRC%\client\ZomBotStockUI.lua" "%GAME%\media\lua\client\ZomBotStockUI.lua" >nul 2>nul || exit /b 0
set "ADMSTATE=%G%installata%N% %D%funziona solo per gli admin%N%"
exit /b 0

:installed_version
rem the version of Silenziatori in the mods folder, if any
set "INSTALLED="
if not exist "%SILDEST%\42\mod.info" exit /b 0
for /f "tokens=1,* delims==" %%a in ('findstr /b /c:"modversion=" "%SILDEST%\42\mod.info"') do set "INSTALLED=%%b"
if not defined INSTALLED set "INSTALLED=?"
exit /b 0

:remove_admin
if not defined GAME (
    echo         %D%non trovo Project Zomboid: non c'è niente da togliere%N%
    exit /b 0
)
echo         %D%» ZomBotData.lua     da %GAME%\media\lua\shared%N%
echo         %D%» ZomBotStockUI.lua  da %GAME%\media\lua\client%N%
if exist "%GAME%\media\lua\shared\ZomBotData.lua" del /q "%GAME%\media\lua\shared\ZomBotData.lua" 2>nul
if exist "%GAME%\media\lua\client\ZomBotStockUI.lua" del /q "%GAME%\media\lua\client\ZomBotStockUI.lua" 2>nul
if exist "%GAME%\media\lua\shared\ZomBotData.lua" exit /b 1
if exist "%GAME%\media\lua\client\ZomBotStockUI.lua" exit /b 1
echo         %OK% Admin-Scorte tolta
exit /b 0

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
echo         %Y%Project Zomboid è aperto: chiudilo, poi premi un tasto.%N%
pause >nul
goto wait_game_closed
