@echo off
rem ==============================================================================================================
rem  Moon: the mods of the Moon server on YOUR computer.
rem    ZomBOT (Moon) - ZomBOT and Admin-Scorte together in one mod (id ZomBOTMoon), copied into
rem                    %UserProfile%\Zomboid\mods. Moon needs it, and it loads only there: option 1 installs or
rem                    updates it. The copies of ZomBOT and Admin-Scorte that older versions of this file put in the
rem                    game's media\lua folder (ZomBotGioco.lua, ZomBotMenu.lua, ZomBotStockUI.lua, ZomBotGravesUI.lua,
rem                    ZomBotData.lua, Moon-ZomBOT.version and Moon-Admin-Scorte.version) are loaded by the game on
rem                    every server, and a server that checks the Lua files (DoLuaChecksum, on by default) kicks
rem                    whoever has them: option 1 also removes exactly those files, nothing else.
rem    Silenziatori  - the suppressor mod (a fixed, Italian copy of Kiidxatlas' Simple Suppressors), copied into
rem                    %UserProfile%\Zomboid\mods. DISABLED for now (the user, 28/10/2026): shown as «Disattivata»,
rem                    not installed, but still removed by option 3 for whoever has it. To turn it back on, empty
rem                    SIL_DISABLED below: one line.
rem  Double click it. If the game is not in a Steam library, drag the ProjectZomboid folder onto this file.
rem  The file must keep Windows line endings (CRLF): see .gitattributes. Colours need Windows 10 or later.
rem ==============================================================================================================
setlocal EnableExtensions DisableDelayedExpansion

rem Silenziatori: 1 = disabled («Disattivata», never installed), empty = installable again
set "SIL_DISABLED=1"

rem the old files of ZomBOT and Admin-Scorte in the game's media\lua: exactly these, nothing else
set "OLDFILES=client\ZomBotGioco.lua client\ZomBotMenu.lua client\ZomBotStockUI.lua client\ZomBotGravesUI.lua shared\ZomBotData.lua Moon-ZomBOT.version Moon-Admin-Scorte.version"

rem chcp reads the input: with <nul it leaves the keys to the menu, also when they come from a file
for /f "tokens=2 delims=:." %%c in ('chcp ^<nul') do set "OLDCP=%%c"
chcp 65001 >nul <nul
title Moon - le mod per il server Moon
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
set "ZBSRC=%HERE%mods\ZomBOTMoon"
set "SILSRC=%HERE%mods\Silenziatori"
if not exist "%ZBSRC%\42\mod.info" goto not_extracted
if not exist "%SILSRC%\42\mod.info" goto not_extracted
if not defined USERPROFILE goto no_profile

set "ZOMBOID=%USERPROFILE%\Zomboid"
set "ZBDEST=%ZOMBOID%\mods\ZomBOTMoon"
set "SILDEST=%ZOMBOID%\mods\Silenziatori"
call :read_version "%ZBSRC%\42\mod.info" ZBVER
call :read_version "%SILSRC%\42\mod.info" SILVER
if not defined ZBVER set "ZBVER=?"
if not defined SILVER set "SILVER=?"
call :count_files "%ZBSRC%" ZBFILES
call :count_files "%SILSRC%" SILFILES

rem the versions in a column 15 wide, for the menu's table
set "ZBVERP=%ZBVER%               "
set "ZBVERP=%ZBVERP:~0,15%"
set "SILVERP=%SILVER%               "
set "SILVERP=%SILVERP:~0,15%"

rem what the menu shows, with Silenziatori on or off
set "SILKIND=%G%Installabile%N%"
set "BANNERLINE=ZomBOT (Moon) %ZBVER%  ·  Silenziatori %SILVER%"
if defined SIL_DISABLED set "SILKIND=%D%Disattivata %N%"
if defined SIL_DISABLED set "BANNERLINE=ZomBOT (Moon) %ZBVER%  ·  Silenziatori disattivata"

rem the game: the folder dragged onto this file, then Steam's own folder, then every Steam library
set "GAME="
set "DRAGGED_WRONG="
if not "%~1"=="" call :try_game "%~1"
if not "%~1"=="" if not defined GAME set "DRAGGED_WRONG=1"
if not defined GAME call :try_game "%ProgramFiles(x86)%\Steam\steamapps\common\ProjectZomboid"
if not defined GAME call :find_steam
set "LUA="
if defined GAME set "LUA=%GAME%\media\lua"

rem ==============================================================================================================
:menu
call :status
cls
call :banner
echo   %B%Le mod di Moon%N%
echo.
echo     %D%                  stato          versione        sul tuo computer%N%
echo     ZomBOT (Moon)     %C%Obbligatoria%N%   %ZBVERP% %ZBSTATE%
echo     Silenziatori      %SILKIND%   %SILVERP% %SILSTATE%
echo.
echo     Project Zomboid   %GAMESTATE%
if defined DRAGGED_WRONG echo     %Y%La cartella che hai trascinato non contiene Project Zomboid.%N%
echo.
if defined OLDN echo   %Y%Nella cartella del gioco ci sono ancora %OLDN% vecchi file di ZomBOT e Admin-Scorte:%N%
if defined OLDN echo   %Y%sugli altri server ti fanno espellere. Premi 1: li tolgo e installo ZomBOT (Moon).%N%
if defined OLDN echo.
echo   %B%Cosa vuoi fare?%N%
echo.
echo     %C%[1]%N%  Installa o aggiorna ZomBOT (Moon)   %D%%ZBHINT%%N%
echo     %C%[2]%N%  Installa o aggiorna Silenziatori    %D%%SILHINT%%N%
echo     %C%[3]%N%  Togli Silenziatori
echo     %C%[0]%N%  Esci
echo.
echo   %D%ZomBOT e Admin-Scorte ora sono dentro la mod ZomBOT (Moon): serve per giocare su Moon,%N%
echo   %D%sugli altri server non si carica.%N%
echo.
choice /c 1230 /n /m "  Premi il numero: "
if errorlevel 4 goto quit
if errorlevel 3 goto uninstall
if errorlevel 2 goto install
goto install_zb

rem ==============================================================================================================
:install_zb
set "STEP=0"
set "STEPS=3"
if defined OLDN set "STEPS=4"
cls
call :banner
echo   %B%Installo ZomBOT (Moon)%N%
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Controllo che Project Zomboid sia chiuso
echo         %D%i file di una mod non si possono cambiare mentre il gioco li sta usando%N%
call :wait_game_closed
echo         %OK% il gioco è chiuso
call :prepare_mods || goto failed_mods
call :install_zbmod || goto failed_mods
if not defined OLDN goto install_zb_done
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Tolgo i vecchi file di ZomBOT e Admin-Scorte
echo         %D%ora sono dentro ZomBOT (Moon); sugli altri server ti farebbero espellere%N%
echo         %D%» %LUA%%N%
set "OLDLEFT="
for %%f in (%OLDFILES%) do call :remove_old "%%f"
if defined OLDLEFT goto failed_game
echo         %OK% tolti
:install_zb_done
echo.
echo   %G%╔════════════════════════════════════════════════════════╗%N%
echo   %G%║%N%  %B%Tutto pronto.%N%                                         %G%║%N%
echo   %G%╚════════════════════════════════════════════════════════╝%N%
echo.
echo   Avvia Project Zomboid ed entra sul server Moon come sempre.
echo   Nel gioco scrivi in chat «zombot» e la domanda, per esempio «zombot dove trovo le asce?».
echo   Quando esce una nuova versione, scaricala e rilancia questo file.
if not defined GAME echo   %D%Non ho trovato la cartella del gioco: se ci sono ancora i vecchi file di ZomBOT, trascinala su questo file.%N%
goto back_to_menu

rem ==============================================================================================================
:install
if defined SIL_DISABLED goto install_off
set "STEP=0"
set "STEPS=3"
cls
call :banner
echo   %B%Installo Silenziatori%N%
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Controllo che Project Zomboid sia chiuso
echo         %D%i file di una mod non si possono cambiare mentre il gioco li sta usando%N%
call :wait_game_closed
echo         %OK% il gioco è chiuso
call :prepare_mods || goto failed_mods
call :install_sil || goto failed_mods
echo.
echo   %G%╔════════════════════════════════════════════════════════╗%N%
echo   %G%║%N%  %B%Tutto pronto.%N%                                         %G%║%N%
echo   %G%╚════════════════════════════════════════════════════════╝%N%
echo.
echo   Avvia Project Zomboid ed entra sul server Moon come sempre.
echo   Quando esce una nuova versione, scaricala e rilancia questo file.
goto back_to_menu

:install_off
echo.
echo   %Y%Silenziatori per ora è disattivata: non si installa.%N%
goto back_to_menu

rem ==============================================================================================================
:uninstall
set "STEP=0"
set "STEPS=2"
cls
call :banner
echo   %B%Tolgo Silenziatori%N%
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Controllo che Project Zomboid sia chiuso
call :wait_game_closed
echo         %OK% il gioco è chiuso
call :uninstall_sil || goto failed_mods
echo.
echo   %G%╔════════════════════════════════════════════════════════╗%N%
echo   %G%║%N%  %B%Fatto.%N%                                                %G%║%N%
echo   %G%╚════════════════════════════════════════════════════════╝%N%
goto back_to_menu

rem ==============================================================================================================
:not_extracted
echo.
echo   %R%Accanto a mod-moon-server.bat manca la cartella "mods".%N%
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
echo   %KO% %R%Non riesco a togliere i file dalla cartella del gioco: "%LUA%".%N%
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
if defined OLDCP chcp %OLDCP% >nul <nul
endlocal
exit /b 0

rem ==============================================================================================================
rem subroutines

:banner
echo.
echo   %C%╔════════════════════════════════════════════════════════╗%N%
echo   %C%║%N%  %B%MOON%N%  ·  le mod per giocare sul server %B%Moon%N%           %C%║%N%
echo   %C%╚════════════════════════════════════════════════════════╝%N%
echo   %D%%BANNERLINE%%N%
echo.
exit /b 0

:status
rem what is on this computer now, as the menu shows it: «aggiornata» when the files are the ones of this pack
call :read_version "%ZBDEST%\42\mod.info" ZBINST
if exist "%ZBDEST%\" if not defined ZBINST set "ZBINST=?"
call :read_version "%SILDEST%\42\mod.info" SILINST
if exist "%SILDEST%\" if not defined SILINST set "SILINST=?"
set "ZBHINT=%ZBVER%, serve per giocare su Moon"
set "ZBSTATE=%Y%non installata%N% %D%· senza non entri su Moon: premi 1%N%"
if not defined ZBINST goto status_sil
if not "%ZBINST%"=="%ZBVER%" goto status_zb_old
rem the same version: «aggiornata» only when the files are this pack's, byte for byte
call :compare_zb
if not defined ZBSAME goto status_zb_changed
set "ZBSTATE=%G%aggiornata%N%"
goto status_sil
:status_zb_old
set "ZBSTATE=%Y%vecchia%N% %D%· hai la %ZBINST%: premi 1 per aggiornarla%N%"
goto status_sil
:status_zb_changed
set "ZBSTATE=%Y%da aggiornare%N% %D%· i file non sono quelli di questa versione: premi 1%N%"
:status_sil
if defined SIL_DISABLED goto status_sil_off
if not defined SILINST (set "SILSTATE=%D%non installata%N%") else if "%SILINST%"=="%SILVER%" (set "SILSTATE=%G%aggiornata%N%") else set "SILSTATE=%Y%vecchia%N% %D%· hai la %SILINST%%N%"
set "SILHINT=%SILVER%"
goto status_game
:status_sil_off
if defined SILINST (set "SILSTATE=%Y%installata%N% %D%· hai la %SILINST%: non serve, puoi toglierla con 3%N%") else set "SILSTATE=%D%non installata%N%"
set "SILHINT=disattivata: per ora non si installa"
:status_game
rem the old files of ZomBOT and Admin-Scorte that are still in the game's folder
set "OLDN="
if not defined GAME set "GAMESTATE=%R%non trovato%N% %D%trascina la cartella ProjectZomboid su mod-moon-server.bat%N%"
if not defined GAME exit /b 0
set "GAMESTATE=%D%%GAME%%N%"
set "OLDCOUNT=0"
for %%f in (%OLDFILES%) do if exist "%LUA%\%%f" set /a OLDCOUNT+=1
if not "%OLDCOUNT%"=="0" set "OLDN=%OLDCOUNT%"
if defined OLDN set "ZBHINT=%ZBVER%, e tolgo %OLDN% vecchi file"
exit /b 0

:compare_zb
rem ZBSAME=1 when the installed ZomBOT (Moon) has exactly this pack's files: none missing, none extra (robocopy /L
rem with /XC /XN /XO lists only those, copying nothing), and each one the same byte for byte (fc /b, like the launcher)
set "ZBSAME="
robocopy "%ZBSRC%" "%ZBDEST%" /MIR /L /XC /XN /XO /R:0 /W:0 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 1 exit /b 0
set "ZBDIFF="
for /f "delims=" %%f in ('dir /s /b /a-d "%ZBSRC%"') do if not defined ZBDIFF call :compare_file "%%f"
if not defined ZBDIFF set "ZBSAME=1"
exit /b 0

