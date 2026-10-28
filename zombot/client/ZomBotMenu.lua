-- ZomBotMenu: the one «ZomBOT» entry of the right click, shared by the Moon mods that talk to ZomBOT in game
-- (28/10/2026, the user: «il tasto destro mostra troppe voci zombot. Deve mostrarne solo una»). Client only.
--
-- The same file, byte for byte, ships with every such mod (Admin-Scorte, ZomBOT) and is installed at the same path,
-- media/lua/client/ZomBotMenu.lua: the game loads it once, whichever of the mods a player has, and uninstalling one
-- of them leaves it in place while another still uses it. Change it here and copy it to every mod.
--
-- A mod tells it what it offers by appending a definition to ZomBotMenu.defs, at load: the order in which the game
-- loads the files does not matter, because nothing is read before a right click.
--   ZomBotMenu = ZomBotMenu or {}
--   ZomBotMenu.defs = ZomBotMenu.defs or {}
--   table.insert(ZomBotMenu.defs, { kind = "main", id = "bases", order = 10, available = fn, open = fn })
-- Kinds (the same id again replaces the older one; a lower order comes first):
--   main   what a click on «ZomBOT» opens: the first one available. available(player, ctx) -> boolean,
--          open(ctx). Admin-Scorte's list of bases for an admin (order 10), ZomBOT's own window for anyone (20).
--   extra  a button the main windows show (ZomBotMenu.extras): what another mod adds there, such as the colour
--          of the crate right-clicked. available(player, ctx) -> boolean, label(ctx) -> text, onClick(ctx).
--   item   the right click on an item: fill(player, ctx, submenu) adds options to the one «ZomBOT» submenu and
--          returns true when it added any. With nothing added there is no «ZomBOT» entry at all.
--   shortcut  an entry of its own in the world right click, right after «ZomBOT», for something done often
--          (28/10/2026, the user: «ZomBOT: colora il contenitore» on a crate). available(player, ctx) -> boolean,
--          label(ctx) -> text, onClick(ctx).
-- ctx, made once for each right click: { playerNum, player, square, x, y, z, worldobjects (world menu),
--   container = { object, index, x, y, z } for the first object with a container among the ones clicked,
--   items and item (inventory menu: the entries and the first item) }.
if isServer() and not isClient() then return end

ZomBotMenu = ZomBotMenu or {}
ZomBotMenu.defs = ZomBotMenu.defs or {}
local M = ZomBotMenu

M.TITLE = "ZomBOT"

-- the definitions of a kind, the last of each id, by order
function M.list(kind)
    local byId, out = {}, {}
    for _, def in ipairs(M.defs) do
        if def.kind == kind and def.id then byId[def.id] = def end
    end
    for _, def in pairs(byId) do out[#out + 1] = def end
    table.sort(out, function(a, b)
        if (a.order or 50) ~= (b.order or 50) then return (a.order or 50) < (b.order or 50) end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

local function ask(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, result = pcall(fn, ...)
    if not ok then print("ZomBotMenu: " .. tostring(result)) end
    return ok and result
end

-- the first object with a container among the ones right-clicked (a crate, a shelf, a fridge)
function M.containerOf(worldobjects)
    for _, object in ipairs(worldobjects or {}) do
        local found = nil
        pcall(function()
            if object:getContainer() == nil then return end
            local square = object:getSquare()
            if square == nil then return end
            found = { object = object, index = object:getObjectIndex(), x = square:getX(), y = square:getY(),
                z = square:getZ() }
        end)
        if found then return found end
    end
    return nil
end

function M.context(playerNum, worldobjects, items)
    local player = getSpecificPlayer(playerNum)
    local ctx = { playerNum = playerNum, player = player, worldobjects = worldobjects, items = items }
    pcall(function()
        ctx.square = player:getCurrentSquare()
        ctx.x, ctx.y, ctx.z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    end)
    if worldobjects then ctx.container = M.containerOf(worldobjects) end
    if items then
        for _, entry in ipairs(items) do
            if instanceof(entry, "InventoryItem") then ctx.item = entry break end
            if type(entry) == "table" and entry.items and entry.items[1] then ctx.item = entry.items[1] break end
        end
    end
    return ctx
end

function M.mainFor(player, ctx)
    for _, def in ipairs(M.list("main")) do
        if ask(def.available, player, ctx) then return def end
    end
    return nil
end

-- the extra buttons a main window shows for this right click: { {def=, label=}, ... }
function M.extras(player, ctx)
    local out = {}
    for _, def in ipairs(M.list("extra")) do
        if ask(def.available, player, ctx) then
            out[#out + 1] = { def = def, label = ask(def.label, ctx) or tostring(def.id) }
        end
    end
    return out
end

function M.press(extra, ctx)
    ask(extra.def.onClick, ctx)
end

function M.open(ctx)
    local def = M.mainFor(ctx and ctx.player or getPlayer(), ctx or {})
    if def then ask(def.open, ctx or {}) end
end

-- a shortcut chosen: its own onClick, with the right click it came from
function M.shortcut(ctx, def)
    ask(def.onClick, ctx)
end

function M.onWorldMenu(playerNum, context, worldobjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end
    local ctx = M.context(playerNum, worldobjects, nil)
    if ctx.player == nil then return end
    if M.mainFor(ctx.player, ctx) ~= nil then context:addOption(M.TITLE, ctx, M.open) end
    for _, def in ipairs(M.list("shortcut")) do
        if ask(def.available, ctx.player, ctx) then
            context:addOption(ask(def.label, ctx) or M.TITLE, ctx, M.shortcut, def)
        end
    end
end

function M.onInventoryMenu(playerNum, context, items)
    local ctx = M.context(playerNum, nil, items)
    if ctx.player == nil or ctx.item == nil then return end
    local hooks = M.list("item")
    if #hooks == 0 then return end
    local option = context:addOption(M.TITLE)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    local added = false
    for _, def in ipairs(hooks) do
        if ask(def.fill, ctx.player, ctx, sub) then added = true end
    end
    if not added then context:removeLastOption() end
end

if not M.hooked then
    M.hooked = true
    Events.OnFillWorldObjectContextMenu.Add(function(...) return M.onWorldMenu(...) end)
    Events.OnFillInventoryObjectContextMenu.Add(function(...) return M.onInventoryMenu(...) end)
end
