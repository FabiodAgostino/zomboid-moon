-- ZomBotGravesUI: the gravestones of the fallen characters, for the admins (04/11/2026, phase 3 of the expeditions'
-- analysis approved by the user). Client only, in the Admin-Scorte mod with ZomBotStockUI.lua (its windows and
-- buttons) and ZomBotMenu.lua (the one «ZomBOT» entry of the right click). The server's half, which decides everything
-- and refuses anyone who is not an admin there, is server/ZomBotGraves.lua.
--
-- Redone the same day after the user tried it («mi aspettavo un tasto rapido se clicco sulla lapide per modificare la
-- posizione e per rimuoverla, un po' come lo strumento di posizionamento di default degli oggetti di pz ... un bottone
-- "Lapidi" che mi apra un menu con tutte le persone morte ... il menu si aggiorna solo se chiudo il gump e lo riapro»):
-- 1. «Lapidi», a button of ZomBOT's window (an `extra` of ZomBotMenu, for an admin wherever he right-clicked): every
--    dead the server keeps, each with its gravestone (where, how far, which shape and side) or none, and «Piazza»,
--    «Sposta», «Togli» for the one chosen (a double click: «Piazza», or «Sposta» when it has one). The shape is chosen
--    there («Forma»: the one of its stone when a dead with a stone is chosen).
-- 2. «Piazza» and «Sposta» work as the game's own build cursor: a cursor of ISBuildingObject's family set with
--    getCell():setDrag (the windows of ZomBOT step aside meanwhile), the stone's ghost under the mouse, green where it
--    can go and red where not (the same checks as the server: loaded, within REACH, floor, not solid, no other
--    gravestone; not over a window), R turns it (the rotate key of the game, between the two sides the tileset has:
--    south and east), a left click sends `place` or `move` {id, x, y, z, shape, facing, from}, Esc or the right click
--    cancels (the game does that for any such cursor: ToggleEscapeMenu, the world's context menu). A tooltip next to
--    the mouse says whose stone it is and, when red, why. Moving, the stone's square now is marked in gold. A cursor
--    born with the left button down (the second press of a double click: UIElement fires it on the press) places
--    nothing until the button has been seen up: else the release would place it right where the mouse was.
-- 3. Right click on a gravestone of ZomBOT: «Sposta la lapide di …» (the cursor at once, with that stone's shape and
--    side: the same stone, the same epitaph) and «Togli la lapide di …» (a question first), entries of their own right
--    after «ZomBOT» (`shortcut`s of ZomBotMenu).
-- 4. The window follows by itself: the server sends the list again to the admins after every change (a death, a
--    gravestone placed, moved or taken away), the window asks it again every POLL_MS while open (a safety net: the
--    server's own sending is what keeps it current), and every answer
--    (done or error) shows up in it and over the admin's head.
-- The client sends the id of the dead, the square, the shape and the side, nothing else: the epitaph is written by the
-- server. Nothing for anyone else.
if isServer() and not isClient() then return end

ZomBotGraves = ZomBotGraves or {}
local G = ZomBotGraves

G.MODULE = "ZomBotGraves"
G.KEY = "zombotGrave" -- the gravestone's modData (server/ZomBotGraves.lua)
G.NAME_KEY = "coffin_customContainerName" -- its epitaph, the name of its container
G.SEP = " \194\183 "
G.TILESET = "location_community_cemetary_01_"
-- {id, label, tile} as the server's Graves.SHAPES (facing south; facing east is the next tile)
G.SHAPES = { { "arched", "Ad arco", 2 }, { "round", "Arrotondata", 0 }, { "square", "Squadrata", 4 },
    { "worn", "Consumata", 8 } }
G.FACINGS = { { "south", "verso sud", 0 }, { "east", "verso est", 1 } }
G.REACH = 30 -- squares between the admin and the gravestone, as the server checks it
G.deaths = {} -- the last list the server sent
G.listed = false -- it came, since the window opened
G.LIST_WAIT_MS = 10000 -- then the server does not answer: no gravestones there (the server's script is missing)
G.POLL_MS = 30000 -- the list again while the window is open, in case a change of the server got lost
G.ANSWER_WAIT_MS = 10000
G.ASKING = "Chiedo al server i morti..."
G.NO_ANSWER = "Il server non risponde: le lapidi non sono ancora installate sul server."
G.NO_CHANGE = "Il server non ha risposto: forse il suo script delle lapidi \195\168 di prima."
G.lastFacing = "south" -- the side of the last stone placed: the next one starts there

-- -- pure helpers -------------------------------------------------------------------------------------------------------
-- B42 roles, as the server checks them
function G.isAdmin(player)
    player = player or getPlayer()
    if player == nil then return false end
    local ok, admin = pcall(function()
        local role = player:getRole()
        if role == nil then return false end
        return role:hasAdminPower() or role:hasCapability(Capability.CanSetupNonPVPZone)
    end)
    return ok and admin == true
end

-- the square right-clicked: the first object's, as the game's own admin menu takes it
function G.squareOf(ctx)
    for _, object in ipairs(ctx and ctx.worldobjects or {}) do
        local ok, square = pcall(function() return object:getSquare() end)
        if ok and square then return square end
    end
    return nil
end

-- the character's name, the epitaph before its first « · »
function G.nameOf(text)
    text = tostring(text or "")
    local cut = string.find(text, G.SEP, 1, true)
    return cut and string.sub(text, 1, cut - 1) or text
end

local function entry(list, id)
    for i, item in ipairs(list) do
        if item[1] == id then return item, i end
    end
    return nil
end

function G.sprite(shape, facing)
    local s = entry(G.SHAPES, shape) or G.SHAPES[1]
    local f = entry(G.FACINGS, facing) or G.FACINGS[1]
    return G.TILESET .. tostring(s[3] + f[3])
end

-- the shape and the side of a sprite of ours, or nil
function G.shapeOf(sprite)
    sprite = tostring(sprite or "")
    if string.sub(sprite, 1, #G.TILESET) ~= G.TILESET then return nil end
    local number = tonumber(string.sub(sprite, #G.TILESET + 1))
    for _, s in ipairs(G.SHAPES) do
        for _, f in ipairs(G.FACINGS) do
            if s[3] + f[3] == number then return s[1], f[1] end
        end
    end
    return nil
end

function G.shapeLabel(shape)
    return (entry(G.SHAPES, shape) or G.SHAPES[1])[2]
end

function G.facingLabel(facing)
    return (entry(G.FACINGS, facing) or G.FACINGS[1])[2]
end

-- R: the next side the tileset has
function G.nextFacing(facing)
    local _, i = entry(G.FACINGS, facing)
    return G.FACINGS[(i or 0) % #G.FACINGS + 1][1]
end

local function spriteNameOf(object)
    local ok, name = pcall(function() return object:getSpriteName() end)
    if ok and name then return name end
    ok, name = pcall(function() return object:getSprite():getName() end)
    return ok and name or nil
end

-- ZomBOT's gravestone on a square: the object and the id of its dead (of `except`'s, when given, never)
function G.graveOn(square, except)
    local ok, objects = pcall(function() return square:getObjects() end)
    if not ok or objects == nil then return nil end
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object:hasModData() then
            local id = object:getModData()[G.KEY]
            if id ~= nil and tostring(id) ~= except then return object, tostring(id) end
        end
    end
    return nil
end

-- ZomBOT's gravestone on the square right-clicked: {id, x, y, z, text, name, shape, facing}, or nil
function G.graveIn(ctx)
    local square = G.squareOf(ctx)
    if square == nil then return nil end
    local object, id = G.graveOn(square)
    if object == nil then return nil end
    local text = tostring(object:getModData()[G.NAME_KEY] or "")
    local shape, facing = G.shapeOf(spriteNameOf(object))
    return { id = id, x = square:getX(), y = square:getY(), z = square:getZ(), text = text, name = G.nameOf(text),
        shape = shape, facing = facing }
end

-- the mouse over one of the windows on the screen: a click there is for the window (as the game's furniture cursor)
function G.mouseOverUI()
    local ok, over = pcall(function()
        local uis = UIManager.getUI()
        for i = 0, uis:size() - 1 do
            local ui = uis:get(i)
            if ui:isVisible() and ui:isMouseOver() then return true end
        end
        return false
    end)
    return ok and over == true
end

-- Why the stone of `id` cannot go on that square, or nil: the server's own checks (Graves.spotError) with its words,
-- so green is what the server accepts.
function G.spotError(square, id, player)
    if G.mouseOverUI() then return "Sopra una finestra." end
    if square == nil then return "Quel punto non \195\168 caricato: avvicinati." end
    player = player or getPlayer()
    local ok, far = pcall(function()
        return math.abs(player:getX() - square:getX()) > G.REACH or math.abs(player:getY() - square:getY()) > G.REACH
    end)
    if ok and far then return "Troppo lontano: avvicinati al punto." end
    local free, room = pcall(function() return square:getFloor() ~= nil and not square:isSolid() end)
    if not free or not room then return "L\195\172 non c'\195\168 posto per una lapide." end
    if G.graveOn(square, id) then return "L\195\172 c'\195\168 gi\195\160 una lapide." end
    return nil
end

function G.send(command, args)
    sendClientCommand(getPlayer(), G.MODULE, command, args or {})
end

local function notify(text, bad)
    local ui = ZomBotUI and ZomBotUI.UI
    if ui and ui.notify then ui.notify(text, bad) end
end

function G.window()
    return ZomBotUI and ZomBotUI.windows and ZomBotUI.windows.ZomBotGraveWindow or nil
end

-- a change to the server: the answer is awaited (`done` or `error`), and the window says so meanwhile
function G.sendChange(command, args)
    G.pendingAt = getTimestampMs()
    G.send(command, args)
    local window = G.window()
    if window then window:setStatus("Un momento...", false) end
end

-- -- the cursor: the stone under the mouse, as the game's build and furniture cursors -------------------------------
local GOLD = { r = 0.94, g = 0.70, b = 0.20 }
local GREY = { r = 0.62, g = 0.64, b = 0.68 }
local GREEN = { r = 0.40, g = 0.82, b = 0.45 }

function G.rotateKeyName()
    local ok, name = pcall(function() return Keyboard.getKeyName(getCore():getKey(KeybindId.ROTATE_BUILDING)) end)
    return ok and name and name ~= "" and name or "R"
end

-- the left mouse button held down (the game's isMouseButtonDown, as its own windows read it)
function G.leftDown()
    local ok, down = pcall(function() return isMouseButtonDown(0) end)
    return ok and down == true
end

function G.isRotateKey(key)
    local ok, yes = pcall(function() return getCore():isKey(KeybindId.ROTATE_BUILDING, key) end)
    return ok and yes == true
end

-- what the tooltip next to the mouse says: {title, text, keys}
function G.cursorWords(job, why)
    local title = (job.mode == "move" and "Sposta la lapide di " or "Lapide di ") .. tostring(job.name)
    local text = G.shapeLabel(job.shape) .. ", " .. G.facingLabel(job.facing)
    if why then
        text = text .. " <LINE> <RGB:1,0.45,0.42> " .. why
    else
        local here = job.mode == "move" and "spostala qui" or "piazzala qui"
        text = text .. " <LINE> <RGB:0.5,0.9,0.55> Clic sinistro: " .. here
    end
    return title, text, G.rotateKeyName() .. ": ruota   -   Esc o clic destro: annulla"
end

-- The windows of ZomBOT step aside while the cursor is out (a window over the square right where the admin stands),
-- and come back when it goes, placed or not.
function G.hideWindows()
    G.hidden = G.hidden or {}
    for _, window in pairs(ZomBotUI and ZomBotUI.windows or {}) do
        if window:isVisible() then
            window:setVisible(false)
            G.hidden[#G.hidden + 1] = window
        end
    end
end

function G.showWindows(status)
    for _, window in ipairs(G.hidden or {}) do window:setVisible(true) end
    G.hidden = {}
    local window = G.window()
    if window and status then window:setStatus(status, false) end
end

-- Made at the first use: ISBuildingObject is in the game's server/ folder, which a client loads after client/.
function G.cursorClass()
    if G.Cursor then return G.Cursor end
    if ISBuildingObject == nil then return nil end
    local C = ISBuildingObject:derive("ZomBotGraveCursor")

    -- job: {mode = "place" | "move", id, name, shape, facing, from = {x, y, z} (moving: where it is now)}
    function C:new(character, job)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        o:init()
        o.character = character
        o.player = character:getPlayerNum()
        o.job = job
        o.noNeedHammer = true
        o.skipBuildAction = true
        o.skipWalk2 = true -- from where the admin stands: the server allows REACH squares
        -- born from a press (the double click on a row): nothing is placed until the button has been seen up
        o.armed = not G.leftDown()
        -- IsoCell.setDrag calls deactivate() only when the cursor has it itself (KahluaTable.rawget, 42.21)
        o.deactivate = C.deactivate
        return o
    end

    function C:getSprite()
        self.chosenSprite = G.sprite(self.job.shape, self.job.facing)
        return self.chosenSprite
    end

    function C:isValid(square)
        self.why = G.spotError(square, self.job.mode == "move" and self.job.id or nil, self.character)
        return self.why == nil
    end

    function C:render(x, y, z, square)
        -- Armed once the button is up, and not in the frame of a release (DoTileBuilding sets `build` on the release
        -- before render and calls tryBuild after it: that release is the one of the press the cursor was born from).
        if not self.armed and not self.build and not G.leftDown() then self.armed = true end
        local name = self:getSprite()
        if self.ghost == nil then self.ghost = IsoSprite.new() end
        if self.ghostName ~= name then
            self.ghost:LoadSingleTexture(name)
            self.ghostName = name
        end
        local colour = self.why and getCore():getBadHighlitedColor() or getCore():getGoodHighlitedColor()
        self.ghost:RenderGhostTileColor(x, y, z, colour:getR(), colour:getG(), colour:getB(), 0.8)
        local from = self.job.from
        if from then
            addAreaHighlightForPlayer(self.player, from.x, from.y, from.x + 1, from.y + 1, from.z, GOLD.r, GOLD.g,
                GOLD.b, 0.6)
        end
        self:showTip()
    end

    function C:showTip()
        if self.tip == nil then
            if ISToolTip == nil then return end
            self.tip = ISToolTip:new()
            self.tip:initialise()
            self.tip:addToUIManager()
            self.tip:setVisible(true)
            self.tip.followMouse = true
        end
        local title, text, keys = G.cursorWords(self.job, self.why)
        self.tip:setName(title)
        self.tip.description = text
        self.tip.footNote = keys
    end

    function C:hideTip()
        if self.tip then
            self.tip:setVisible(false)
            self.tip:removeFromUIManager()
            self.tip = nil
        end
    end

    -- the rotate key of the game (ISBuildingObject's own OnKeyPressed calls this on the cursor)
    function C:rotateKey(key)
        if not G.isRotateKey(key) then return end
        self.job.facing = G.nextFacing(self.job.facing)
        pcall(function() getSoundManager():playUISound("UIObjectMenuObjectRotateOutline") end)
    end

    function C:rotateMouse() end -- the button held turns nothing: a click places

    -- the click on a valid square (DoTileBuilding): straight to the server, no timed action, no walking; not the
    -- release of the press that made the cursor
    function C:tryBuild(x, y, z)
        if not self.armed then
            self:reinit()
            return
        end
        self:create(x, y, z)
    end

    function C:create(x, y, z)
        local job = self.job
        self.sent = true
        G.lastFacing = job.facing
        local args = { id = job.id, x = x, y = y, z = z, shape = job.shape, facing = job.facing }
        if job.mode == "move" then args.from = job.from end -- the server refuses it if its stone is elsewhere
        G.sendChange(job.mode, args)
        getCell():setDrag(nil, self.player)
    end

    -- the cursor goes: placed, Esc, the right click, another cursor
    function C:deactivate()
        if self.gone then return end
        self.gone = true
        self:hideTip()
        if G.cursor == self then G.cursor = nil end
        G.showWindows(not self.sent and "Annullato." or nil)
    end

    -- a click on an object (a container next to it) is the cursor's, never the loot window's (ISMoveableCursor too)
    function C.onObjectLeftMouseButtonDown()
        return true
    end

    G.Cursor = C
    return C
end

function G.startCursor(job)
    local class = G.cursorClass()
    local player = getPlayer()
    if class == nil or player == nil then return nil end
    local cursor = class:new(player, job)
    getCell():setDrag(cursor, cursor.player) -- the cursor before it, if any, goes first (its windows come back)
    G.cursor = cursor
    G.hideWindows()
    return cursor
end

-- «Sposta la lapide di …» on the stone right-clicked: the same shape and side to start with
function G.moveFrom(ctx)
    local found = G.graveIn(ctx)
    if found == nil then return nil end
    return G.startCursor({ mode = "move", id = found.id, name = found.name, shape = found.shape or G.SHAPES[1][1],
        facing = found.facing or G.lastFacing, from = { x = found.x, y = found.y, z = found.z } })
end

-- «Togli la lapide di …»: a question first. `target`: {id, name} (the window: wherever it is) or {x, y, z, name}
-- (the stone right-clicked).
function G.askRemove(target)
    if target == nil then return end
    local x, y = getCore():getScreenWidth() / 2 - 180, getCore():getScreenHeight() / 2 - 75
    local player = getPlayer()
    local modal = ISModalDialog:new(x, y, 360, 150, "Togliere la lapide di " .. tostring(target.name) .. "?", true,
        nil, G.onRemoveAnswer, player and player:getPlayerNum() or 0, target)
    modal:initialise()
    modal:addToUIManager()
end

function G.onRemoveAnswer(_, button, target)
    if button.internal ~= "YES" or target == nil then return end
    if target.id and target.x == nil then
        G.sendChange("remove", { id = target.id })
    else
        G.sendChange("remove", { x = target.x, y = target.y, z = target.z })
    end
end

-- -- the window: every dead, with its gravestone ----------------------------------------------------------------------
local PAD = 10

-- where its gravestone is, as the window says it: «Lapide a 110, 205 (piano 0), a 12 m da te - Ad arco, verso est»
function G.stoneText(stone, player)
    if stone == nil then return "Nessuna lapide" end
    local text = string.format("Lapide a %d, %d (piano %d)", stone.x, stone.y, stone.z)
    local ok, far = pcall(function()
        local dx, dy = player:getX() - stone.x, player:getY() - stone.y
        return math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
    end)
    if ok and far then text = text .. ", a " .. far .. " m da te" end
    if stone.shape then text = text .. " - " .. G.shapeLabel(stone.shape) .. ", " .. G.facingLabel(stone.facing) end
    return text
end

-- Made at the first opening: the window of the bases (ZomBotStockUI.lua, the same mod) is loaded after this file.
function G.windowClass()
    if G.Window then return G.Window end
    if ZomBotWindow == nil or ZomBotUI == nil or ZomBotUI.UI == nil then return nil end
    local UI = ZomBotUI.UI
    local small = getTextManager():getFontHeight(UIFont.Small)
    local medium = getTextManager():getFontHeight(UIFont.Medium)
    local buttonH = small + 8
    local W = ZomBotWindow:derive("ZomBotGraveWindow")

    function W:new(x, y, width, height)
        return ZomBotWindow.new(self, x, y, width, height, "ZomBOT  -  Lapidi")
    end

    function W:createChildren()
        ISCollapsableWindow.createChildren(self)
        local top = self:top() + medium + PAD
        local listHeight = self.height - top - buttonH * 2 - small - PAD * 4
        self.list = ISScrollingListBox:new(PAD, top, self.width - PAD * 2, listHeight)
        self.list:initialise()
        self.list:instantiate()
        self.list.itemheight = medium + small * 2 + 10
        self.list.font = UIFont.Small
        self.list.drawBorder = true
        self.list.doDrawItem = W.drawRow
        self.list:setOnMouseDoubleClick(self, W.onDoubleClick)
        self:addChild(self.list)
        local y = top + listHeight + PAD
        local half = (self.width - PAD * 3) / 2
        self.shapeCombo = ISComboBox:new(PAD, y, half, buttonH, self, W.onShape)
        self.shapeCombo:initialise()
        self:addChild(self.shapeCombo)
        for _, shape in ipairs(G.SHAPES) do self.shapeCombo:addOptionWithData("Forma: " .. shape[2], shape[1]) end
        self.shapeCombo.selected = 1
        self.hintX, self.hintY = PAD * 2 + half, y + (buttonH - small) / 2
        y = self.height - buttonH - PAD
        local w = (self.width - PAD * 5) / 4
        self.placeButton = UI.button(self, PAD, y, w, "Piazza", W.onPlace, "accept")
        self.moveButton = UI.button(self, PAD * 2 + w, y, w, "Sposta", W.onMove)
        self.removeButton = UI.button(self, PAD * 3 + w * 2, y, w, "Togli", W.onRemove, "cancel")
        self.doneButton = UI.button(self, PAD * 4 + w * 3, y, w, "Chiudi", W.close)
        self.statusY = y - small - PAD / 2
        self:setStatus(G.ASKING, false)
        self.askedAt = getTimestampMs()
        self.polledAt = self.askedAt
        self:refresh()
        G.send("list")
    end

    function W:refresh()
        if not self.list then return end
        local chosen = self:selected()
        self.list:clear()
        for _, death in ipairs(G.deaths) do
            local row = self.list:addItem(death.name, death)
            if chosen and chosen.id == death.id then self.list.selected = row.itemindex end
        end
        if self.list.selected > #self.list.items then self.list.selected = #self.list.items end
        if self.list.selected < 1 and #self.list.items > 0 then self.list.selected = 1 end
    end

    function W:selected()
        local row = self.list and self.list.items[self.list.selected]
        return row and row.item or nil
    end

    function W:shape()
        return self.shapeCombo:getOptionData(self.shapeCombo.selected) or G.SHAPES[1][1]
    end

    function W.drawRow(list, y, item, alt)
        local scroll = list:getYScroll()
        if y + scroll + item.height < 0 or y + scroll >= list.height then return y + item.height end -- out of view
        local death = item.item
        if list.selected == item.index then
            list:drawRect(0, y, list:getWidth(), item.height - 1, 0.35, 0.55, 0.40, 0.10)
        end
        list:drawRectBorder(0, y, list:getWidth(), item.height, 0.5, list.borderColor.r, list.borderColor.g,
            list.borderColor.b)
        local width = list:getWidth() - PAD * 2
        local title = death.name .. ((death.user or "") ~= "" and ("  (" .. death.user .. ")") or "")
        list:drawText(UI.fit(title, width, UIFont.Medium), PAD, y + 4, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Medium)
        local line = tostring(death.text or "")
        if death.test then line = "Prova - " .. line end -- a test entry (testdeath on the server)
        list:drawText(UI.fit(line, width), PAD, y + 6 + medium, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
        local c = death.stone and GREEN or GREY
        list:drawText(UI.fit(G.stoneText(death.stone, getPlayer()), width), PAD, y + 6 + medium + small, c.r, c.g, c.b,
            1, UIFont.Small)
        return y + item.height
    end

    function W:render()
        ISCollapsableWindow.render(self)
        local now = getTimestampMs()
        if not G.listed and self.status == G.ASKING and now - (self.askedAt or 0) > G.LIST_WAIT_MS then
            self:setStatus(G.NO_ANSWER, true)
        end
        if G.pendingAt and now - G.pendingAt > G.ANSWER_WAIT_MS then
            G.pendingAt = nil
            self:setStatus(G.NO_CHANGE, true)
        end
        if now - (self.polledAt or 0) >= G.POLL_MS then -- the list again: the window follows by itself
            self.polledAt = now
            G.send("list")
        end
        local stones = 0
        for _, death in ipairs(G.deaths) do
            if death.stone then stones = stones + 1 end
        end
        local text = string.format("%d morti, %d con la lapide. Scegline uno.", #G.deaths, stones)
        if G.listed and #G.deaths == 0 then
            text = "Nessun morto da ricordare: il server li annota da quando sa fare le lapidi."
        elseif not G.listed then
            text = ""
        end
        if text ~= "" then self:drawText(text, PAD, self:top(), 1, 1, 1, 1, UIFont.Medium) end
        self:drawText(G.rotateKeyName() .. " ruota la lapide mentre la piazzi.", self.hintX, self.hintY, GREY.r, GREY.g,
            GREY.b, 1, UIFont.Small)
        local death = self:selected()
        if death and death.id ~= self.shownId then -- another dead chosen (a click, the keys, a new list)
            self.shownId = death.id
            self:onSelect(death)
        end
        self.placeButton:setEnable(death ~= nil and not death.placed)
        self.moveButton:setEnable(death ~= nil and death.placed == true)
        self.removeButton:setEnable(death ~= nil and death.placed == true)
        self:drawStatus(self.statusY)
    end

    -- a dead with a gravestone chosen: «Forma» shows its shape, and «Sposta» keeps it unless the admin changes it
    function W:onSelect(death)
        self.shapeFor = nil
        if death.stone == nil or death.stone.shape == nil then return end
        local _, i = entry(G.SHAPES, death.stone.shape)
        if i then self.shapeCombo.selected = i end
    end

    function W:onDoubleClick(death)
        if death == nil then return end
        if death.placed then self:onMove() else self:onPlace() end
    end

    -- «Forma» changed by the admin, for the dead chosen now: «Sposta» takes it
    function W:onShape()
        local death = self:selected()
        self.shapeFor = death and death.id or nil
    end

    function W:onPlace()
        local death = self:selected()
        if death == nil or death.placed then return end
        G.startCursor({ mode = "place", id = death.id, name = death.name, shape = self:shape(), facing = G.lastFacing })
    end

    function W:onMove()
        local death = self:selected()
        if death == nil or not death.placed then return end
        local stone = death.stone or {}
        -- the stone's own shape, unless the admin changed «Forma» for this dead
        local shape = (self.shapeFor ~= death.id and stone.shape) or self:shape()
        G.startCursor({ mode = "move", id = death.id, name = death.name, shape = shape,
            facing = stone.facing or G.lastFacing,
            from = stone.x and { x = stone.x, y = stone.y, z = stone.z } or nil })
    end

    function W:onRemove()
        local death = self:selected()
        if death == nil or not death.placed then return end
        G.askRemove({ id = death.id, name = death.name })
    end

    function W:onResult(ok, text)
        self:setStatus(text, not ok)
    end

    G.Window = W
    return W
end

-- the window of the gravestones, wherever the admin right-clicked
function G.open()
    local class = G.windowClass()
    if class == nil then return nil end
    G.listed = false
    return ZomBotUI.show(class, 560, 500)
end

function G.onServerCommand(module, command, args)
    if module ~= G.MODULE then return end
    args = args or {}
    local window = G.window()
    if command == "list" then
        local found = {}
        for _, death in ipairs(args.deaths or {}) do found[#found + 1] = death end
        G.deaths, G.listed = found, true
        if window then
            if window.status == G.ASKING or window.status == G.NO_ANSWER then window:setStatus(nil, false) end
            window:refresh()
        end
        return
    end
    if command == "done" or command == "error" then
        G.pendingAt = nil
        notify(args.text, command == "error")
        if window then window:onResult(command == "done", args.text or "") end
    end
end

-- What this file offers in the one «ZomBOT» entry (client/ZomBotMenu.lua): the button «Lapidi» of the admins' window
-- of the bases, wherever the admin right-clicked, and two entries of their own on a gravestone of ZomBOT.
ZomBotMenu = ZomBotMenu or {}
ZomBotMenu.defs = ZomBotMenu.defs or {}
table.insert(ZomBotMenu.defs, {
    kind = "extra", id = "graves", order = 30,
    available = function(player) return G.isAdmin(player) end,
    label = function() return "Lapidi" end,
    onClick = function() G.open() end,
})
table.insert(ZomBotMenu.defs, {
    kind = "shortcut", id = "grave-move", order = 30,
    available = function(player, ctx) return G.isAdmin(player) and G.graveIn(ctx) ~= nil end,
    label = function(ctx)
        local found = G.graveIn(ctx)
        return "Sposta la lapide di " .. (found and found.name or "?")
    end,
    onClick = function(ctx) G.moveFrom(ctx) end,
})
table.insert(ZomBotMenu.defs, {
    kind = "shortcut", id = "grave-remove", order = 31,
    available = function(player, ctx) return G.isAdmin(player) and G.graveIn(ctx) ~= nil end,
    label = function(ctx)
        local found = G.graveIn(ctx)
        return "Togli la lapide di " .. (found and found.name or "?")
    end,
    onClick = function(ctx) G.askRemove(G.graveIn(ctx)) end,
})

if not G.hooked then -- a reload of the file adds no second handler
    G.hooked = true
    Events.OnServerCommand.Add(function(...) return ZomBotGraves.onServerCommand(...) end)
end