:compare_file
rem %1 = a file of the pack's ZomBOT (Moon); ZBDIFF when the installed one is missing or different
set "REL=%~1"
call set "REL=%%REL:%ZBSRC%\=%%"
rem fc, like chcp, reads the input: with <nul it leaves the keys to the menu
fc /b "%~1" "%ZBDEST%\%REL%" >nul 2>nul <nul || set "ZBDIFF=1"
exit /b 0

:read_version
rem %1 = a mod.info, %2 = the variable that gets its modversion: empty when there is none
set "%~2="
if not exist "%~1" exit /b 0
for /f "tokens=1,* delims==" %%a in ('findstr /b /c:"modversion=" "%~1"') do set "%~2=%%b"
exit /b 0

:count_files
rem %1 = a folder, %2 = the variable that gets how many files it has
set "%~2=0"
for /f %%n in ('dir /s /b /a-d "%~1" ^| find /c /v ""') do set "%~2=%%n"
exit /b 0

:remove_old
rem %1 = one of OLDFILES, under the game's media\lua; OLDLEFT when it is still there afterwards
if not exist "%LUA%\%~1" exit /b 0
echo         %D%» %~nx1%N%
del /f /q "%LUA%\%~1" 2>nul
if exist "%LUA%\%~1" set "OLDLEFT=1"
exit /b 0

