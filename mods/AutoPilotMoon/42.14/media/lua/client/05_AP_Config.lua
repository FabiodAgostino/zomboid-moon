-- AutoPilot (Moon): automations for the Moon server.

-- The player's own preferences. Since 11/11/2026 they live in the game's options, Esc > Options > Mods > AutoPilot
-- (Moon) (PZAPI.ModOptions of 42.22, file Zomboid/Lua/ModOptions.ini, spec UX-AUTOPILOT.md 2.5): the page is built
-- by client/UI/ModOptions.lua once every automation and chain has registered.
-- What the server allows is NOT here: it is read live from the sandbox (AutoPilotMoon.Sandbox, shared/05_AP_Config.lua)
-- and never written into the player's options.
--
-- AutoPilotMoon.Options:get(key) / :set(key, value) are the only way to read and write a preference:
--   enabled                the master switch "Attiva AutoPilot", OFF by default (12/11/2026, client/06_AP_Switch.lua):
--                          while off the mod is inert for this player; first on the page, the others greyed
--   haloMode               "all" / "important" / "none" (messages over the head)
--   openPanelOnStart, showJobArea, uiSounds, autoRest, stopWhenUnwell, menuIcon, unloadBeforeScrapping   booleans
--   restLevel              1-4: the endurance moodle level at which auto-rest sits down (12/11/2026: the player's
--                          choice, no longer the server's RestAtFatigueLevel; default 2)
--   panelKey               key code, 0 = none (decision D2: no default key)
--   macroEditorKey         key code of the macro editor, 0 = none (MACRO-AUTOPILOT.md 7.2)
--   macroCodeFont          the macro editor writes with the game's fixed-width font (MACRO-AUTOPILOT.md 4.3)
--   macroColors            the macro editor colours its text (MACRO-AUTOPILOT.md 4.11; needs macroCodeFont)
--   macroSuggest           the macro editor suggests while typing (MACRO-AUTOPILOT.md 4.12)
--   enable<Name>           the job <name> is shown in the menu ("Jobs in the menu", one tick per job and chain)
--   any other key given to Options:register(key, default): a boolean of this game session only, not saved

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Options = AutoPilotMoon.Options or {};

local O = AutoPilotMoon.Options;

-- the preferences of the page, in the page's order (spec 2.5 plus stopWhenUnwell, decision D1)
O.specs = {
    -- the master switch (decision of 12/11/2026): off by default, also for a ModOptions.ini saved before it existed
    enabled = { kind = "tick", nameKey = "IGUI_AutoPilot_MO_Enabled", default = false,
        tooltipKey = "IGUI_AutoPilot_MO_Enabled_Tooltip" },
    haloMode = { kind = "combo", nameKey = "IGUI_AutoPilot_MO_Halo", default = 2,
        values = { "all", "important", "none" },
        itemKeys = { "IGUI_AutoPilot_MO_Halo_All", "IGUI_AutoPilot_MO_Halo_Important", "IGUI_AutoPilot_MO_Halo_None" } },
    openPanelOnStart = { kind = "tick", nameKey = "IGUI_AutoPilot_MO_OpenPanel", default = true },
    showJobArea = { kind = "tick", nameKey = "IGUI_AutoPilot_MO_ShowArea", default = true },
    uiSounds = { kind = "tick", nameKey = "IGUI_AutoPilot_MO_Sounds", default = true },
    autoRest = { kind = "tick", nameKey = "IGUI_AutoPilot_MO_AutoRest", default = true,
        tooltipKey = "IGUI_AutoPilot_MO_AutoRest_Tooltip" },
    -- the endurance moodle level of auto-rest (decision of 12/11/2026: each player chooses it; the game's moodle names)
    restLevel = { kind = "combo", nameKey = "IGUI_AutoPilot_MO_RestLevel", default = 2,
        values = { 1, 2, 3, 4 },
        itemKeys = { "IGUI_AutoPilot_MO_RestLevel_1", "IGUI_AutoPilot_MO_RestLevel_2", "IGUI_AutoPilot_MO_RestLevel_3",
            "IGUI_AutoPilot_MO_RestLevel_4" },
        tooltipKey = "IGUI_AutoPilot_MO_RestLevel_Tooltip" },
    stopWhenUnwell = { kind = "tick", nameKey = "IGUI_AutoPilot_MO_StopUnwell", default = true,
        tooltipKey = "IGUI_AutoPilot_MO_StopUnwell_Tooltip" },
    panelKey = { kind = "key", nameKey = "IGUI_AutoPilot_MO_PanelKey", default = 0 },
    menuIcon = { kind = "tick", nameKey = "IGUI_AutoPilot_MO_MenuIcon", default = true },
    menuJobs = { kind = "jobs", nameKey = "IGUI_AutoPilot_MO_MenuJobs" },
    unloadBeforeScrapping = { kind = "tick", nameKey = "IGUI_AutoPilot_MO_UnloadBeforeScrap", default = true },
    -- the macros (experimental, MACRO-AUTOPILOT.md 7.2)
    macroEditorKey = { kind = "key", nameKey = "IGUI_AutoPilot_MO_MacroEditorKey", default = 0 },
    macroCodeFont = { kind = "tick", nameKey = "IGUI_AutoPilot_MO_MacroCodeFont", default = true },
    macroColors = { kind = "tick", nameKey = "IGUI_AutoPilot_MO_MacroColors", default = true,
        tooltipKey = "IGUI_AutoPilot_MO_MacroColors_Tooltip" },
    macroSuggest = { kind = "tick", nameKey = "IGUI_AutoPilot_MO_MacroSuggest", default = true,
        tooltipKey = "IGUI_AutoPilot_MO_MacroSuggest_Tooltip" },
};

O.pageOrder = { "enabled", "haloMode", "openPanelOnStart", "showJobArea", "uiSounds", "autoRest", "restLevel", "stopWhenUnwell",
    "panelKey", "macroEditorKey", "menuIcon", "menuJobs", "unloadBeforeScrapping", "macroCodeFont", "macroColors",
    "macroSuggest" };

-- The ticks of "Jobs in the menu", in this order. PZAPI.ModOptions saves a multiple tickbox by position: once released,
-- this list is only appended to (never reordered, never shortened). A job not in the list comes after, in the order it
-- registered; a job in the list that is not registered is left out of the page.
O.menuJobsOrder = { "lumberjack", "sawyer", "firewood", "gatherer", "woodChain", "chopAndGather", "gardener",
    "clearAndGather", "soilBagger", "farmer", "dismantler", "unloader", "corpsePiler", "macro" };

O.jobs = O.jobs or {};          -- registered jobs (automations and chains): list of { name, key, titleKey }
O.jobByKey = O.jobByKey or {};  -- "enable<Name>" -> job
O.session = O.session or {};    -- key -> value of the session-only booleans
O.sessionDefaults = O.sessionDefaults or {};
O.page = nil;                   -- the PZAPI.ModOptions page, once built
O.pageJobs = nil;               -- the jobs of the page's multiple tickbox, in its order

-- registration

-- a job (automation or chain) gets a tick in "Jobs in the menu" (Automation:register, Chain:define)
function AutoPilotMoon.Options:addMenuJob(name, titleKey)
    local key = "enable" .. AutoPilotMoon:ucFirst(name);

    if O.jobByKey[key]
    then
        return key;
    end

    local job = { name = name, key = key, titleKey = titleKey or ("IGUI_AutoPilot_O_Context_" .. AutoPilotMoon:ucFirst(name)) };

    table.insert(O.jobs, job);
    O.jobByKey[key] = job;

    -- registered after the page was built: its tick goes at the end (the saved order of the others does not change)
    if O.page
    then
        local option = O.page:getOption("menuJobs");

        if option == nil
        then
            option = O.page:addMultipleTickBox("menuJobs", O.specs.menuJobs.nameKey);
            O.pageJobs = {};
            O:watchOption(option);
        end

        option:addTickBox(job.titleKey, true);
        table.insert(O.pageJobs, job);
        O:greyOthers(O.shownOn);
    end

    return key;
end

-- a boolean of this session only (not on the page, not saved); the page's keys and the job keys are already known
function AutoPilotMoon.Options:register(key, defaultValue)
    if O.specs[key] or O.jobByKey[key] or O.sessionDefaults[key] ~= nil
    then
        return;
    end

    O.sessionDefaults[key] = defaultValue == true;
    O.session[key] = defaultValue == true;
end

-- the page (PZAPI.ModOptions)

local function modOptions()
    local api = rawget(_G, "PZAPI");

    return api and api.ModOptions or nil;
end

-- the jobs of the page in their saved order
function AutoPilotMoon.Options:getPageJobs()
    local ordered = {};
    local seen = {};

    for i, name in ipairs(O.menuJobsOrder)
    do
        for j, job in ipairs(O.jobs)
        do
            if job.name == name and not seen[name]
            then
                table.insert(ordered, job);
                seen[name] = true;
            end
        end
    end

    for i, job in ipairs(O.jobs)
    do
        if not seen[job.name]
        then
            table.insert(ordered, job);
            seen[job.name] = true;
        end
    end

    return ordered;
end

-- builds the page once (client/UI/ModOptions.lua, at load and again at OnGameBoot if PZAPI was not there yet)
function AutoPilotMoon.Options:buildPage()
    if O.page ~= nil
    then
        return O.page;
    end

    local api = modOptions();

    if api == nil
    then
        return nil;
    end

    local page = api:create(AutoPilotMoon.Config.modOptionsId, "IGUI_AutoPilot_MO_Title");

    for i, key in ipairs(O.pageOrder)
    do
        local spec = O.specs[key];

        if spec.kind == "tick"
        then
            page:addTickBox(key, spec.nameKey, spec.default, spec.tooltipKey);

            -- under the master switch, one line that says the others count only with it on (the game draws a greyed
            -- tick box or list almost as an active one)
            if key == "enabled" and page.addDescription
            then
                page:addDescription("IGUI_AutoPilot_MO_Enabled_Note");
            end
        elseif spec.kind == "combo"
        then
            local combo = page:addComboBox(key, spec.nameKey, spec.tooltipKey);

            for j, itemKey in ipairs(spec.itemKeys)
            do
                combo:addItem(itemKey, j == spec.default);
            end
        elseif spec.kind == "key"
        then
            page:addKeyBind(key, spec.nameKey, spec.default, spec.tooltipKey);
        elseif spec.kind == "jobs"
        then
            local jobs = O:getPageJobs();

            if #jobs > 0
            then
                local multiple = page:addMultipleTickBox(key, spec.nameKey, spec.tooltipKey);

                for j, job in ipairs(jobs)
                do
                    multiple:addTickBox(job.titleKey, true);
                end

                O.pageJobs = jobs;
            end
        end
    end

    O.page = page;
    O:watchPage();

    return page;
end

local function pageOption(key)
    return O.page and O.page:getOption(key) or nil;
end

-- The master switch on the page (decision of 12/11/2026). While it is off the other options are greyed (PZAPI's
-- isEnabled / setEnabled: the game draws them grey and does not change them; they keep their values and count again
-- when it is on). The page follows the switch three ways:
--   - the screen being built: each option's element is caught when the game sets it (a metatable on the option, the
--     element kept in autopilotElement), greyed or not as the switch is shown now;
--   - the screen showing the saved value (gameOption.toUI -> the tick box's setSelected) and the player ticking it
--     (option.onChange): the others follow at once, before Apply;
--   - Apply (MainOptions:apply -> the page's apply, after every value is stored): the switch itself (Switch:sync).
O.shownOn = false;

-- greys (or not) one option. PZAPI's setEnabled works for a tick box and a list; a key binding's element is the
-- game's keyTextElement once the screen is built (its button in .btn: PZAPI's setEnabled would call a missing method);
-- a multiple tick box disables its ticks by their shown text (ISTickBox), not by the key PZAPI passes: done here
local function setOptionEnabled(option, on)
    if option.type == "keybind"
    then
        option.isEnabled = on;

        local element = option.element;
        local button = element and (element.btn or element);

        if button and button.setEnable
        then
            button:setEnable(on);
        end
    elseif option.type == "multipletickbox"
    then
        local element = option.element;

        for i, value in ipairs(option.values or {})
        do
            value.isEnabled = on;

            if element and element.disableOption
            then
                element:disableOption(getText(value.name), not on);
            end
        end

        if element
        then
            element.enable = on;
        end
    elseif option.setEnabled
    then
        option:setEnabled(on);
    else
        option.isEnabled = on;
    end
end

-- the other options of the page, greyed while the switch shown is off
function AutoPilotMoon.Options:greyOthers(on)
    O.shownOn = on == true;

    if O.page == nil
    then
        return;
    end

    for i, option in ipairs(O.page.data or {})
    do
        if option.id ~= nil and option.id ~= "enabled"
        then
            setOptionEnabled(option, O.shownOn);
        end
    end
end

-- the game set the element of an option (the Options screen is being built)
local function onElement(option)
    local element = option.element;

    if option.id ~= "enabled"
    then
        setOptionEnabled(option, O.shownOn);

        return;
    end

    -- the switch's tick box: gameOption.toUI shows the saved value with setSelected; the others follow it
    if element and element.setSelected and not element.autopilotSwitch
    then
        local gameSetSelected = element.setSelected;

        element.autopilotSwitch = true;
        element.setSelected = function(self, index, selected)
            gameSetSelected(self, index, selected);
            O:greyOthers(selected == true);
        end
    end
end

local function watchElement(option)
    if getmetatable(option) ~= nil
    then
        return;
    end

    setmetatable(option, {
        __index = function(t, k)
            if k == "element"
            then
                return rawget(t, "autopilotElement");
            end

            return nil;
        end,
        __newindex = function(t, k, v)
            if k == "element"
            then
                rawset(t, "autopilotElement", v);

                if v ~= nil
                then
                    onElement(t);
                end

                return;
            end

            rawset(t, k, v);
        end,
    });
end

function AutoPilotMoon.Options:watchOption(option)
    watchElement(option);
end

-- once, when the page is built
function AutoPilotMoon.Options:watchPage()
    local page = O.page;
    local switch = page and page:getOption("enabled");

    if page == nil or switch == nil
    then
        return;
    end

    -- the player ticks or unticks it on the screen (before Apply)
    switch.onChange = function(self, selected)
        O:greyOthers(selected == true);
    end

    for i, option in ipairs(page.data or {})
    do
        if option.id ~= nil
        then
            watchElement(option);
        end
    end

    -- Apply / Accept of the Options screen: every value is stored, then each page's apply
    page.apply = function(self)
        O:greyOthers(O:get("enabled") == true);

        if AutoPilotMoon.Switch
        then
            AutoPilotMoon.Switch:sync();
        end
    end

    O:greyOthers(O:get("enabled") == true);
end

-- the position of a job in the page's multiple tickbox, or nil
local function pageJobIndex(name)
    for i, job in ipairs(O.pageJobs or {})
    do
        if job.name == name
        then
            return i;
        end
    end

    return nil;
end

-- access

function AutoPilotMoon.Options:get(key)
    local job = O.jobByKey[key];

    if job
    then
        local option = pageOption("menuJobs");
        local index = pageJobIndex(job.name);

        if option and index
        then
            return option:getValue(index) == true;
        end

        return true;
    end

    local spec = O.specs[key];

    if spec == nil
    then
        return O.session[key];
    end

    local option = pageOption(key);

    if spec.kind == "combo"
    then
        local index = option and tonumber(option:getValue()) or spec.default;

        return spec.values[index] or spec.values[spec.default];
    end

    if option == nil
    then
        return spec.default;
    end

    return option:getValue();
end

-- writes the game's options file once, and only when the value really changes; false for an unknown key or a value of
-- the wrong type
function AutoPilotMoon.Options:set(key, value, skipSave)
    local changed = false;

    local job = O.jobByKey[key];
    local spec = O.specs[key];

    if job
    then
        local option = pageOption("menuJobs");
        local index = pageJobIndex(job.name);

        if type(value) ~= "boolean" or option == nil or index == nil or option:getValue(index) == value
        then
            return false;
        end

        option:setValue(index, value);
        changed = true;
    elseif spec and spec.kind == "tick"
    then
        local option = pageOption(key);

        if type(value) ~= "boolean" or option == nil or option:getValue() == value
        then
            return false;
        end

        option:setValue(value);
        changed = true;
    elseif spec and spec.kind == "combo"
    then
        local option = pageOption(key);
        local index = nil;

        for i, name in ipairs(spec.values)
        do
            if name == value
            then
                index = i;
            end
        end

        if index == nil or option == nil or option:getValue() == index
        then
            return false;
        end

        option:setValue(index);
        changed = true;
    elseif spec and spec.kind == "key"
    then
        local option = pageOption(key);

        if type(value) ~= "number" or option == nil or option:getValue() == value
        then
            return false;
        end

        option:setValue(value);
        changed = true;
    elseif O.sessionDefaults[key] ~= nil
    then
        if type(value) ~= "boolean" or O.session[key] == value
        then
            return false;
        end

        O.session[key] = value;

        return true;
    end

    if changed and skipSave ~= true
    then
        O:save();
    end

    -- the master switch: the page and the mod follow it at once
    if changed and key == "enabled"
    then
        O:greyOthers(O:get("enabled") == true);

        if AutoPilotMoon.Switch
        then
            AutoPilotMoon.Switch:sync();
        end
    end

    return changed;
end

-- the game's options file (every mod's page is written together, as the Options screen does)
function AutoPilotMoon.Options:save()
    local api = modOptions();

    if api and O.page
    then
        api:save();
    end
end

-- the values saved in ModOptions.ini (the game reads the file when it builds its Options screen; in multiplayer the
-- server's mods load later, so the mod reads it again at OnGameStart: harmless, it reads the whole file)
function AutoPilotMoon.Options:load()
    local api = modOptions();

    if api and O.page
    then
        api:load();
        O:greyOthers(O:get("enabled") == true);
    end
end

