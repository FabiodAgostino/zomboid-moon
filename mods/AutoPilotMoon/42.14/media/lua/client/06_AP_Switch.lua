-- AutoPilot (Moon): automations for the Moon server.

-- The player's master switch (decision of 12/11/2026, UX-AUTOPILOT.md 9): Esc > Options > Mods > AutoPilot (Moon),
-- "Attiva AutoPilot" (option "enabled"), OFF by default. The mod is in the Moon server's mod list, so every player has
-- its files: while the switch is off the mod must be inert for that player, the game exactly as without it.
--
-- While off:
--   - no game event of the mod is bound except the two that run once at the start (OnGameBoot builds the options page,
--     OnGameStart reads the options and asks this switch): no OnPlayerUpdate, no right click, no key, no death or
--     respawn handler (Switch:bind keeps them here and adds them only while on);
--   - no vanilla function is wrapped: the hooks on the game's recipe action (ISHandcraftAction.perform / stop, for the
--     macros and the recorder) are installed when it turns on and put back when it turns off (when another mod wrapped
--     them after us, ours stays in its chain and only calls the game's: no macro, no recording, nothing else);
--   - no window of the mod is in the game's UI list (the game updates even the hidden ones at every frame).
-- Turning it off while something runs: the job, chain or macro stops as with "Ferma" with the reason "AutoPilot spento
-- nelle Opzioni", a recording is thrown away (with a message), the area or destination choice is cancelled, the panel,
-- the macro editor, the recipe picker and the recorder's preview close. The messages already queued are still shown
-- (a handler of OnPlayerUpdate that removes itself when the queue is empty), then nothing.
-- The server's switches (Enable*, sandbox) are untouched: an automation needs both.
--
-- The switch reads the option at the game's start (Event.initialize -> Switch:start) and whenever it may change:
-- Options:set("enabled", ...), the Options screen's Apply (the page's apply, client/05_AP_Config.lua). Nothing watches
-- it per frame.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Switch = AutoPilotMoon.Switch or {
    on = false,          -- AutoPilot acts for this player now
    started = false,     -- the game has started (before it, in the main menu, nothing is bound)
    bound = false,       -- the events of Switch:bind are added to the game's events
    bindings = {},       -- { event = name, fn = handler }, in the order they were declared
    draining = false,    -- the queued messages are still shown after turning off
};

local Switch = AutoPilotMoon.Switch;

-- the option of the page (false when the page is not built: the default)
function AutoPilotMoon.Switch:isWanted()
    return AutoPilotMoon.Options:get("enabled") == true;
end

function AutoPilotMoon.Switch:isOn()
    return Switch.on == true;
end

-- a game event that acts only while AutoPilot is on (instead of Events.<name>.Add at load)
function AutoPilotMoon.Switch:bind(eventName, fn)
    for i, binding in ipairs(Switch.bindings)
    do
        if binding.event == eventName and binding.fn == fn
        then
            return;
        end
    end

    table.insert(Switch.bindings, { event = eventName, fn = fn });

    if Switch.bound
    then
        Events[eventName].Add(fn);
    end
end

local function bindAll()
    if Switch.bound
    then
        return;
    end

    Switch.bound = true;

    for i, binding in ipairs(Switch.bindings)
    do
        Events[binding.event].Add(binding.fn);
    end
end

local function unbindAll()
    if not Switch.bound
    then
        return;
    end

    Switch.bound = false;

    for i, binding in ipairs(Switch.bindings)
    do
        Events[binding.event].Remove(binding.fn);
    end
end

-- after turning off: the messages already queued (the reason of a stop) are still shown, then this handler goes
function AutoPilotMoon.Switch.drainMessages(player)
    if #AutoPilotMoon.messageQueue > 0
    then
        AutoPilotMoon:showNextMessage();
    end

    if #AutoPilotMoon.messageQueue == 0
    then
        Switch:stopDraining();
    end
end

function AutoPilotMoon.Switch:stopDraining()
    if Switch.draining
    then
        Switch.draining = false;
        Events.OnPlayerUpdate.Remove(Switch.drainMessages);
    end
end

local function startDraining()
    if not Switch.draining and #AutoPilotMoon.messageQueue > 0
    then
        Switch.draining = true;
        Events.OnPlayerUpdate.Add(Switch.drainMessages);
    end
end

-- calls fn without letting an error of one module leave the switch half done
local function safely(fn, ...)
    local ok, err = pcall(fn, ...);

    if not ok
    then
        print("AutoPilot (Moon): switch: " .. tostring(err));
    end
end

local function turnOn()
    Switch:stopDraining();

    -- the classes derived from the game's (cursors, panel, editor, recorder's preview): before the first use
    safely(function()
        AutoPilotMoon.Cursors:createClasses();

        if AutoPilotMoon.Panel
        then
            AutoPilotMoon.Panel:createClasses();
        end

        local macro = AutoPilotMoon.Macro;

        if macro and macro.Editor
        then
            macro.Editor:createClasses();
            macro.Recorder:createClasses();
        end
    end);

    -- the hooks on the game's recipe action (macros and recorder)
    safely(function()
        local macro = AutoPilotMoon.Macro;

        if macro and macro.Hooks and macro.Hooks.install
        then
            macro.Hooks:install();
        end
    end);

    bindAll();
end

local function turnOff()
    local macro = AutoPilotMoon.Macro;

    -- what runs stops as with "Ferma", with the reason (a job, a chain also between two phases, a macro)
    safely(function()
        if AutoPilotMoon.Automation:isBusy()
        then
            AutoPilotMoon.Automation:stopAll("switchedoff");
        end
    end);

    -- a recording is thrown away (the game's actions never touched), the preview of a finished one closes
    safely(function()
        if macro and macro.Recorder and macro.Recorder.shutdown
        then
            macro.Recorder:shutdown();
        end
    end);

    -- an area or destination choice open, the preview of a menu entry
    safely(function()
        AutoPilotMoon.AreaTool:cancelAll();
        AutoPilotMoon.AreaPreview:hide();
    end);

    -- the windows: the editor (it saves the text, closes its picker), the panel; out of the game's UI list
    safely(function()
        if macro and macro.Editor and macro.Editor.shutdown
        then
            macro.Editor:shutdown();
        end
    end);

    safely(function()
        if AutoPilotMoon.Panel and AutoPilotMoon.Panel.shutdown
        then
            AutoPilotMoon.Panel:shutdown();
        end
    end);

    -- the game's recipe action as it was
    safely(function()
        if macro and macro.Hooks and macro.Hooks.uninstall
        then
            macro.Hooks:uninstall();
        end
    end);

    unbindAll();
    startDraining();
end

-- reads the option and turns AutoPilot on or off when it changed (only after the game's start)
function AutoPilotMoon.Switch:sync()
    if not Switch.started
    then
        return Switch.on;
    end

    local wanted = Switch:isWanted();

    if wanted == Switch.on
    then
        return Switch.on;
    end

    Switch.on = wanted;

    if wanted
    then
        turnOn();
    else
        turnOff();
    end

    return Switch.on;
end

-- the game has started (Event.initialize, after the options are read)
function AutoPilotMoon.Switch:start()
    Switch.started = true;

    return Switch:sync();
end
