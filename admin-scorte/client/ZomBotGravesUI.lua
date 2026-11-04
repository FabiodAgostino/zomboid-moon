-- ZomBotGravesUI: the gravestones of the fallen characters, for the admins (04/11/2026, phase 3 of the expeditions'
-- analysis approved by the user). Client only, in the Admin-Scorte mod with ZomBotStockUI.lua (its windows and
-- buttons) and ZomBotMenu.lua (the one «ZomBOT» entry of the right click). The server's half, which decides everything
-- and refuses anyone who is not an admin there, is server/ZomBotGraves.lua.
--
-- An admin right-clicks where the gravestone goes, «ZomBOT»: the list of bases, with the button «Piazza una lapide»
-- (an `extra` of ZomBotMenu). It opens the window of the gravestone: the recent dead as the server keeps them (asked
-- with `list`), the shape and the side it faces; «Piazza la lapide» sends the id of the dead and the square right-
-- clicked, nothing else: the epitaph is written by the server. On a gravestone of ZomBOT the button is «Togli la lapide
-- di …», with a question first. Nothing for anyone else.
if isServer() and not isClient() then return end

ZomBotGraves = ZomBotGraves or {}
local G = ZomBotGraves

G.MODULE = "ZomBotGraves"
G.KEY = "zombotGrave" -- the gravestone's modData (server/ZomBotGraves.lua)
G.NAME_KEY = "coffin_customContainerName" -- its epitaph, the name of its container
G.SEP = " · "
G.SHAPES = { { "arched", "Ad arco" }, { "round", "Arrotondata" }, { "square", "Squadrata" }, { "worn", "Consumata" } }
G.FACINGS = { { "south", "Verso sud" }, { "east", "Verso est" } }
G.deaths = {} -- the last list the server sent
G.listed = false -- it came, since the window opened
G.LIST_WAIT_MS = 10000 -- then the server does not answer: no gravestones there (the server's script is missing)
G.ASKING = "Chiedo al server i morti recenti..."
G.NO_ANSWER = "Il server non risponde: le lapidi non sono ancora installate sul server."

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

-- ZomBOT's gravestone on the square right-clicked: {x, y, z, text, name}, or nil
function G.graveIn(ctx)
    local square = G.squareOf(ctx)
    if square == nil then return nil end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object:hasModData() and object:getModData()[G.KEY] ~= nil then
            local text = tostring(object:getModData()[G.NAME_KEY] or "")
            return { x = square:getX(), y = square:getY(), z = square:getZ(), text = text, name = G.nameOf(text) }
        end
    end
    return nil
end

function G.send(command, args)
    sendClientCommand(getPlayer(), G.MODULE, command, args or {})
end

local function notify(text, bad)
    local ui = ZomBotUI and ZomBotUI.UI
    if ui and ui.notify then ui.notify(text, bad) end
end

-- -- the window ---------------------------------------------------------------------------------------------------------
local PAD = 10
local GOLD = { r = 0.94, g = 0.70, b = 0.20 }
local GREY = { r = 0.62, g = 0.64, b = 0.68 }

-- Made at the first opening: the window of the bases (ZomBotStockUI.lua, the same mod) is loaded after this file.
function G.windowClass()
    if G.Window then return G.Window end
    if ZomBotWindow == nil or ZomBotUI == nil or ZomBotUI.UI == nil then return nil end
    local UI = ZomBotUI.UI
    local small = getTextManager():getFontHeight(UIFont.Small)
    local medium = getTextManager():getFontHeight(UIFont.Medium)
    local buttonH = small + 8
    local W = ZomBotWindow:derive("ZomBotGraveWindow")

    function W:new(x, y, width, height, spot)
        local o = ZomBotWindow.new(self, x, y, width, height, "ZomBOT  -  Lapide")
        o.spot = spot
        return o
    end

    function W:createChildren()
        ISCollapsableWindow.createChildren(self)
        local top = self:top() + medium + PAD
        local listHeight = self.height - top - buttonH * 3 - PAD * 5
        self.list = ISScrollingListBox:new(PAD, top, self.width - PAD * 2, listHeight)
        self.list:initialise()
        self.list:instantiate()
        self.list.itemheight = medium + small + 10
        self.list.font = UIFont.Small
        self.list.drawBorder = true
        self.list.doDrawItem = W.drawRow
        self:addChild(self.list)
        local y = top + listHeight + PAD
        local half = (self.width - PAD * 3) / 2
        self.shapeCombo = ISComboBox:new(PAD, y, half, buttonH, self, W.onChoice)
        self.shapeCombo:initialise()
        self:addChild(self.shapeCombo)
        for _, shape in ipairs(G.SHAPES) do self.shapeCombo:addOptionWithData("Lapide: " .. shape[2], shape[1]) end
        self.shapeCombo.selected = 1
        self.facingCombo = ISComboBox:new(PAD * 2 + half, y, half, buttonH, self, W.onChoice)
        self.facingCombo:initialise()
        self:addChild(self.facingCombo)
        for _, facing in ipairs(G.FACINGS) do self.facingCombo:addOptionWithData(facing[2], facing[1]) end
        self.facingCombo.selected = 1
        y = self.height - buttonH - PAD
        self.placeButton = UI.button(self, PAD, y, half, "Piazza la lapide", W.onPlace, "accept")
        self.doneButton = UI.button(self, PAD * 2 + half, y, half, "Chiudi", W.close)
        self.statusY = y - small - PAD / 2
        self:setStatus(G.ASKING, false)
        self.askedAt = getTimestampMs()
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

    function W.drawRow(list, y, item, alt)
        local death = item.item
        if list.selected == item.index then
            list:drawRect(0, y, list:getWidth(), item.height - 1, 0.35, 0.55, 0.40, 0.10)
        end
        list:drawRectBorder(0, y, list:getWidth(), item.height, 0.5, list.borderColor.r, list.borderColor.g,
            list.borderColor.b)
        list:drawText(UI.fit(death.name .. "  (" .. death.user .. ")", list:getWidth() - PAD * 2, UIFont.Medium), PAD,
            y + 4, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Medium)
        local line = death.placed and ("Ha già una lapide - " .. death.text) or death.text
        if death.test then line = "Prova - " .. line end -- a test entry (testdeath on the server)
        list:drawText(UI.fit(line, list:getWidth() - PAD * 2), PAD, y + 6 + medium, GREY.r, GREY.g, GREY.b, 1,
            UIFont.Small)
        return y + item.height
    end

    function W:render()
        ISCollapsableWindow.render(self)
        if not G.listed and self.status == G.ASKING and getTimestampMs() - (self.askedAt or 0) > G.LIST_WAIT_MS then
            self:setStatus(G.NO_ANSWER, true)
        end
        local spot = self.spot
        local text = string.format("Dove: %d, %d (piano %d). Scegli chi ricordare.", spot.x, spot.y, spot.z)
        if G.listed and #G.deaths == 0 then
            text = "Nessun morto da ricordare: il server li annota da quando sa fare le lapidi."
        end
        self:drawText(text, PAD, self:top(), 1, 1, 1, 1, UIFont.Medium)
        self.placeButton:setEnable(self:selected() ~= nil)
        self:drawStatus(self.statusY)
    end

    function W:onChoice() end

    function W:onPlace()
        local death = self:selected()
        if death == nil then return end
        if death.placed then
            self:setStatus("Ha già una lapide: toglila prima (tasto destro su quella, ZomBOT).", true)
            return
        end
        self:setStatus("Un momento...", false)
        G.send("place", {
            id = death.id, x = self.spot.x, y = self.spot.y, z = self.spot.z,
            shape = self.shapeCombo:getOptionData(self.shapeCombo.selected),
            facing = self.facingCombo:getOptionData(self.facingCombo.selected),
        })
    end

    function W:onResult(ok, text)
        self:setStatus(text, not ok)
    end

    G.Window = W
    return W
end

-- the window for the square right-clicked
function G.open(ctx)
    local square = G.squareOf(ctx)
    local class = G.windowClass()
    if square == nil or class == nil then return nil end
    local spot = { x = square:getX(), y = square:getY(), z = square:getZ() }
    G.listed = false
    return ZomBotUI.show(class, 520, 430, spot)
end

-- «Togli la lapide di …»: a question first
function G.askRemove(ctx)
    local found = G.graveIn(ctx)
    if found == nil then return end
    local x, y = getCore():getScreenWidth() / 2 - 180, getCore():getScreenHeight() / 2 - 75
    local player = getPlayer()
    local modal = ISModalDialog:new(x, y, 360, 150, "Togliere la lapide di " .. found.name .. "?", true, nil,
        G.onRemoveAnswer, player and player:getPlayerNum() or 0, found)
    modal:initialise()
    modal:addToUIManager()
end

function G.onRemoveAnswer(_, button, found)
    if button.internal ~= "YES" or found == nil then return end
    G.send("remove", { x = found.x, y = found.y, z = found.z })
end

function G.onServerCommand(module, command, args)
    if module ~= G.MODULE then return end
    args = args or {}
    local window = ZomBotUI and ZomBotUI.windows and ZomBotUI.windows.ZomBotGraveWindow
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
        notify(args.text, command == "error")
        if window then
            window:onResult(command == "done", args.text or "")
            if command == "done" then G.send("list") end
        end
    end
end

-- What this file offers in the one «ZomBOT» entry (client/ZomBotMenu.lua): two buttons of the admins' window of the
-- bases, for the square right-clicked.
ZomBotMenu = ZomBotMenu or {}
ZomBotMenu.defs = ZomBotMenu.defs or {}
table.insert(ZomBotMenu.defs, {
    kind = "extra", id = "grave-place", order = 30,
    available = function(player, ctx) return G.isAdmin(player) and G.squareOf(ctx) ~= nil and G.graveIn(ctx) == nil end,
    label = function() return "Piazza una lapide" end,
    onClick = function(ctx) G.open(ctx) end,
})
table.insert(ZomBotMenu.defs, {
    kind = "extra", id = "grave-remove", order = 31,
    available = function(player, ctx) return G.isAdmin(player) and G.graveIn(ctx) ~= nil end,
    label = function(ctx)
        local found = G.graveIn(ctx)
        return "Togli la lapide di " .. (found and found.name or "?")
    end,
    onClick = function(ctx) G.askRemove(ctx) end,
})

Events.OnServerCommand.Add(G.onServerCommand)
