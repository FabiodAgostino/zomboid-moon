@echo off
rem ==============================================================================================================
rem  Moon: installs, updates or removes on YOUR computer the optional mods for the Moon server. The server lists no
rem  mods (Mods= is empty): nobody needs any of them to join.
rem    Silenziatori  - the suppressor mod (a fixed, Italian copy of Kiidxatlas' Simple Suppressors), copied into
rem                    %UserProfile%\Zomboid\mods. DISABLED for now (the user, 28/10/2026): shown as «Disattivata»,
rem                    installed by no option, but still removed by «Disinstalla» for whoever has it. To turn it back
rem                    on, empty SIL_DISABLED below: one line.
rem    Admin-Scorte  - ZomBOT's bases and stocks (ZomBotData.lua, ZomBotStockUI.lua, ZomBotMenu.lua), copied into the
rem                    game's media\lua folders. An admin gets the windows (right click, «ZomBOT»); any other player
rem                    only the box under the items that says where they are missing or short in a base. The server
rem                    refuses every change from non-admins.
rem    ZomBOT        - ZomBOT for every player (ZomBotGioco.lua, ZomBotMenu.lua), copied into the game's media\lua\client:
rem                    questions to ZomBOT from the game's chat, the nearest container that blinks, coloured crates.
rem  Admin-Scorte and ZomBOT are not mods of the server's list on purpose: then everybody would have to install them to
rem  join. ZomBotMenu.lua (the one «ZomBOT» entry of the right click) is the same file in both: installing either one
rem  copies it, removing one leaves it while the other is still there (found by its own file: ZomBotStockUI.lua for
rem  Admin-Scorte, ZomBotGioco.lua for ZomBOT).
rem  Versions: each mod folder has a VERSION file (Silenziatori: modversion in mod.info). The installed version of
rem  Admin-Scorte and ZomBOT is written next to their files, media\lua\Moon-<mod>.version, and the menu compares it.
rem  The menu installs the players' mods, everything, or only the mods ticked in a list (for example only ZomBOT).
rem  Double click it. If the game is not in a Steam library, drag the ProjectZomboid folder onto this file.
rem  The file must keep Windows line endings (CRLF): see .gitattributes. Colours need Windows 10 or later.
rem ==============================================================================================================
setlocal EnableExtensions DisableDelayedExpansion

rem Silenziatori: 1 = disabled («Disattivata», never installed), empty = installable again
set "SIL_DISABLED=1"

for /f "tokens=2 delims=:." %%c in ('chcp') do set "OLDCP=%%c"
chcp 65001 >nul
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
set "SILSRC=%HERE%mods\Silenziatori"
set "ADMSRC=%HERE%admin-scorte"
set "ZBSRC=%HERE%zombot"
if not exist "%SILSRC%\42\mod.info" goto not_extracted
if not exist "%ADMSRC%\VERSION" goto not_extracted
if not exist "%ADMSRC%\client\ZomBotStockUI.lua" goto not_extracted
if not exist "%ADMSRC%\client\ZomBotMenu.lua" goto not_extracted
if not exist "%ADMSRC%\shared\ZomBotData.lua" goto not_extracted
if not exist "%ZBSRC%\VERSION" goto not_extracted
if not exist "%ZBSRC%\client\ZomBotGioco.lua" goto not_extracted
if not exist "%ZBSRC%\client\ZomBotMenu.lua" goto not_extracted
if not defined USERPROFILE goto no_profile

set "ZOMBOID=%USERPROFILE%\Zomboid"
set "SILDEST=%ZOMBOID%\mods\Silenziatori"
set "SILVER="
for /f "tokens=1,* delims==" %%a in ('findstr /b /c:"modversion=" "%SILSRC%\42\mod.info"') do set "SILVER=%%b"
call :read_version ADMVER "%ADMSRC%\VERSION"
call :read_version ZBVER "%ZBSRC%\VERSION"
if not defined SILVER set "SILVER=?"
if not defined ADMVER set "ADMVER=?"
if not defined ZBVER set "ZBVER=?"
set "NFILES=0"
for /f %%n in ('dir /s /b /a-d "%SILSRC%" ^| find /c /v ""') do set "NFILES=%%n"

rem the versions in a column 15 wide, for the menu's table
set "SILVERP=%SILVER%               "
set "SILVERP=%SILVERP:~0,15%"
set "ADMVERP=%ADMVER%               "
set "ADMVERP=%ADMVERP:~0,15%"
set "ZBVERP=%ZBVER%               "
set "ZBVERP=%ZBVERP:~0,15%"

rem what the menu offers, with Silenziatori on or off
if defined SIL_DISABLED (
    set "SILKIND=%D%Disattivata %N%"
    set "USERSET=ZomBOT"
    set "ALLSET=ZomBOT + Admin-Scorte"
    set "PICKKEYS=2 o 3"
    set "BANNERLINE=Admin-Scorte %ADMVER%  ·  ZomBOT %ZBVER%  ·  Silenziatori disattivata"
) else (
    set "SILKIND=%G%Installabile%N%"
    set "USERSET=Silenziatori + ZomBOT"
    set "ALLSET=Silenziatori + ZomBOT + Admin-Scorte"
    set "PICKKEYS=1, 2 o 3"
    set "BANNERLINE=Silenziatori %SILVER%  ·  Admin-Scorte %ADMVER%  ·  ZomBOT %ZBVER%"
)
set "ADMKIND=%G%Installabile%N%"
set "ZBKIND=%G%Installabile%N%"

rem the game: the folder dragged onto this file, then Steam's own folder, then every Steam library
set "GAME="
set "DRAGGED_WRONG="
if not "%~1"=="" call :try_game "%~1"
if not "%~1"=="" if not defined GAME set "DRAGGED_WRONG=1"
if not defined GAME call :try_game "%ProgramFiles(x86)%\Steam\steamapps\common\ProjectZomboid"
if not defined GAME call :find_steam
set "LUA="
set "ADMMARK="
set "ZBMARK="
if defined GAME set "LUA=%GAME%\media\lua"
if defined GAME set "ADMMARK=%GAME%\media\lua\Moon-Admin-Scorte.version"
if defined GAME set "ZBMARK=%GAME%\media\lua\Moon-ZomBOT.version"

rem ==============================================================================================================
:menu
call :status
cls
call :banner
echo   %B%Le mod di Moon%N%
echo.
echo     %D%                  stato          versione        sul tuo computer%N%
echo     Silenziatori      %SILKIND%   %SILVERP% %SILSTATE%
echo     Admin-Scorte      %ADMKIND%   %ADMVERP% %ADMSTATE%
echo     ZomBOT            %ZBKIND%   %ZBVERP% %ZBSTATE%
echo.
echo     Project Zomboid   %GAMESTATE%
if defined DRAGGED_WRONG echo     %Y%La cartella che hai trascinato non contiene Project Zomboid.%N%
echo.
echo   %B%Cosa vuoi fare?%N%
echo.
echo     %C%[1]%N%  Installa o aggiorna le mod per giocare      %D%%USERSET%%N%
echo     %C%[2]%N%  Installa o aggiorna tutto, anche da admin   %D%%ALLSET%%N%
echo     %C%[3]%N%  Scegli tu quali installare                  %D%per esempio solo ZomBOT%N%
echo     %C%[4]%N%  Disinstalla
echo     %C%[0]%N%  Esci
echo.
if defined SIL_DISABLED echo   %D%Per entrare sul server Moon non serve nessuna mod: sono tutte facoltative.%N%
if defined SIL_DISABLED echo.
choice /c 12340 /n /m "  Premi il numero: "
if errorlevel 5 goto quit
if errorlevel 4 goto uninstall_menu
if errorlevel 3 goto choose_start
if errorlevel 2 goto install_all
goto install_user

rem ==============================================================================================================
:install_user
set "WITH_SIL=1"
set "WITH_ADMIN="
set "WITH_ZOMBOT=1"
goto install

:install_all
set "WITH_SIL=1"
set "WITH_ADMIN=1"
set "WITH_ZOMBOT=1"
goto install

rem the list where every mod is ticked or not: its number ticks it, I installs the ticked ones
:choose_start
set "PICK_SIL="
set "PICK_ADM="
set "PICK_ZB="
set "PICK_NONE="
set "PICK_OFF="

:choose_menu
call :status
if defined PICK_SIL (set "BOXSIL=%G%[√]%N%") else set "BOXSIL=%D%[ ]%N%"
if defined PICK_ADM (set "BOXADM=%G%[√]%N%") else set "BOXADM=%D%[ ]%N%"
if defined PICK_ZB (set "BOXZB=%G%[√]%N%") else set "BOXZB=%D%[ ]%N%"
cls
call :banner
echo   %B%Scegli cosa installare%N%
echo   %D%Premi il numero di una mod per sceglierla, premilo di nuovo per toglierla.%N%
echo.
if defined SIL_DISABLED echo     %D%[1]  [-]  Silenziatori      %SILVERP% disattivata: per ora non si installa%N%
if not defined SIL_DISABLED echo     %C%[1]%N%  %BOXSIL%  Silenziatori      %SILVERP% %SILSTATE%
echo     %C%[2]%N%  %BOXADM%  Admin-Scorte      %ADMVERP% %ADMSTATE%
echo     %C%[3]%N%  %BOXZB%  ZomBOT            %ZBVERP% %ZBSTATE%
echo.
echo     %C%[I]%N%  Installa le mod scelte
echo     %C%[0]%N%  Torna indietro
echo.
if defined PICK_NONE echo   %Y%Prima scegli almeno una mod: premi %PICKKEYS%.%N%
if defined PICK_NONE echo.
if defined PICK_OFF echo   %Y%Silenziatori per ora è disattivata: non si installa.%N%
if defined PICK_OFF echo.
set "PICK_NONE="
set "PICK_OFF="
choice /c 123i0 /n /m "  Premi un numero o I: "
if errorlevel 5 goto menu
if errorlevel 4 goto choose_install
if errorlevel 3 goto choose_zombot
if errorlevel 2 goto choose_admin
if defined SIL_DISABLED (set "PICK_OFF=1") else if defined PICK_SIL (set "PICK_SIL=") else set "PICK_SIL=1"
goto choose_menu

:choose_admin
if defined PICK_ADM (set "PICK_ADM=") else set "PICK_ADM=1"
goto choose_menu

:choose_zombot
if defined PICK_ZB (set "PICK_ZB=") else set "PICK_ZB=1"
goto choose_menu

:choose_install
if not defined PICK_SIL if not defined PICK_ADM if not defined PICK_ZB set "PICK_NONE=1"
if defined PICK_NONE goto choose_menu
set "WITH_SIL=%PICK_SIL%"
set "WITH_ADMIN=%PICK_ADM%"
set "WITH_ZOMBOT=%PICK_ZB%"

:install
rem the steps are numbered on what is installed: 1 check, 2 for Silenziatori, 1 for Admin-Scorte, 1 for ZomBOT
if defined SIL_DISABLED set "WITH_SIL="
call :status
set "STEP=0"
set "STEPS=1"
if defined WITH_SIL set /a STEPS+=2
if defined WITH_ADMIN set /a STEPS+=1
if defined WITH_ZOMBOT set /a STEPS+=1
set "WHAT="
set "WHATLAST="
if defined WITH_SIL call :what_add Silenziatori
if defined WITH_ADMIN call :what_add Admin-Scorte
if defined WITH_ZOMBOT call :what_add ZomBOT
call :what_end
cls
call :banner
echo   %B%Installo %WHAT%%N%
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Controllo che Project Zomboid sia chiuso
echo         %D%i file di una mod non si possono cambiare mentre il gioco li sta usando%N%
call :wait_game_closed
echo         %OK% il gioco è chiuso
if defined WITH_SIL call :install_sil || goto failed_mods
if not defined WITH_ADMIN if not defined WITH_ZOMBOT goto install_done
if not defined GAME goto install_no_game
if defined WITH_ADMIN call :install_admin || goto failed_game
if defined WITH_ZOMBOT call :install_zombot || goto failed_game
goto install_done

:install_no_game
set "WHAT="
set "WHATLAST="
if defined WITH_ADMIN call :what_add Admin-Scorte
if defined WITH_ZOMBOT call :what_add ZomBOT
call :what_end
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Installo %B%%WHAT%%N% nella cartella del gioco
echo         %KO% non trovo Project Zomboid: non ho installato %WHAT%
echo         %D%chiudi questa finestra e trascina la cartella ProjectZomboid su mod-moon-server.bat%N%
echo.
if defined WITH_SIL (echo   %Y%Silenziatori è pronta, %WHAT% no.%N%) else echo   %Y%Non ho installato niente.%N%
goto back_to_menu

:install_done
echo.
echo   %G%╔════════════════════════════════════════════════════════╗%N%
echo   %G%║%N%  %B%Tutto pronto.%N%                                         %G%║%N%
echo   %G%╚════════════════════════════════════════════════════════╝%N%
echo.
echo   Avvia Project Zomboid ed entra sul server Moon come sempre:
echo   non devi attivare niente nel menu Mod.
if defined WITH_ZOMBOT echo.
if defined WITH_ZOMBOT echo   Per chiedere a ZomBOT scrivi in chat una riga che comincia con «zombot»,
if defined WITH_ZOMBOT echo   per esempio %C%zombot dove trovo le asce?%N%  La risposta la vedi solo tu.
if defined WITH_ZOMBOT echo   Per colorare una cassa: tasto destro sulla cassa, %C%«ZomBOT»%N%, %C%«Colore di questa cassa»%N%.
if defined WITH_ADMIN echo.
if defined WITH_ADMIN echo   Da admin: tasto destro, %C%«ZomBOT»%N%: si apre la finestra delle basi e delle scorte.
echo.
echo   Quando esce una nuova versione, scaricala e rilancia questo file.
goto back_to_menu

rem ==============================================================================================================
:uninstall_menu
call :status
cls
call :banner
echo   %B%Disinstalla%N%
echo.
echo     %C%[1]%N%  Togli Silenziatori      %SILSTATE%
echo     %C%[2]%N%  Togli Admin-Scorte      %ADMSTATE%
echo     %C%[3]%N%  Togli ZomBOT            %ZBSTATE%
echo     %C%[4]%N%  Togli tutto             %D%Silenziatori + Admin-Scorte + ZomBOT%N%
echo     %C%[0]%N%  Torna indietro
echo.
set "REM_SIL="
set "REM_ADM="
set "REM_ZB="
choice /c 12340 /n /m "  Premi il numero: "
if errorlevel 5 goto menu
if errorlevel 4 goto uninstall_all
if errorlevel 3 goto uninstall_zombot
if errorlevel 2 goto uninstall_admin
set "REM_SIL=1"
set "WHAT=Silenziatori"
goto uninstall

:uninstall_admin
set "REM_ADM=1"
set "WHAT=Admin-Scorte"
goto uninstall

:uninstall_zombot
set "REM_ZB=1"
set "WHAT=ZomBOT"
goto uninstall

:uninstall_all
set "REM_SIL=1"
set "REM_ADM=1"
set "REM_ZB=1"
set "WHAT=tutto"

:uninstall
rem 1 check, then 1 step for every mod removed; Admin-Scorte before ZomBOT, so the shared file goes with the last
set "STEP=0"
set "STEPS=1"
if defined REM_SIL set /a STEPS+=1
if defined REM_ADM set /a STEPS+=1
if defined REM_ZB set /a STEPS+=1
cls
call :banner
echo   %B%Tolgo %WHAT%%N%
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Controllo che Project Zomboid sia chiuso
call :wait_game_closed
echo         %OK% il gioco è chiuso
if defined REM_SIL call :uninstall_sil || goto failed_mods
if defined REM_ADM call :uninstall_admin_step || goto failed_game
if defined REM_ZB call :uninstall_zombot_step || goto failed_game

:uninstall_done
echo.
echo   %G%╔════════════════════════════════════════════════════════╗%N%
echo   %G%║%N%  %B%Fatto.%N%                                                %G%║%N%
echo   %G%╚════════════════════════════════════════════════════════╝%N%
echo.
echo   Per rimettere le mod rilancia questo file e premi 1, 2 o 3.
goto back_to_menu

rem ==============================================================================================================
:not_extracted
echo.
echo   %R%Accanto a mod-moon-server.bat mancano le cartelle "mods", "admin-scorte" e "zombot".%N%
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
echo   %KO% %R%Non riesco a scrivere nella cartella del gioco: "%LUA%".%N%
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
echo   %C%║%N%  %B%MOON%N%  ·  le mod per giocare sul server %B%Moon%N%           %C%║%N%
echo   %C%╚════════════════════════════════════════════════════════╝%N%
echo   %D%%BANNERLINE%%N%
echo.
exit /b 0

:status
rem what is on this computer now, as the menu shows it: «aggiornata» when the files are the ones of this pack
call :installed_version
if defined SIL_DISABLED goto status_sil_off
if not defined SILINST (set "SILSTATE=%D%non installata%N%") else if "%SILINST%"=="%SILVER%" (set "SILSTATE=%G%aggiornata%N%") else set "SILSTATE=%Y%vecchia%N% %D%· hai la %SILINST%%N%"
goto status_game
:status_sil_off
if defined SILINST (set "SILSTATE=%Y%installata%N% %D%· hai la %SILINST%: non serve, puoi toglierla da Disinstalla%N%") else set "SILSTATE=%D%non installata%N%"
:status_game
set "ADMINST="
set "ZBINST="
set "ADMHAVE="
set "ZBHAVE="
if not defined GAME (
    set "GAMESTATE=%R%non trovato%N% %D%trascina la cartella ProjectZomboid su mod-moon-server.bat%N%"
    set "ADMSTATE=%D%serve la cartella del gioco%N%"
    set "ZBSTATE=%D%serve la cartella del gioco%N%"
    exit /b 0
)
set "GAMESTATE=%D%%GAME%%N%"
rem Admin-Scorte is there when one of its own files is: ZomBotMenu.lua alone may be ZomBOT's
set "ADMSTATE=%D%non installata · per gli admin%N%"
if exist "%LUA%\shared\ZomBotData.lua" set "ADMHAVE=1"
if exist "%LUA%\client\ZomBotStockUI.lua" set "ADMHAVE=1"
if not defined ADMHAVE goto status_zombot
call :read_version ADMINST "%ADMMARK%"
set "ADMSTATE=%Y%vecchia%N%"
if defined ADMINST if not "%ADMINST%"=="%ADMVER%" set "ADMSTATE=%Y%vecchia%N% %D%· hai la %ADMINST%%N%"
fc /b "%ADMSRC%\shared\ZomBotData.lua" "%LUA%\shared\ZomBotData.lua" >nul 2>nul || goto status_zombot
fc /b "%ADMSRC%\client\ZomBotStockUI.lua" "%LUA%\client\ZomBotStockUI.lua" >nul 2>nul || goto status_zombot
fc /b "%ADMSRC%\client\ZomBotMenu.lua" "%LUA%\client\ZomBotMenu.lua" >nul 2>nul || goto status_zombot
set "ADMSTATE=%G%aggiornata%N%"
:status_zombot
set "ZBSTATE=%D%non installata · per tutti%N%"
if exist "%LUA%\client\ZomBotGioco.lua" set "ZBHAVE=1"
if not defined ZBHAVE exit /b 0
call :read_version ZBINST "%ZBMARK%"
set "ZBSTATE=%Y%vecchia%N%"
if defined ZBINST if not "%ZBINST%"=="%ZBVER%" set "ZBSTATE=%Y%vecchia%N% %D%· hai la %ZBINST%%N%"
fc /b "%ZBSRC%\client\ZomBotGioco.lua" "%LUA%\client\ZomBotGioco.lua" >nul 2>nul || exit /b 0
fc /b "%ZBSRC%\client\ZomBotMenu.lua" "%LUA%\client\ZomBotMenu.lua" >nul 2>nul || exit /b 0
set "ZBSTATE=%G%aggiornata%N%"
exit /b 0

:installed_version
rem the version of Silenziatori in the mods folder, if any
set "SILINST="
if not exist "%SILDEST%\42\mod.info" exit /b 0
for /f "tokens=1,* delims==" %%a in ('findstr /b /c:"modversion=" "%SILDEST%\42\mod.info"') do set "SILINST=%%b"
if not defined SILINST set "SILINST=?"
exit /b 0

:read_version
rem %1 = a variable, %2 = a VERSION or .version file: its first line, or nothing when the file is not there
set "%~1="
if not exist "%~2" exit /b 0
for /f "usebackq delims=" %%v in ("%~2") do if not defined %~1 set "%~1=%%v"
exit /b 0

:what_add
rem joins the names as "A, B e C": a name goes in when the next one arrives, the last one in :what_end
if defined WHATLAST if defined WHAT set "WHAT=%WHAT%, %WHATLAST%"
if defined WHATLAST if not defined WHAT set "WHAT=%WHATLAST%"
set "WHATLAST=%~1"
exit /b 0

:what_end
if defined WHAT (set "WHAT=%WHAT% e %WHATLAST%") else set "WHAT=%WHATLAST%"
exit /b 0

:install_sil
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Preparo la cartella delle mod
echo         %D%» %ZOMBOID%\mods%N%
if not exist "%ZOMBOID%\mods\" mkdir "%ZOMBOID%\mods" 2>nul
if not exist "%ZOMBOID%\mods\" exit /b 1
echo         %OK% pronta
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Installo %B%Silenziatori%N% %D%%SILVER%%N%
echo         %D%i silenziatori per le armi, in italiano e senza i bug dell'originale%N%
if defined SILINST echo         %D%» sostituisco la versione %SILINST% che hai già%N%
echo         %D%» copio %NFILES% file in %SILDEST%%N%
robocopy "%SILSRC%" "%SILDEST%" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 exit /b 1
echo         %OK% Silenziatori installata
exit /b 0

:install_admin
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Installo %B%Admin-Scorte%N% %D%%ADMVER%%N%
echo         %D%le finestre di ZomBOT per gestire le basi e le loro scorte, per gli admin del server%N%
echo         %D%chi non è admin vede solo il riquadro delle scorte sotto gli oggetti%N%
if defined ADMHAVE if defined ADMINST echo         %D%» sostituisco la versione %ADMINST% che hai già%N%
if defined ADMHAVE if not defined ADMINST echo         %D%» sostituisco la versione che hai già%N%
echo         %D%» ZomBotData.lua     in %LUA%\shared%N%
copy /y "%ADMSRC%\shared\ZomBotData.lua" "%LUA%\shared\ZomBotData.lua" >nul 2>nul || exit /b 1
echo         %D%» ZomBotStockUI.lua  in %LUA%\client%N%
copy /y "%ADMSRC%\client\ZomBotStockUI.lua" "%LUA%\client\ZomBotStockUI.lua" >nul 2>nul || exit /b 1
echo         %D%» ZomBotMenu.lua     in %LUA%\client  · lo stesso file di ZomBOT%N%
copy /y "%ADMSRC%\client\ZomBotMenu.lua" "%LUA%\client\ZomBotMenu.lua" >nul 2>nul || exit /b 1
(echo %ADMVER%)>"%ADMMARK%" 2>nul || exit /b 1
echo         %OK% Admin-Scorte %ADMVER% installata
exit /b 0

:install_zombot
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Installo %B%ZomBOT%N% %D%%ZBVER%%N%
echo         %D%le domande a ZomBOT dalla chat del gioco, il contenitore che lampeggia, le casse colorate%N%
echo         %D%funziona per tutti, non solo per gli admin%N%
if defined ZBHAVE if defined ZBINST echo         %D%» sostituisco la versione %ZBINST% che hai già%N%
if defined ZBHAVE if not defined ZBINST echo         %D%» sostituisco la versione che hai già%N%
echo         %D%» ZomBotGioco.lua    in %LUA%\client%N%
copy /y "%ZBSRC%\client\ZomBotGioco.lua" "%LUA%\client\ZomBotGioco.lua" >nul 2>nul || exit /b 1
echo         %D%» ZomBotMenu.lua     in %LUA%\client  · lo stesso file di Admin-Scorte%N%
copy /y "%ZBSRC%\client\ZomBotMenu.lua" "%LUA%\client\ZomBotMenu.lua" >nul 2>nul || exit /b 1
(echo %ZBVER%)>"%ZBMARK%" 2>nul || exit /b 1
echo         %OK% ZomBOT %ZBVER% installata
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

:uninstall_admin_step
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Tolgo %B%Admin-Scorte%N% dalla cartella del gioco
if not defined GAME goto remove_no_game
echo         %D%» ZomBotData.lua     da %LUA%\shared%N%
echo         %D%» ZomBotStockUI.lua  da %LUA%\client%N%
if exist "%LUA%\shared\ZomBotData.lua" del /q "%LUA%\shared\ZomBotData.lua" 2>nul
if exist "%LUA%\client\ZomBotStockUI.lua" del /q "%LUA%\client\ZomBotStockUI.lua" 2>nul
if exist "%ADMMARK%" del /q "%ADMMARK%" 2>nul
if exist "%LUA%\shared\ZomBotData.lua" exit /b 1
if exist "%LUA%\client\ZomBotStockUI.lua" exit /b 1
if exist "%ADMMARK%" exit /b 1
rem the shared file stays while ZomBOT, found by its own file, still uses it
if exist "%LUA%\client\ZomBotGioco.lua" goto uninstall_admin_keep_menu
call :remove_menu || exit /b 1
echo         %OK% Admin-Scorte tolta
exit /b 0
:uninstall_admin_keep_menu
echo         %D%» ZomBotMenu.lua resta: lo usa anche ZomBOT%N%
echo         %OK% Admin-Scorte tolta
exit /b 0

:uninstall_zombot_step
echo.
set /a STEP+=1
echo   %C%[%STEP%/%STEPS%]%N% Tolgo %B%ZomBOT%N% dalla cartella del gioco
if not defined GAME goto remove_no_game
echo         %D%» ZomBotGioco.lua    da %LUA%\client%N%
if exist "%LUA%\client\ZomBotGioco.lua" del /q "%LUA%\client\ZomBotGioco.lua" 2>nul
if exist "%ZBMARK%" del /q "%ZBMARK%" 2>nul
if exist "%LUA%\client\ZomBotGioco.lua" exit /b 1
if exist "%ZBMARK%" exit /b 1
rem the shared file stays while Admin-Scorte, found by its own file, still uses it
if exist "%LUA%\client\ZomBotStockUI.lua" goto uninstall_zombot_keep_menu
call :remove_menu || exit /b 1
echo         %OK% ZomBOT tolta
exit /b 0
:uninstall_zombot_keep_menu
echo         %D%» ZomBotMenu.lua resta: lo usa anche Admin-Scorte%N%
echo         %OK% ZomBOT tolta
exit /b 0

:remove_menu
echo         %D%» ZomBotMenu.lua     da %LUA%\client%N%
if exist "%LUA%\client\ZomBotMenu.lua" del /q "%LUA%\client\ZomBotMenu.lua" 2>nul
if exist "%LUA%\client\ZomBotMenu.lua" exit /b 1
exit /b 0

:remove_no_game
echo         %D%non trovo Project Zomboid: non c'è niente da togliere%N%
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
