-- AutoPilot (Moon): automations for the Moon server.

-- The page Esc > Options > Mods > AutoPilot (Moon) (PZAPI.ModOptions, spec UX-AUTOPILOT.md 2.5). Built here because this
-- file loads after client/Automation/ (the game loads client/ sorted by path, case-insensitively): every automation and
-- chain registered at load time has its tick in "Jobs in the menu". The game builds its Options screen from
-- PZAPI.ModOptions.Data, so the page must exist before the main menu; OnGameBoot covers a PZAPI loaded after this file.

require "05_AP_Config";

function AutoPilotMoon.Options.onGameBoot()
    AutoPilotMoon.Options:buildPage();
end

AutoPilotMoon.Options:buildPage();

Events.OnGameBoot.Add(AutoPilotMoon.Options.onGameBoot);