:prepare_mods
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Preparo la cartella delle mod
echo         %D%» %ZOMBOID%\mods%N%
if not exist "%ZOMBOID%\mods\" mkdir "%ZOMBOID%\mods" 2>nul
if not exist "%ZOMBOID%\mods\" exit /b 1
echo         %OK% pronta
exit /b 0

:install_zbmod
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Installo %B%ZomBOT (Moon)%N% %D%%ZBVER%%N%
echo         %D%ZomBOT e Admin-Scorte in una mod sola: serve per giocare su Moon%N%
if defined ZBINST if not "%ZBINST%"=="%ZBVER%" echo         %D%» sostituisco la versione %ZBINST% che hai già%N%
echo         %D%» copio %ZBFILES% file in %ZBDEST%%N%
rem /IS /IT: every file, also the ones with the same size and date, so that afterwards they are the same byte for byte
robocopy "%ZBSRC%" "%ZBDEST%" /MIR /IS /IT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 exit /b 1
echo         %OK% ZomBOT (Moon) installata
exit /b 0

:install_sil
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Installo %B%Silenziatori%N% %D%%SILVER%%N%
echo         %D%i silenziatori per le armi, in italiano e senza i bug dell'originale%N%
if defined SILINST echo         %D%» sostituisco la versione %SILINST% che hai già%N%
echo         %D%» copio %SILFILES% file in %SILDEST%%N%
robocopy "%SILSRC%" "%SILDEST%" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 exit /b 1
echo         %OK% Silenziatori installata
exit /b 0

:uninstall_sil
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Tolgo %B%Silenziatori%N%
echo         %D%» %SILDEST%%N%
if not exist "%SILDEST%\" goto uninstall_sil_none
rmdir /s /q "%SILDEST%"
if exist "%SILDEST%\" exit /b 1
echo         %OK% Silenziatori tolta
exit /b 0
:uninstall_sil_none
echo         %OK% Silenziatori non c'era
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
