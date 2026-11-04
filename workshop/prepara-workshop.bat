@echo off
rem Prepares the Steam Workshop upload of ZomBOT (Moon): copies mods\ZomBOTMoon of this repo and the preview into
rem %USERPROFILE%\Zomboid\Workshop\ZomBOTMoon, the folder the game's Workshop screen uploads from (main menu,
rem "Workshop", "Create and update items"). The game writes workshop.txt there with the item's id at the first upload:
rem it is kept, so the next uploads update the same item.
setlocal
set "HERE=%~dp0"
set "SRC=%HERE%..\mods\ZomBOTMoon"
set "DEST=%USERPROFILE%\Zomboid\Workshop\ZomBOTMoon"
if not exist "%SRC%\42\mod.info" (
    echo Non trovo la mod in "%SRC%".
    exit /b 1
)
if not exist "%DEST%" mkdir "%DEST%"
copy /y "%HERE%ZomBOTMoon\preview.png" "%DEST%\preview.png" >nul || exit /b 1
robocopy "%SRC%" "%DEST%\Contents\mods\ZomBOTMoon" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 (
    echo Copia non riuscita.
    exit /b 1
)
echo Pronta in "%DEST%".
echo Ora nel gioco: menu principale, Workshop, scegli ZomBOTMoon e carica (visibilita: non in elenco).
endlocal
