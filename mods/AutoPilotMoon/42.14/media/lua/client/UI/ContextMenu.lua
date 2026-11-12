-- AutoPilot (Moon): automations for the Moon server.

AutoPilotMoon = AutoPilotMoon or {};

-- Helpers of the right click menu (spec UX-AUTOPILOT.md 2.2): the game's own ISContextMenu options, nothing drawn by
-- the mod. A header ("Legna", "Qui") is an option the game draws grey and never runs (isDisabled, no onSelect, no
-- tooltip); an entry that cannot be used now is notAvailable (the game draws it in its "bad" colour, the colour-blind
-- option included) with the reason in its tooltip; the menu's font is the game's (setFontFromOption, rule 9).

function AutoPilotMoon:addContextMenuHeader(context, text)
    local entry = context:addOption(text, nil, nil);

    entry.isDisabled = true;

    return entry;
end

function AutoPilotMoon:addDisabledContextMenuItem(context, text, tip)
    return AutoPilotMoon:addContextMenuItem(context,
        text, nil, nil, {
            disabled = true,
            tip = tip
        }
    );
end

function AutoPilotMoon:addContextMenuItem(context, text, handler, params, options)
    options = options or {};
    options.isSubMenu = false;

    return AutoPilotMoon:createContextMenuOption(context, text, handler, params, options);
end

function AutoPilotMoon:addContextMenuSubMenu(context, text, handler, params, options)
    options = options or {};
    options.isSubMenu = true;

    return AutoPilotMoon:createContextMenuOption(context, text, handler, params, options);
end

-- ISContextMenu:addOption(name, target, onSelect, param1, ...): the handler is called as handler(params[1], params[2], ...)
function AutoPilotMoon:createContextMenuOption(context, text, handler, params, options)
    params = params or {};

    local entry = context:addOption(
        text,
        params[1],
        handler,
        params[2],
        params[3],
        params[4],
        params[5],
        params[6]
    );

    if options.checked
    then
        entry.checkMark = true;
    end

    entry.notAvailable = options.disabled;

    if options.tip ~= nil and options.tip ~= ""
    then
        entry.toolTip = ISWorldObjectContextMenu.addToolTip();
        entry.toolTip.description = options.tip;
    end

    -- the entry "AutoPilot" in the game's own menu: the mod's icon when the player wants it
    if context.parent == nil and AutoPilotMoon.Options:get("menuIcon")
    then
        entry.iconTexture = getTexture(AutoPilotMoon.Config.icons.menu);
    end

    if options.isSubMenu
    then
        local menu = context:getNew(context);

        context:addSubMenu(entry, menu);

        -- the option too (its tooltip, its preview)
        return menu, entry;
    end

    return entry;
end
