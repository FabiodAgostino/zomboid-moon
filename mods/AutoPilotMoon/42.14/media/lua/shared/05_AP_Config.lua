-- AutoPilot (Moon): automations for the Moon server.

AutoPilotMoon = AutoPilotMoon or {};

AutoPilotMoon.Config = {
    -- the player's preferences in Esc > Options > Mods (PZAPI.ModOptions)
    modOptionsId = "AutoPilotMoon",

    -- SandboxVars page of the server options (sandbox-options.txt)
    sandboxPage = "AutoPilotMoon",

    -- integer server options: same defaults and ranges as sandbox-options.txt, used when the value is missing or
    -- out of range (a missing page means: defaults here, every automation off)
    sandboxIntegers = {
        MaxSquaresPerJob = { default = 400, min = 25, max = 2000 },
        UnloaderItemsPerStep = { default = 20, min = 1, max = 100 },
        UnloaderItemsPerJob = { default = 200, min = 1, max = 2000 },
        DismantlerObjectsPerJob = { default = 50, min = 1, max = 500 },
        CorpsesPerJob = { default = 50, min = 1, max = 500 },
        -- carrying to a destination (AutoPilotMoon.Carry): items per trip and per job (the Gatherer's limits, spec 2.5)
        GathererItemsPerTrip = { default = 20, min = 1, max = 100 },
        GathererItemsPerJob = { default = 200, min = 1, max = 2000 },
        -- phase B (11/11/2026): logs per job of the Sawyer and of the Woodcutter (firewood)
        SawyerLogsPerJob = { default = 50, min = 1, max = 500 },
        FirewoodLogsPerJob = { default = 50, min = 1, max = 500 },
        -- the macros (experimental, step M1, decision DM1): actions and loops of one run, actions started per minute
        MacroActionsPerRun = { default = 200, min = 1, max = 2000 },
        MacroLoopsPerRun = { default = 100, min = 1, max = 1000 },
        MacroActionsPerMinute = { default = 20, min = 1, max = 60 },
    },

    icons = {
        menu = "media/ui/ap_icon.png",
    },
};

-- server options, read at the moment of use (never cached: an admin can change them while the game runs)

AutoPilotMoon.Sandbox = AutoPilotMoon.Sandbox or {};

function AutoPilotMoon.Sandbox:getPage()
    if type(SandboxVars) ~= "table"
    then
        return nil;
    end

    local page = SandboxVars[AutoPilotMoon.Config.sandboxPage];

    if type(page) ~= "table"
    then
        return nil;
    end

    return page;
end

-- true only when the option exists and is exactly true (missing page or option = off)
function AutoPilotMoon.Sandbox:getBoolean(key)
    local page = AutoPilotMoon.Sandbox:getPage();

    return page ~= nil and page[key] == true;
end

-- an integer option of AutoPilotMoon.Config.sandboxIntegers, clamped to its range (default when missing or invalid)
function AutoPilotMoon.Sandbox:getInteger(key)
    local spec = AutoPilotMoon.Config.sandboxIntegers[key];

    if not spec
    then
        return nil;
    end

    local page = AutoPilotMoon.Sandbox:getPage();
    local value = page and tonumber(page[key]);

    if value == nil or value ~= value
    then
        return spec.default;
    end

    value = math.floor(value);

    if value < spec.min
    then
        return spec.min;
    elseif value > spec.max
    then
        return spec.max;
    end

    return value;
end
