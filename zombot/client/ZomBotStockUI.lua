-- ZomBotStockUI: the admins' windows for ZomBOT's bases and stocks. Client only, and ONLY the admins copy it into
-- their own game (media/lua/client), with shared/ZomBotData.lua: the server runs with DoLuaChecksum=false, so
-- nobody else needs anything. Every change goes to the server (server/ZomBotStock.lua), which refuses it unless
-- the player is an admin there: this file cannot give powers to anyone.
--
-- What it adds, inside a base:
--   right click on an item: «ZomBOT: aggiungi a scorta» (three thresholds: critical, running low, good), any food
--   «aggiungi a scorta: Alimenti» (all the food together, in portions), books and magazines «controlla i libri /
--   le riviste» (copies of each), liquids «… in litri»;
-- «Scorte...» in the list of bases, or right click on the ground inside a base «ZomBOT: scorte di questa base»: every
--   check of the base with its thresholds and how it stands, «Modifica le soglie» and «Smetti di tracciare»;
-- anywhere: right click on the ground «ZomBOT: basi…» (list, new, edit, remove) and a «Basi» button on the map:
--   a base is drawn on the ground (click and drag), on the world map (click and drag), from the building you
--   stand in, or from two corners where you stand.
if isServer() and not isClient() then return end

ZomBotUI = ZomBotUI or {}
local Core = {}
ZomBotUI.Core = Core

Core.MODULE = "ZomBOT"
Core.MAX_SQUARES = 60000
Core.state = { bases = {} }   -- the last state the server sent
Core.waiting = {}             -- callbacks waiting for an answer, by command

-- -- pure helpers (tested in tests/test_lua_ui.py) ------------------------------------------------------------
function Core.trim(text)
    return (tostring(text or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

function Core.toInt(text)
    local cleaned = tostring(text or ""):gsub("%s", ""):gsub("[lL]$", "")
    if string.match(cleaned, "^%d%d?%d?%.%d%d%d") then cleaned = cleaned:gsub("%.", "") end -- 1.200
    cleaned = cleaned:gsub(",", ".")
    local n = tonumber(cleaned)
    if n == nil or n < 0 then return nil end
    return math.floor(n)
end

function Core.rect(ax, ay, bx, by)
    return math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by)
end

function Core.volume(r)
    return (r.x2 - r.x1 + 1) * (r.y2 - r.y1 + 1) * (r.z2 - r.z1 + 1)
end

function Core.baseAt(x, y, z)
    for _, base in ipairs(Core.state.bases or {}) do
        if x >= base.x1 and x <= base.x2 and y >= base.y1 and y <= base.y2 and z >= base.z1 and z <= base.z2 then
            return base
        end
    end
    return nil
end

function Core.findBase(name)
    local wanted = string.lower(Core.trim(name))
    for _, base in ipairs(Core.state.bases or {}) do
        if string.lower(base.name) == wanted then return base end
    end
    return nil
end

function Core.ruleOf(base, key)
    for _, rule in ipairs(base and base.rules or {}) do
        if rule.key == key then return rule end
    end
    return nil
end

-- what an item is for ZomBOT: {kind = "book", skill, label} / {kind = "magazine", series, label} /
-- {kind = "set", skill} (a set of books) / {kind = "item"}
function Core.describe(fullType)
    local data = ZomBotData or {}
    local book = (data.books or {})[fullType]
    if book then return { kind = "book", skill = book[1], label = (data.skills or {})[book[1]] or book[1] } end
    local series = (data.magazines or {})[fullType]
    if series then return { kind = "magazine", series = series, label = (data.series or {})[series] or series } end
    local inner = (data.unpack or {})[fullType]
    if inner and #inner > 1 and (data.books or {})[inner[1][1]] then
        local skill = data.books[inner[1][1]][1]
        return { kind = "set", skill = skill, label = (data.skills or {})[skill] or skill }
    end
    return { kind = "item" }
end

-- what a pack is made of, down to the single pieces (ZomBotData.unpack, the game's opening recipes): a carton or
-- a pack of cigarettes -> the cigarettes, a box of screws -> the screws, a box of jars -> the jars and the lids.
-- Empty for an item that is not a pack (and for book sets, which are books).
function Core.leaves(fullType)
    local unpack = (ZomBotData or {}).unpack or {}
    local out, seen = {}, {}
    local function walk(current, depth)
        local inner = unpack[current]
        if inner == nil or depth > 4 then
            if current ~= fullType and not seen[current] then
                seen[current] = true
                out[#out + 1] = current
            end
            return
        end
        for _, pair in ipairs(inner) do walk(pair[1], depth + 1) end
    end
    if Core.describe(fullType).kind == "item" then walk(fullType, 0) end
    return out
end

function Core.fluidLabel(fluid)
    return ((ZomBotData or {}).fluids or {})[fluid] or fluid
end

-- all the food is one check, «alimenti», in portions (25 hunger points, about a meal): an apple, a closed can, a box
-- of cans, an egg carton
Core.FOOD = "alimenti"
Core.FOOD_LABEL = "Alimenti (porzioni)"

function Core.isFood(fullType)
    return ((ZomBotData or {}).food or {})[fullType] ~= nil
end

-- the same checks as the server, so a wrong number is said at once (the server checks again)
function Core.thresholdError(critical, scarce, good)
    if not (critical and scarce and good) then return "Scrivi tre numeri interi (0 o più)." end
    if math.max(critical, scarce, good) > 1000000 then return "Il massimo è 1.000.000." end
    if critical > scarce then return "La soglia critica deve essere più bassa (o uguale) di quella di scarsità." end
    if good <= scarce then return "La soglia buona deve essere più alta di quella di scarsità." end
    return nil
end

function Core.baseError(name, r, oldName)
    name = Core.trim(name)
    if #name < 1 or #name > 40 then return "Serve un nome di 1-40 caratteri." end
    local other = Core.findBase(name)
    if other and (oldName == nil or string.lower(oldName) ~= string.lower(other.name)) then
        return "C'è già una base che si chiama '" .. other.name .. "'."
    end
    if r == nil or r.x1 == nil then return "Manca il rettangolo: disegnalo." end
    if Core.volume(r) > Core.MAX_SQUARES then
        return string.format("Troppo grande: %d caselle con i piani (massimo %d). Stringi il rettangolo o i piani.",
            Core.volume(r), Core.MAX_SQUARES)
    end
    return nil
end

function Core.floorsText(z1, z2)
    local function one(z)
        if z == 0 then return "piano terra" end
        if z < 0 then return "cantina (" .. z .. ")" end
        return z .. "° piano"
    end
    if z1 == z2 then return one(z1) end
    return "da " .. one(z1) .. " a " .. one(z2)
end

function Core.amount(value)
    local n = math.floor((tonumber(value) or 0) + 0.5)
    local text = tostring(n)
    while true do
        local replaced, count = text:gsub("^(-?%d+)(%d%d%d)", "%1.%2")
        text = replaced
        if count == 0 then break end
    end
    return text
end

function Core.level(have, rule)
    if have <= rule.critical then return "critical" end
    if have <= rule.scarce then return "scarce" end
    if have >= rule.good then return "good" end
    return "fair"
end

Core.LEVELS = {
    critical = { label = "Critico", r = 0.86, g = 0.24, b = 0.24 },
    scarce = { label = "Scarseggia", r = 0.94, g = 0.55, b = 0.16 },
    fair = { label = "Sufficiente", r = 0.93, g = 0.80, b = 0.25 },
    good = { label = "Buono", r = 0.30, g = 0.75, b = 0.36 },
}

-- the window's title: the pills are counted by the dose, not by the bottle
function Core.unitLabel(fullType, name)
    if ((ZomBotData or {}).doses or {})[fullType] then return name .. " (dosi)" end
    return name
end

function Core.itemName(fullType)
    local ok, name = pcall(function() return getItemNameFromFullType(fullType) end)
    return ok and name or fullType
end

-- where this item is short, for the line under its tooltip: «Scarseggia a RiversideMoon (12 su 30)»,
-- «Mancante a Napoli», «Manca a RiversideMoon» (a book or a magazine that base lacks). From each base's last
-- complete count (made when someone walks out of it, when a check changes, or by ZomBOT's /scorte): out in town
-- the bases are not in the game's memory, so this is what is known. A pack also tells about what it holds, any food
-- about all the food («Alimenti: scarseggiano a RiversideMoon (112 su 200)»).
function Core.shortages(fullType, fluid)
    local lines = {}
    local keys = { fullType }
    if Core.isFood(fullType) then
        keys = { Core.FOOD }
    else
        for _, leaf in ipairs(Core.leaves(fullType)) do keys[#keys + 1] = leaf end
    end
    if fluid then keys[#keys + 1] = "liquido:" .. fluid end
    for _, base in ipairs(Core.state.bases or {}) do
        local status = base.status
        if status then
            for _, key in ipairs(keys) do
                local s = status.items and status.items[key]
                local rule = Core.ruleOf(base, key)
                if s and rule and (s.level == "critical" or s.level == "scarce") then
                    local litres = string.sub(key, 1, 8) == "liquido:"
                    local food = key == Core.FOOD
                    local what = ""
                    if litres then what = Core.fluidLabel(fluid) .. ": "
                    elseif food then what = "Alimenti: "
                    elseif key ~= fullType then what = Core.itemName(key) .. ": " end
                    local have = litres and (string.format("%.1f", s.have):gsub("%.", ",") .. " L") or Core.amount(s.have)
                    local text
                    if s.level == "critical" and s.have <= 0 then
                        text = (food and "Mancano a " or "Mancante a ") .. base.name
                    else
                        local word = s.level == "critical" and (food and "Critici a " or "Critico a ")
                            or (food and "Scarseggiano a " or "Scarseggia a ")
                        text = word .. base.name .. " (" .. have .. " su " .. Core.amount(rule.good)
                            .. (food and " porzioni)" or ")")
                    end
                    lines[#lines + 1] = { text = what .. text, level = s.level }
                end
            end
            for key, set in pairs(status.missing or {}) do
                if set[fullType] and Core.ruleOf(base, key) then
                    lines[#lines + 1] = { text = "Manca a " .. base.name, level = "critical" }
                    break
                end
            end
        end
    end
    return lines
end

-- -- a base's checks, as the «scorte della base» window lists them ----------------------------------------------
-- what a check is: "food", "fluid", "books", "magazines" or "item", and the rest of its key (skill, series, fluid)
function Core.ruleKind(key)
    if key == Core.FOOD then return "food" end
    local head, rest = string.match(key, "^(%a+):(.+)$")
    if key == "libri" or head == "libri" then return "books", rest end
    if key == "riviste" or head == "riviste" then return "magazines", rest end
    if head == "liquido" then return "fluid", rest end
    return "item"
end

function Core.ruleLabel(key)
    local kind, rest = Core.ruleKind(key)
    local data = ZomBotData or {}
    if kind == "food" then return Core.FOOD_LABEL end
    if kind == "fluid" then return Core.fluidLabel(rest) .. " (litri)" end
    if kind == "books" then
        return rest and ("Libri di " .. ((data.skills or {})[rest] or rest)) or "Libri delle abilità (tutti)"
    end
    if kind == "magazines" then
        return rest and ("Riviste di " .. ((data.series or {})[rest] or rest)) or "Riviste di ricette (tutte)"
    end
    return Core.unitLabel(key, Core.itemName(key))
end

-- the item whose icon stands for the check
function Core.ruleIcon(key)
    local kind = Core.ruleKind(key)
    if kind == "item" then return key end
    return ({ food = "Base.TinnedBeans", fluid = "Base.WaterBottle", books = "Base.Book", magazines = "Base.Magazine" })[kind]
end

-- «Critico fino a 100, scarseggia fino a 500, buono da 1.000», «1 copia di ogni volume»
function Core.ruleText(rule)
    local kind = Core.ruleKind(rule.key)
    if kind == "books" or kind == "magazines" then
        local copies = rule.good == 1 and "1 copia" or (rule.good .. " copie")
        return copies .. (kind == "books" and " di ogni volume" or " di ognuna")
    end
    local unit = kind == "fluid" and " L" or ""
    local text = "Critico fino a " .. Core.amount(rule.critical) .. unit .. ", scarseggia fino a "
        .. Core.amount(rule.scarce) .. unit .. ", buono da " .. Core.amount(rule.good) .. unit
    return kind == "food" and (text .. " porzioni") or text
end

-- how the check stands in the base's last complete count: {text, level}; no level when it was never counted
function Core.ruleStatus(base, rule)
    local kind = Core.ruleKind(rule.key)
    local status = base and base.status
    if kind == "books" or kind == "magazines" then
        local set = status and status.missing and status.missing[rule.key]
        if set == nil then return { text = "Non ancora contato" } end
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        if n == 0 then return { text = kind == "books" and "Ci sono tutti" or "Ci sono tutte", level = "good" } end
        return { text = n == 1 and "Ne manca 1" or ("Ne mancano " .. n), level = "critical" }
    end
    local s = status and status.items and status.items[rule.key]
    if s == nil or Core.LEVELS[s.level] == nil then return { text = "Non ancora contato" } end
    local have = kind == "fluid" and (string.format("%.1f", s.have):gsub("%.", ",") .. " L") or Core.amount(s.have)
    return { text = have .. " - " .. Core.LEVELS[s.level].label, level = s.level }
end

-- the checks of a base in alphabetical order, with their labels
function Core.sortedRules(base)
    local rows = {}
    for _, rule in ipairs(base and base.rules or {}) do
        rows[#rows + 1] = { rule = rule, label = Core.ruleLabel(rule.key) }
    end
    table.sort(rows, function(a, b) return string.lower(a.label) < string.lower(b.label) end)
    return rows
end

-- -- who may use it -------------------------------------------------------------------------------------------
-- B42 roles (as the game's own admin tools check them); the server checks the same on every command
function Core.isAdmin(player)
    player = player or getPlayer()
    if player == nil then return false end
    local ok, admin = pcall(function()
        local role = player:getRole()
        if role == nil then return false end
        return role:hasAdminPower() or role:hasCapability(Capability.CanSetupNonPVPZone)
    end)
    return ok and admin == true
end

-- -- talking to the server -----------------------------------------------------------------------------------
function Core.send(command, args, onAnswer)
    if onAnswer then
        Core.waiting[command] = Core.waiting[command] or {}
        table.insert(Core.waiting[command], onAnswer)
    end
    sendClientCommand(getPlayer(), Core.MODULE, command, args or {})
end

function Core.onServerCommand(module, command, args)
    if module ~= Core.MODULE then return end
    if command == "state" then
        Core.state = args or { bases = {} }
        if ZomBotUI.onState then ZomBotUI.onState() end
        return
    end
    if command == "done" or command == "error" then
        if ZomBotUI.onResult then ZomBotUI.onResult(command == "done", args or {}) end
        return
    end
    local queue = Core.waiting[command]
    if queue and #queue > 0 then
        local callback = table.remove(queue, 1)
        callback(args or {})
    end
end

-- -- look and feel ------------------------------------------------------------------------------------------
local UI = {}
ZomBotUI.UI = UI
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local PAD = 10
local BUTTON_HGT = FONT_HGT_SMALL + 8
local GOLD = { r = 0.94, g = 0.70, b = 0.20 }
local GREY = { r = 0.62, g = 0.64, b = 0.68 }
local GREEN = { r = 0.40, g = 0.82, b = 0.45 }
local RED = { r = 0.95, g = 0.35, b = 0.32 }

function UI.textWidth(text, font)
    return getTextManager():MeasureStringX(font or UIFont.Small, text)
end

function UI.button(parent, x, y, w, title, onClick, kind)
    local button = ISButton:new(x, y, w, BUTTON_HGT, title, parent, onClick)
    button:initialise()
    button:instantiate()
    if kind == "accept" then button:enableAcceptColor() end
    if kind == "cancel" then button:enableCancelColor() end
    parent:addChild(button)
    return button
end

function UI.entry(parent, x, y, w, text, numbers)
    local entry = ISTextEntryBox:new(tostring(text or ""), x, y, w, BUTTON_HGT)
    entry:initialise()
    entry:instantiate()
    if numbers then entry:setOnlyNumbers(true) end
    parent:addChild(entry)
    return entry
end

function UI.notify(text, bad)
    local player = getPlayer()
    if player == nil or text == nil or text == "" then return end
    pcall(function()
        if bad then HaloTextHelper.addBadText(player, text) else HaloTextHelper.addGoodText(player, text) end
    end)
end

-- a window that goes away when closed (ISCollapsableWindow only hides itself)
ZomBotWindow = ISCollapsableWindow:derive("ZomBotWindow")

function ZomBotWindow:new(x, y, width, height, title)
    local o = ISCollapsableWindow.new(self, x, y, width, height)
    o:setTitle(title)
    o:setResizable(false)
    o.player = getPlayer()
    o.playerNum = o.player and o.player:getPlayerNum() or 0
    o.status, o.statusBad = nil, false
    return o
end

function ZomBotWindow:top()
    return self:titleBarHeight() + PAD
end

function ZomBotWindow:setStatus(text, bad)
    self.status, self.statusBad = text, bad
end

function ZomBotWindow:drawStatus(y, x)
    if self.status and self.status ~= "" then
        local c = self.statusBad and RED or GREEN
        self:drawText(self.status, x or PAD, y, c.r, c.g, c.b, 1, UIFont.Small)
    end
end

function ZomBotWindow:close()
    if ZomBotUI.awaiting == self then ZomBotUI.awaiting = nil end
    self:setVisible(false)
    self:removeFromUIManager()
    ZomBotUI.windows[self.Type] = nil
end

ZomBotUI.windows = ZomBotUI.windows or {}

-- one window of each kind at a time, in the middle of the screen
function ZomBotUI.show(class, width, height, ...)
    local old = ZomBotUI.windows[class.Type]
    if old then old:close() end
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local window = class:new(x, y, width, height, ...)
    window:initialise()
    window:addToUIManager()
    ZomBotUI.windows[class.Type] = window
    return window
end

-- the server answered a change: the window that sent it shows the outcome, the player sees it over the head
function ZomBotUI.onResult(ok, args)
    UI.notify(args.text, not ok)
    local window = ZomBotUI.awaiting
    if window and window.onResult then
        ZomBotUI.awaiting = nil
        window:onResult(ok, args.text or "")
    end
end

function ZomBotUI.onState()
    for _, window in pairs(ZomBotUI.windows) do
        if window.refresh then window:refresh() end
    end
end

-- -- the list of bases --------------------------------------------------------------------------------------
ZomBotBasesWindow = ZomBotWindow:derive("ZomBotBasesWindow")

function ZomBotBasesWindow:new(x, y, width, height)
    local o = ZomBotWindow.new(self, x, y, width, height, "ZomBOT  -  Basi")
    return o
end

function ZomBotBasesWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:top() + FONT_HGT_MEDIUM + PAD
    local listHeight = self.height - top - BUTTON_HGT * 2 - PAD * 4
    self.list = ISScrollingListBox:new(PAD, top, self.width - PAD * 2, listHeight)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = FONT_HGT_MEDIUM + FONT_HGT_SMALL * 2 + 10
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    self.list.doDrawItem = ZomBotBasesWindow.drawRow
    self.list.owner = self
    self:addChild(self.list)
    local y = top + listHeight + PAD
    local w = (self.width - PAD * 5) / 4
    self.newButton = UI.button(self, PAD, y, w, "Nuova base", ZomBotBasesWindow.onNew, "accept")
    self.editButton = UI.button(self, PAD * 2 + w, y, w, "Modifica", ZomBotBasesWindow.onEdit)
    self.mapButton = UI.button(self, PAD * 3 + w * 2, y, w, "Sulla mappa", ZomBotBasesWindow.onMap)
    self.removeButton = UI.button(self, PAD * 4 + w * 3, y, w, "Togli", ZomBotBasesWindow.onRemove, "cancel")
    self.rulesButton = UI.button(self, PAD, y + BUTTON_HGT + PAD, w, "Scorte...", ZomBotBasesWindow.onRules)
    -- not closeButton: that is the X of the title bar in ISCollapsableWindow
    self.doneButton = UI.button(self, self.width - PAD - w, y + BUTTON_HGT + PAD, w, "Chiudi", ZomBotBasesWindow.close)
    self:refresh()
    Core.send("state")
end

function ZomBotBasesWindow:refresh()
    if not self.list then return end
    local selected = self:selectedBase()
    self.list:clear()
    for _, base in ipairs(Core.state.bases or {}) do
        local row = self.list:addItem(base.name, base)
        if selected and selected.id == base.id then self.list.selected = row.itemindex end
    end
    if self.list.selected == 0 and #self.list.items > 0 then self.list.selected = 1 end
end

function ZomBotBasesWindow:selectedBase()
    local row = self.list and self.list.items[self.list.selected]
    return row and row.item or nil
end

function ZomBotBasesWindow.drawRow(list, y, item, alt)
    local base = item.item
    if list.selected == item.index then
        list:drawRect(0, y, list:getWidth(), item.height - 1, 0.35, 0.55, 0.40, 0.10)
    end
    list:drawRectBorder(0, y, list:getWidth(), item.height, 0.5, list.borderColor.r, list.borderColor.g, list.borderColor.b)
    local player = getPlayer()
    local here = player and Core.baseAt(math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()))
    list:drawText(base.name, PAD, y + 4, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Medium)
    if here and here.id == base.id then
        local x = PAD * 2 + UI.textWidth(base.name, UIFont.Medium)
        list:drawText("sei qui", x, y + 4 + (FONT_HGT_MEDIUM - FONT_HGT_SMALL) / 2, GREEN.r, GREEN.g, GREEN.b, 1, UIFont.Small)
    end
    local line = string.format("%d x %d m - %s - da (%d, %d) a (%d, %d)", base.x2 - base.x1 + 1, base.y2 - base.y1 + 1,
        Core.floorsText(base.z1, base.z2), base.x1, base.y1, base.x2, base.y2)
    list:drawText(line, PAD, y + 6 + FONT_HGT_MEDIUM, 0.85, 0.85, 0.85, 1, UIFont.Small)
    local count = #(base.rules or {})
    local checks = count == 0 and "Niente da controllare: tasto destro su un oggetto dentro la base"
        or (count == 1 and "1 cosa da controllare (Scorte...)" or (count .. " cose da controllare (Scorte...)"))
    list:drawText(checks, PAD, y + 6 + FONT_HGT_MEDIUM + FONT_HGT_SMALL, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
    return y + item.height
end

function ZomBotBasesWindow:render()
    ISCollapsableWindow.render(self)
    local player = getPlayer()
    local here = player and Core.baseAt(math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()))
    local text = here and ("Sei dentro la base '" .. here.name .. "'.") or "Non sei dentro nessuna base."
    local count = #(Core.state.bases or {})
    if count == 0 then text = "Nessuna base ancora: creane una con 'Nuova base'." end
    self:drawText(text, PAD, self:top(), 1, 1, 1, 1, UIFont.Medium)
    local hasBase = self:selectedBase() ~= nil
    self.editButton:setEnable(hasBase)
    self.mapButton:setEnable(hasBase)
    self.removeButton:setEnable(hasBase)
    self.rulesButton:setEnable(hasBase)
    -- between «Scorte...» and «Chiudi»
    self:drawStatus(self.height - BUTTON_HGT - PAD + 4, PAD * 2 + self.rulesButton.width)
end

function ZomBotBasesWindow:onRules()
    local base = self:selectedBase()
    if base then ZomBotUI.openRules(nil, base.name) end
end

function ZomBotBasesWindow:onNew()
    ZomBotUI.openEditor(nil)
end

function ZomBotBasesWindow:onEdit()
    local base = self:selectedBase()
    if base then ZomBotUI.openEditor(base) end
end

function ZomBotBasesWindow:onMap()
    local base = self:selectedBase()
    if base then
        ISWorldMap.ShowWorldMap(self.playerNum, (base.x1 + base.x2) / 2, (base.y1 + base.y2) / 2, 20.0)
    end
end

function ZomBotBasesWindow:onRemove()
    local base = self:selectedBase()
    if not base then return end
    local count = #(base.rules or {})
    local text = "Togliere la base '" .. base.name .. "'"
        .. (count > 0 and (" e le sue " .. count .. " cose da controllare?") or "?")
    local x, y = getCore():getScreenWidth() / 2 - 180, getCore():getScreenHeight() / 2 - 75
    local modal = ISModalDialog:new(x, y, 360, 150, text, true, self, ZomBotBasesWindow.onRemoveAnswer, self.playerNum, base.name)
    modal:initialise()
    modal:addToUIManager()
end

function ZomBotBasesWindow:onRemoveAnswer(button, name)
    if button.internal ~= "YES" then return end
    ZomBotUI.awaiting = self
    Core.send("removeBase", { name = name })
end

function ZomBotBasesWindow:onResult(ok, text)
    self:setStatus(text, not ok)
end

function ZomBotUI.openBases()
    return ZomBotUI.show(ZomBotBasesWindow, 560, 470)
end

-- -- what a base checks: each check with its thresholds and how it stands; change it or stop tracking it ----------
ZomBotRulesWindow = ZomBotWindow:derive("ZomBotRulesWindow")
local ICON = 32

function ZomBotRulesWindow:new(x, y, width, height, baseName)
    local o = ZomBotWindow.new(self, x, y, width, height, "ZomBOT  -  Scorte della base")
    o.baseName = baseName
    return o
end

function ZomBotRulesWindow:base()
    return Core.findBase(self.baseName)
end

function ZomBotRulesWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:top() + FONT_HGT_MEDIUM + FONT_HGT_SMALL + PAD
    local listHeight = self.height - top - BUTTON_HGT - FONT_HGT_SMALL - PAD * 3
    self.list = ISScrollingListBox:new(PAD, top, self.width - PAD * 2, listHeight)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = math.max(ICON + 8, FONT_HGT_SMALL * 2 + 10)
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    self.list.doDrawItem = ZomBotRulesWindow.drawRow
    self.list.owner = self
    self:addChild(self.list)
    local y = self.height - BUTTON_HGT - PAD
    local w = (self.width - PAD * 4) / 3
    self.editButton = UI.button(self, PAD, y, w, "Modifica le soglie...", ZomBotRulesWindow.onEdit)
    self.removeButton = UI.button(self, PAD * 2 + w, y, w, "Smetti di tracciare", ZomBotRulesWindow.onRemove, "cancel")
    self.doneButton = UI.button(self, PAD * 3 + w * 2, y, w, "Chiudi", ZomBotRulesWindow.close)
    self:refresh()
end

-- a new state from the server (a check removed or changed, a new count): the list follows it
function ZomBotRulesWindow:refresh()
    if not self.list then return end
    local selected = self:selectedRule()
    self.list:clear()
    for _, row in ipairs(Core.sortedRules(self:base())) do
        pcall(function() row.texture = getItemTex(Core.ruleIcon(row.rule.key)) end)
        local item = self.list:addItem(row.label, row)
        if selected and selected.key == row.rule.key then self.list.selected = item.itemindex end
    end
    if self.list.selected > #self.list.items then self.list.selected = #self.list.items end
    if self.list.selected < 1 and #self.list.items > 0 then self.list.selected = 1 end
end

function ZomBotRulesWindow:selectedRule()
    local row = self.list and self.list.items[self.list.selected]
    return row and row.item.rule or nil
end

function ZomBotRulesWindow.drawRow(list, y, item, alt)
    local row = item.item
    if list.selected == item.index then
        list:drawRect(0, y, list:getWidth(), item.height - 1, 0.35, 0.55, 0.40, 0.10)
    end
    list:drawRectBorder(0, y, list:getWidth(), item.height, 0.5, list.borderColor.r, list.borderColor.g, list.borderColor.b)
    local x = PAD
    if row.texture then
        list:drawTextureScaledAspect(row.texture, PAD, y + (item.height - ICON) / 2, ICON, ICON, 1, 1, 1, 1)
        x = PAD * 2 + ICON
    end
    local top = y + (item.height - FONT_HGT_SMALL * 2) / 2
    list:drawText(row.label, x, top, 1, 1, 1, 1, UIFont.Small)
    list:drawText(Core.ruleText(row.rule), x, top + FONT_HGT_SMALL, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
    -- how it stands, on the right: a coloured square and the number
    local s = Core.ruleStatus(list.owner:base(), row.rule)
    local c = s.level and Core.LEVELS[s.level] or GREY
    local right = list:getWidth() - PAD - 16 -- room for the scroll bar
    local tx = right - UI.textWidth(s.text)
    list:drawText(s.text, tx, top, c.r, c.g, c.b, 1, UIFont.Small)
    if s.level then list:drawRect(tx - 14, top + 3, 9, FONT_HGT_SMALL - 6, 1, c.r, c.g, c.b) end
    return y + item.height
end

function ZomBotRulesWindow:render()
    ISCollapsableWindow.render(self)
    local base = self:base()
    local y = self:top()
    if base == nil then
        self:drawText("La base '" .. self.baseName .. "' non c'è più.", PAD, y, RED.r, RED.g, RED.b, 1, UIFont.Medium)
        self.editButton:setEnable(false)
        self.removeButton:setEnable(false)
        return
    end
    self:drawText(base.name, PAD, y, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Medium)
    local count = #(base.rules or {})
    local text = "Niente da controllare: tasto destro su un oggetto dentro la base per aggiungerlo."
    if count > 0 then
        text = (count == 1 and "1 cosa da controllare" or (count .. " cose da controllare"))
            .. ", con i numeri dell'ultimo conteggio completo."
    end
    self:drawText(text, PAD, y + FONT_HGT_MEDIUM + 2, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
    local has = self:selectedRule() ~= nil
    self.editButton:setEnable(has)
    self.removeButton:setEnable(has)
    self:drawStatus(self.height - BUTTON_HGT - PAD * 2 - FONT_HGT_SMALL)
end

function ZomBotRulesWindow:onEdit()
    local rule = self:selectedRule()
    if rule == nil then return end
    local kind, rest = Core.ruleKind(rule.key)
    if kind == "books" or kind == "magazines" then
        ZomBotUI.openSet(nil, self.baseName, kind, rest)
        return
    end
    local texture = nil
    pcall(function() texture = getItemTex(Core.ruleIcon(rule.key)) end)
    ZomBotUI.openStock(nil, self.baseName, rule.key, Core.ruleLabel(rule.key), texture)
end

function ZomBotRulesWindow:onRemove()
    local rule = self:selectedRule()
    if rule == nil then return end
    local text = "Smettere di tracciare '" .. Core.ruleLabel(rule.key) .. "' nella base '" .. self.baseName .. "'?"
    local x, y = getCore():getScreenWidth() / 2 - 190, getCore():getScreenHeight() / 2 - 75
    local modal = ISModalDialog:new(x, y, 380, 150, text, true, self, ZomBotRulesWindow.onRemoveAnswer, self.playerNum, rule.key)
    modal:initialise()
    modal:addToUIManager()
end

function ZomBotRulesWindow:onRemoveAnswer(button, key)
    if button.internal ~= "YES" then return end
    ZomBotUI.awaiting = self
    self:setStatus("Tolgo...", false)
    Core.send("removeRule", { base = self.baseName, key = key })
end

function ZomBotRulesWindow:onResult(ok, text)
    self:setStatus(text, not ok)
end

function ZomBotUI.openRules(_, baseName)
    return ZomBotUI.show(ZomBotRulesWindow, 620, 480, baseName)
end

-- -- drawing a base -------------------------------------------------------------------------------------------
ZomBotBaseEditor = ZomBotWindow:derive("ZomBotBaseEditor")

ZomBotBaseEditor.FLOORS = { { 0, 0 }, { 0, 1 }, { 0, 2 }, { -1, 0 }, { -1, 1 }, { -1, 2 }, { -1, 3 } }

function ZomBotBaseEditor:new(x, y, width, height, base)
    local o = ZomBotWindow.new(self, x, y, width, height, base and ("Modifica la base '" .. base.name .. "'") or "Nuova base")
    o.base = base
    if base then
        o.rect = { x1 = base.x1, y1 = base.y1, x2 = base.x2, y2 = base.y2 }
        o.floors = { base.z1, base.z2 }
    else
        o.floors = { -1, 2 }
    end
    return o
end

function ZomBotBaseEditor:createChildren()
    ISCollapsableWindow.createChildren(self)
    local y = self:top()
    local labelW = UI.textWidth("Nome della base") + PAD
    self.nameY = y
    self.nameEntry = UI.entry(self, PAD + labelW, y, self.width - PAD * 2 - labelW, self.base and self.base.name or "")
    y = y + BUTTON_HGT + PAD * 2
    self.drawY = y
    y = y + FONT_HGT_SMALL + 4
    local w = (self.width - PAD * 4) / 3
    self.groundButton = UI.button(self, PAD, y, w, "Disegna sul terreno", ZomBotBaseEditor.onGround, "accept")
    self.mapButton = UI.button(self, PAD * 2 + w, y, w, "Disegna sulla mappa", ZomBotBaseEditor.onMap, "accept")
    self.houseButton = UI.button(self, PAD * 3 + w * 2, y, w, "Prendi questa casa", ZomBotBaseEditor.onHouse)
    y = y + BUTTON_HGT + PAD / 2
    self.cornerA = UI.button(self, PAD, y, w, "Angolo A: qui", ZomBotBaseEditor.onCornerA)
    self.cornerB = UI.button(self, PAD * 2 + w, y, w, "Angolo B: qui", ZomBotBaseEditor.onCornerB)
    y = y + BUTTON_HGT + PAD * 2
    -- the corners, editable by hand
    self.coordsY = y
    local entryW = (self.width - PAD * 2 - UI.textWidth("Da x") - UI.textWidth(" y ") * 2 - UI.textWidth(" a x") - PAD * 4) / 4
    local x = PAD + UI.textWidth("Da x") + 4
    self.x1Entry = UI.entry(self, x, y, entryW, "", true)
    x = x + entryW + UI.textWidth(" y ") + 4
    self.y1Entry = UI.entry(self, x, y, entryW, "", true)
    x = x + entryW + UI.textWidth(" a x") + 8
    self.x2Entry = UI.entry(self, x, y, entryW, "", true)
    x = x + entryW + UI.textWidth(" y ") + 4
    self.y2Entry = UI.entry(self, x, y, entryW, "", true)
    self.coordLabels = {
        { "Da x", PAD }, { "y", self.x1Entry:getRight() + 4 }, { "a x", self.y1Entry:getRight() + 6 },
        { "y", self.x2Entry:getRight() + 4 },
    }
    y = y + BUTTON_HGT + PAD
    self.floorsY = y
    self.floorsCombo = ISComboBox:new(PAD + UI.textWidth("Piani") + PAD, y, self.width - PAD * 3 - UI.textWidth("Piani"), BUTTON_HGT, self, ZomBotBaseEditor.onFloors)
    self.floorsCombo:initialise()
    self:addChild(self.floorsCombo)
    self:fillFloors()
    y = y + BUTTON_HGT + PAD
    self.infoY = y
    local bw = (self.width - PAD * 3) / 2
    self.saveButton = UI.button(self, PAD, self.height - BUTTON_HGT - PAD, bw, "Salva", ZomBotBaseEditor.onSave, "accept")
    self.cancelButton = UI.button(self, PAD * 2 + bw, self.height - BUTTON_HGT - PAD, bw, "Annulla", ZomBotBaseEditor.close, "cancel")
    self:showRect()
end

function ZomBotBaseEditor:fillFloors()
    self.floorsCombo:clear()
    local found = false
    for _, f in ipairs(ZomBotBaseEditor.FLOORS) do
        self.floorsCombo:addOptionWithData(Core.floorsText(f[1], f[2]), f)
        if f[1] == self.floors[1] and f[2] == self.floors[2] then
            self.floorsCombo.selected = #self.floorsCombo.options
            found = true
        end
    end
    if not found then
        self.floorsCombo:addOptionWithData(Core.floorsText(self.floors[1], self.floors[2]), { self.floors[1], self.floors[2] })
        self.floorsCombo.selected = #self.floorsCombo.options
    end
end

function ZomBotBaseEditor:onFloors(combo)
    local f = combo:getOptionData(combo.selected)
    if f then self.floors = { f[1], f[2] } end
end

-- the corners as typed (the entries win over what was drawn: the admin may correct one number)
function ZomBotBaseEditor:readRect()
    local x1, y1 = Core.toInt(self.x1Entry:getText()), Core.toInt(self.y1Entry:getText())
    local x2, y2 = Core.toInt(self.x2Entry:getText()), Core.toInt(self.y2Entry:getText())
    if not (x1 and y1 and x2 and y2) then return nil end
    local a, b, c, d = Core.rect(x1, y1, x2, y2)
    return { x1 = a, y1 = b, x2 = c, y2 = d }
end

function ZomBotBaseEditor:showRect()
    local r = self.rect
    self.x1Entry:setText(r and tostring(r.x1) or "")
    self.y1Entry:setText(r and tostring(r.y1) or "")
    self.x2Entry:setText(r and tostring(r.x2) or "")
    self.y2Entry:setText(r and tostring(r.y2) or "")
end

function ZomBotBaseEditor:applyRect(x1, y1, x2, y2, floors, note)
    local a, b, c, d = Core.rect(x1, y1, x2, y2)
    self.rect = { x1 = a, y1 = b, x2 = c, y2 = d }
    if floors then
        self.floors = floors
        self:fillFloors()
    end
    self:showRect()
    self:setVisible(true)
    self:setStatus(note or string.format("Rettangolo di %d x %d m.", c - a + 1, d - b + 1), false)
end

function ZomBotBaseEditor:onDrawCancelled()
    self:setVisible(true)
    self:setStatus("Disegno annullato.", true)
end

function ZomBotBaseEditor:playerSquare()
    local player = getPlayer()
    if player == nil then return nil end
    return math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
end

function ZomBotBaseEditor:onCornerA()
    local x, y = self:playerSquare()
    if not x then return end
    local r = self:readRect() or { x1 = x, y1 = y, x2 = x, y2 = y }
    self.cornerAPos = { x, y }
    local other = self.cornerBPos or { r.x2, r.y2 }
    self:applyRect(x, y, other[1], other[2], nil, string.format("Angolo A dove sei: %d, %d. Ora vai nell'angolo opposto.", x, y))
end

function ZomBotBaseEditor:onCornerB()
    local x, y = self:playerSquare()
    if not x then return end
    local r = self:readRect() or { x1 = x, y1 = y, x2 = x, y2 = y }
    self.cornerBPos = { x, y }
    local other = self.cornerAPos or { r.x1, r.y1 }
    self:applyRect(other[1], other[2], x, y, nil, string.format("Angolo B dove sei: %d, %d.", x, y))
end

-- the building you stand in (or next to): the game knows its walls
function ZomBotBaseEditor:onHouse()
    local px, py, pz = self:playerSquare()
    if not px then return end
    local best, bestDistance = nil, nil
    for dy = -3, 3 do
        for dx = -3, 3 do
            local square = getCell():getGridSquare(px + dx, py + dy, pz)
            local def = square and square:getBuildingDef()
            local distance = dx * dx + dy * dy
            if def and (bestDistance == nil or distance < bestDistance) then best, bestDistance = def, distance end
        end
    end
    if best == nil then
        self:setStatus("Non sei in un edificio della mappa (le costruzioni dei giocatori non contano): disegnala.", true)
        return
    end
    local floors = nil
    pcall(function()
        local low, high = math.min(best:getMinLevel(), 0), best:getMaxLevel()
        floors = { low, math.max(high, low) }
    end)
    -- BuildingDef: x2 = x + w is the first square outside
    self:applyRect(best:getX(), best:getY(), best:getX() + best:getW() - 1, best:getY() + best:getH() - 1, floors,
        "Presa la casa (muri esterni). Allarga i numeri se vuoi il giardino o il garage.")
end

function ZomBotBaseEditor:onGround()
    self.rect = self:readRect() or self.rect
    self:setVisible(false)
    ZomBotGroundTool.start(self)
end

function ZomBotBaseEditor:onMap()
    self.rect = self:readRect() or self.rect
    self:setVisible(false)
    ZomBotUI.startMapTool(self)
end

function ZomBotBaseEditor:onSave()
    local r = self:readRect()
    if r then r.z1, r.z2 = self.floors[1], self.floors[2] end
    local name = Core.trim(self.nameEntry:getText())
    local problem = Core.baseError(name, r, self.base and self.base.name or nil)
    if problem then
        self:setStatus(problem, true)
        return
    end
    ZomBotUI.awaiting = self
    self:setStatus("Salvo...", false)
    Core.send("saveBase", {
        name = name, old = self.base and self.base.name or nil,
        x1 = r.x1, y1 = r.y1, x2 = r.x2, y2 = r.y2, z1 = r.z1, z2 = r.z2,
    })
end

function ZomBotBaseEditor:onResult(ok, text)
    if ok then
        self:close()
        ZomBotUI.openBases():setStatus(text, false)
    else
        self:setStatus(text, true)
    end
end

function ZomBotBaseEditor:prerender()
    ISCollapsableWindow.prerender(self)
    -- the rectangle, on the ground, while the window is open
    local r = self:readRect()
    local player = getPlayer()
    if r and player and Core.volume({ x1 = r.x1, y1 = r.y1, x2 = r.x2, y2 = r.y2, z1 = 0, z2 = 0 }) <= Core.MAX_SQUARES then
        addAreaHighlightForPlayer(self.playerNum, r.x1, r.y1, r.x2 + 1, r.y2 + 1, math.floor(player:getZ()), GOLD.r, GOLD.g, GOLD.b, 0.35)
    end
end

function ZomBotBaseEditor:render()
    ISCollapsableWindow.render(self)
    self:drawText("Nome della base", PAD, self.nameY + 3, 1, 1, 1, 1, UIFont.Small)
    self:drawText("Il rettangolo deve comprendere tutta la casa:", PAD, self.drawY, 1, 1, 1, 1, UIFont.Small)
    for _, label in ipairs(self.coordLabels) do
        self:drawText(label[1], label[2], self.coordsY + 3, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
    end
    self:drawText("Piani", PAD, self.floorsY + 3, 1, 1, 1, 1, UIFont.Small)
    local r = self:readRect()
    local y = self.infoY
    if r then
        local volume = Core.volume({ x1 = r.x1, y1 = r.y1, x2 = r.x2, y2 = r.y2, z1 = self.floors[1], z2 = self.floors[2] })
        local c = volume > Core.MAX_SQUARES and RED or GREY
        self:drawText(string.format("%d x %d m, %s caselle con i piani (massimo %s). Il giallo sul terreno è la base.",
            r.x2 - r.x1 + 1, r.y2 - r.y1 + 1, Core.amount(volume), Core.amount(Core.MAX_SQUARES)), PAD, y, c.r, c.g, c.b, 1, UIFont.Small)
        for _, other in ipairs(Core.state.bases or {}) do
            if (not self.base or other.id ~= self.base.id) and r.x1 <= other.x2 and other.x1 <= r.x2 and r.y1 <= other.y2 and other.y1 <= r.y2 then
                y = y + FONT_HGT_SMALL
                self:drawText("Si sovrappone a '" .. other.name .. "': gli oggetti in comune contano per tutte e due.", PAD, y, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Small)
                break
            end
        end
    else
        self:drawText("Nessun rettangolo ancora: usa uno dei pulsanti qui sopra.", PAD, y, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
    end
    self:drawStatus(y + FONT_HGT_SMALL + PAD)
end

function ZomBotUI.openEditor(base)
    return ZomBotUI.show(ZomBotBaseEditor, 560, 420, base)
end

-- -- drawing on the ground: hold the left button and drag (as the game's own animal zones) -----------------------
ZomBotGroundTool = ISPanel:derive("ZomBotGroundTool")

function ZomBotGroundTool.start(editor)
    local width = 520
    local tool = ZomBotGroundTool:new((getCore():getScreenWidth() - width) / 2, 60, width, FONT_HGT_MEDIUM + FONT_HGT_SMALL * 3 + BUTTON_HGT + PAD * 5)
    tool.editor = editor
    tool:initialise()
    tool:addToUIManager()
    ZomBotUI.groundTool = tool
end

function ZomBotGroundTool:new(x, y, width, height)
    local o = ISPanel.new(self, x, y, width, height)
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.82 }
    o.borderColor = { r = GOLD.r, g = GOLD.g, b = GOLD.b, a = 1 }
    o.player = getPlayer()
    o.playerNum = o.player and o.player:getPlayerNum() or 0
    o.moveWithMouse = true
    return o
end

function ZomBotGroundTool:createChildren()
    ISPanel.createChildren(self)
    self.cancel = UI.button(self, self.width - 150 - PAD, self.height - BUTTON_HGT - PAD, 150, "Annulla", ZomBotGroundTool.onCancel, "cancel")
end

function ZomBotGroundTool:pick(screenX, screenY)
    local z = math.floor(self.player:getZ())
    return math.floor(screenToIsoX(self.playerNum, screenX, screenY, z)), math.floor(screenToIsoY(self.playerNum, screenX, screenY, z)), z
end

function ZomBotGroundTool:onMouseDownOutside(x, y)
    if self.startX then return end
    self.startX, self.startY = self:pick(x + self:getAbsoluteX(), y + self:getAbsoluteY())
    self.endX, self.endY = self.startX, self.startY
    ISWorldObjectContextMenu.disableWorldMenu = true
end

function ZomBotGroundTool:onMouseMoveOutside(dx, dy)
    if not self.startX then return end
    self.endX, self.endY = self:pick(getMouseX(), getMouseY())
end

function ZomBotGroundTool:onMouseUpOutside(x, y)
    if not self.startX then return end
    self.endX, self.endY = self:pick(getMouseX(), getMouseY())
    local editor = self.editor
    local x1, y1, x2, y2 = self.startX, self.startY, self.endX, self.endY
    self:finish()
    editor:applyRect(x1, y1, x2, y2)
end

function ZomBotGroundTool:onCancel()
    local editor = self.editor
    self:finish()
    editor:onDrawCancelled()
end

function ZomBotGroundTool:finish()
    ISWorldObjectContextMenu.disableWorldMenu = false
    self:setVisible(false)
    self:removeFromUIManager()
    ZomBotUI.groundTool = nil
end

function ZomBotGroundTool:prerender()
    ISPanel.prerender(self)
    local y = PAD
    self:drawText("Disegna la base sul terreno", PAD, y, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Medium)
    y = y + FONT_HGT_MEDIUM + 4
    self:drawText("Tieni premuto il tasto sinistro in un angolo e trascina fino a quello opposto.", PAD, y, 1, 1, 1, 1, UIFont.Small)
    y = y + FONT_HGT_SMALL
    self:drawText("Si disegna al piano dove sei; i piani della base li scegli dopo.", PAD, y, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
    y = y + FONT_HGT_SMALL
    local mouseX, mouseY, z = self:pick(getMouseX(), getMouseY())
    if self.startX then
        local x1, y1, x2, y2 = Core.rect(self.startX, self.startY, self.endX, self.endY)
        self:drawText(string.format("%d x %d m", x2 - x1 + 1, y2 - y1 + 1), PAD, y, GREEN.r, GREEN.g, GREEN.b, 1, UIFont.Small)
        addAreaHighlightForPlayer(self.playerNum, x1, y1, x2 + 1, y2 + 1, z, GOLD.r, GOLD.g, GOLD.b, 0.5)
    else
        self:drawText(string.format("Casella: %d, %d", mouseX, mouseY), PAD, y, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
        addAreaHighlightForPlayer(self.playerNum, mouseX, mouseY, mouseX + 1, mouseY + 1, z, GOLD.r, GOLD.g, GOLD.b, 0.9)
    end
end

-- -- drawing on the world map: a map tool, like the game's symbol tools ----------------------------------------
function ZomBotUI.mapToolClass()
    if ZomBotMapTool then return ZomBotMapTool end
    ZomBotMapTool = ISWorldMapSymbolTool:derive("ZomBotMapTool")

    function ZomBotMapTool:new(symbolsUI, editor)
        local o = ISWorldMapSymbolTool.new(self, symbolsUI)
        o.editor = editor
        return o
    end

    function ZomBotMapTool:worldAt(x, y)
        return math.floor(self.mapAPI:uiToWorldX(x, y)), math.floor(self.mapAPI:uiToWorldY(x, y))
    end

    function ZomBotMapTool:onMouseDown(x, y)
        self.startX, self.startY = self:worldAt(x, y)
        self.endX, self.endY = self.startX, self.startY
        self.drawing = true
        return true
    end

    function ZomBotMapTool:onMouseMove(dx, dy)
        if not self.drawing then return false end
        self.endX, self.endY = self:worldAt(self:getMouseX(), self:getMouseY())
        return true
    end

    function ZomBotMapTool:onMouseUp(x, y)
        if not self.drawing then return false end
        self.drawing = false
        self.endX, self.endY = self:worldAt(x, y)
        self.finished = true
        local editor = self.editor
        local x1, y1, x2, y2 = self.startX, self.startY, self.endX, self.endY
        self.symbolsUI:setCurrentTool(nil)
        if ISWorldMap_instance then ISWorldMap_instance:close() end
        editor:applyRect(x1, y1, x2, y2)
        return true
    end

    function ZomBotMapTool:deactivate()
        if not self.finished then
            self.finished = true
            self.editor:onDrawCancelled()
        end
    end

    function ZomBotMapTool:render()
        local text = "ZomBOT: tieni premuto e trascina per disegnare la base. Esc per annullare."
        self.mapUI:drawRect(0, 0, UI.textWidth(text, UIFont.Medium) + PAD * 2, FONT_HGT_MEDIUM + PAD, 0.75, 0, 0, 0)
        self.mapUI:drawText(text, PAD, PAD / 2, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Medium)
        if self.startX then
            local x1, y1, x2, y2 = Core.rect(self.startX, self.startY, self.endX, self.endY)
            ZomBotUI.drawMapRect(self.mapUI, x1, y1, x2 + 1, y2 + 1, GOLD, 3)
            self.mapUI:drawText(string.format("%d x %d m", x2 - x1 + 1, y2 - y1 + 1), self:getMouseX() + 16, self:getMouseY(), 1, 1, 1, 1, UIFont.Small)
        end
    end

    return ZomBotMapTool
end

-- a world rectangle on the map (isometric by default: four corners, four lines, as the zone editor does)
function ZomBotUI.drawMapRect(map, x1, y1, x2, y2, colour, thick)
    local api = map.mapAPI
    local points = { { x1, y1 }, { x2, y1 }, { x2, y2 }, { x1, y2 } }
    local ui = {}
    for i, p in ipairs(points) do ui[i] = { api:worldToUIX(p[1], p[2]), api:worldToUIY(p[1], p[2]) } end
    for i = 1, 4 do
        local a, b = ui[i], ui[i % 4 + 1]
        map.javaObject:DrawLine(Texture:getWhite(), a[1], a[2], b[1], b[2], thick or 1, colour.r, colour.g, colour.b, 1)
    end
    return ui
end

function ZomBotUI.startMapTool(editor)
    local player = getPlayer()
    local r = editor.rect
    local cx = r and (r.x1 + r.x2) / 2 or (player and player:getX())
    local cy = r and (r.y1 + r.y2) / 2 or (player and player:getY())
    ISWorldMap.ShowWorldMap(editor.playerNum, cx, cy, 19.0)
    local map = ISWorldMap_instance
    if not map or not map:isVisible() then
        editor:setVisible(true)
        editor:setStatus("La mappa del mondo non è disponibile su questo server.", true)
        return
    end
    map.symbolsUI:setCurrentTool(ZomBotUI.mapToolClass():new(map.symbolsUI, editor))
end

-- the bases, on the admin's world map (in grey, with their names)
function ZomBotUI.drawBasesOnMap(map)
    if not ZomBotUI.showOnMap or not Core.isAdmin() then return end
    for _, base in ipairs(Core.state.bases or {}) do
        local ui = ZomBotUI.drawMapRect(map, base.x1, base.y1, base.x2 + 1, base.y2 + 1, GOLD, 2)
        map:drawText(base.name, ui[1][1] + 4, ui[1][2] + 2, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Small)
    end
end
ZomBotUI.showOnMap = true

-- -- the three thresholds of an item or a liquid -----------------------------------------------------------------
ZomBotStockWindow = ZomBotWindow:derive("ZomBotStockWindow")

function ZomBotStockWindow:new(x, y, width, height, baseName, key, label, texture)
    local o = ZomBotWindow.new(self, x, y, width, height, "ZomBOT  -  Scorta")
    o.baseName, o.key, o.label, o.texture = baseName, key, label, texture
    o.litres = string.sub(key, 1, 8) == "liquido:"
    o.food = key == Core.FOOD
    o.rule = Core.ruleOf(Core.findBase(baseName), key)
    return o
end

ZomBotStockWindow.ROWS = {
    { field = "critical", level = "critical", text = "Critico: fino a quanti (compreso)" },
    { field = "scarce", level = "scarce", text = "Scarseggia: fino a quanti" },
    { field = "good", level = "good", text = "Buono: da quanti in su" },
}

function ZomBotStockWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local y = self:top() + 48 + PAD + FONT_HGT_SMALL * 2 + PAD
    self.rowsY = y
    local defaults = self.litres and { 5, 20, 50 } or (self.food and { 20, 50, 100 } or { 0, 10, 30 })
    local values = self.rule and { self.rule.critical, self.rule.scarce, self.rule.good } or defaults
    self.entries = {}
    for i, row in ipairs(ZomBotStockWindow.ROWS) do
        self.entries[row.field] = UI.entry(self, self.width - PAD - 110, y, 110, values[i], true)
        y = y + BUTTON_HGT + PAD / 2
    end
    self.helpY = y + PAD / 2
    local bw = (self.width - PAD * 4) / 3
    local by = self.height - BUTTON_HGT - PAD
    self.saveButton = UI.button(self, PAD, by, bw, self.rule and "Salva" or "Aggiungi a scorta", ZomBotStockWindow.onSave, "accept")
    self.removeButton = UI.button(self, PAD * 2 + bw, by, bw, "Smetti di tracciare", ZomBotStockWindow.onRemove, "cancel")
    self.removeButton:setVisible(self.rule ~= nil)
    self.cancelButton = UI.button(self, PAD * 3 + bw * 2, by, bw, "Annulla", ZomBotStockWindow.close)
    Core.send("info", { base = self.baseName, key = self.key }, function(info) self.info = info end)
end

function ZomBotStockWindow:numbers()
    return Core.toInt(self.entries.critical:getText()), Core.toInt(self.entries.scarce:getText()), Core.toInt(self.entries.good:getText())
end

function ZomBotStockWindow:render()
    ISCollapsableWindow.render(self)
    local y = self:top()
    if self.texture then self:drawTextureScaledAspect(self.texture, PAD, y, 48, 48, 1, 1, 1, 1) end
    local x = PAD + (self.texture and 48 + PAD or 0)
    self:drawText(self.label, x, y + 2, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Medium)
    self:drawText("Base '" .. self.baseName .. "'", x, y + 4 + FONT_HGT_MEDIUM, 0.85, 0.85, 0.85, 1, UIFont.Small)
    y = y + 48 + PAD
    -- how much there is now, and in which band the typed thresholds put it
    local unit = self.litres and " L" or (self.food and " porzioni" or "")
    if self.info == nil then
        self:drawText("Conto quanto ce n'è adesso nella base...", PAD, y, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
    elseif self.info.error then
        self:drawText("Non riesco a contare adesso: " .. tostring(self.info.error), PAD, y, RED.r, RED.g, RED.b, 1, UIFont.Small)
    else
        local have = self.info.have or 0
        local text = "Adesso nella base: " .. (self.litres and string.format("%.1f", have) or Core.amount(have)) .. unit
        local extra = {}
        local packed = self.food and " in scatolette e barattoli chiusi" or " ancora in scatole o pacchi"
        if (self.info.packed or 0) > 0 then table.insert(extra, Core.amount(self.info.packed) .. packed) end
        if (self.info.loadedAmmo or 0) > 0 then table.insert(extra, Core.amount(self.info.loadedAmmo) .. " nei caricatori") end
        if (self.info.spoiled or 0) > 0 then table.insert(extra, Core.amount(self.info.spoiled) .. " marci esclusi") end
        if #extra > 0 then text = text .. " (" .. table.concat(extra, ", ") .. ")" end
        self:drawText(text, PAD, y, 1, 1, 1, 1, UIFont.Small)
        local critical, scarce, good = self:numbers()
        if not Core.thresholdError(critical, scarce, good) then
            local level = Core.LEVELS[Core.level(have, { critical = critical, scarce = scarce, good = good })]
            self:drawText("Con queste soglie: " .. level.label, PAD, y + FONT_HGT_SMALL, level.r, level.g, level.b, 1, UIFont.Small)
        end
        if (self.info.loaded or 0) < (self.info.squares or 0) then
            self:drawText("Una parte della base non è in memoria: il numero può essere più basso.", PAD, y + FONT_HGT_SMALL * 2,
                GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Small)
        end
    end
    -- the three rows, each with its colour
    y = self.rowsY
    for _, row in ipairs(ZomBotStockWindow.ROWS) do
        local level = Core.LEVELS[row.level]
        self:drawRect(PAD, y + 3, 14, BUTTON_HGT - 6, 1, level.r, level.g, level.b)
        self:drawText(row.text .. unit, PAD + 22, y + 3, 1, 1, 1, 1, UIFont.Small)
        y = y + BUTTON_HGT + PAD / 2
    end
    local fair = Core.LEVELS.fair
    self:drawRect(PAD, self.helpY + 3, 14, FONT_HGT_SMALL - 4, 1, fair.r, fair.g, fair.b)
    self:drawText("Fra 'scarseggia' e 'buono' è sufficiente.", PAD + 22, self.helpY, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
    local how = self.food and "Una porzione: 25 di fame, circa un pasto. Cibi marci esclusi."
        or "Scatole, pacchi e caricatori contano per ciò che contengono."
    self:drawText(how, PAD + 22, self.helpY + FONT_HGT_SMALL, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
    self:drawStatus(self.helpY + FONT_HGT_SMALL * 2 + PAD / 2)
end

function ZomBotStockWindow:onSave()
    local critical, scarce, good = self:numbers()
    local problem = Core.thresholdError(critical, scarce, good)
    if problem then
        self:setStatus(problem, true)
        return
    end
    ZomBotUI.awaiting = self
    self:setStatus("Salvo...", false)
    Core.send("setRule", { base = self.baseName, key = self.key, critical = critical, scarce = scarce, good = good })
end

function ZomBotStockWindow:onRemove()
    ZomBotUI.awaiting = self
    Core.send("removeRule", { base = self.baseName, key = self.key })
end

function ZomBotStockWindow:onResult(ok, text)
    if ok then self:close() else self:setStatus(text, true) end
end

function ZomBotUI.openStock(_, baseName, key, label, texture)
    return ZomBotUI.show(ZomBotStockWindow, 470, 400, baseName, key, label, texture)
end

-- -- skill books and recipe magazines: which ones, and how many copies of each ------------------------------------
ZomBotSetWindow = ZomBotWindow:derive("ZomBotSetWindow")

function ZomBotSetWindow:new(x, y, width, height, baseName, kind, group)
    local books = kind == "books"
    local o = ZomBotWindow.new(self, x, y, width, height, books and "ZomBOT  -  Libri delle abilità" or "ZomBOT  -  Riviste di ricette")
    o.baseName, o.kind, o.group = baseName, kind, group
    o.prefix = books and "libri" or "riviste"
    local data = ZomBotData or {}
    o.groupLabel = group and ((books and data.skills or data.series) or {})[group] or nil
    return o
end

function ZomBotSetWindow:keys()
    local keys = {}
    if self.group then
        local label = self.kind == "books" and ("Solo i libri di " .. self.groupLabel) or ("Solo le riviste di " .. self.groupLabel)
        table.insert(keys, { self.prefix .. ":" .. self.group, label })
    end
    table.insert(keys, { self.prefix, self.kind == "books" and "Tutti i libri delle abilità (24 x 5 volumi)" or "Tutte le riviste di ricette" })
    return keys
end

function ZomBotSetWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local y = self:top() + FONT_HGT_MEDIUM + PAD + FONT_HGT_SMALL * 2 + PAD
    self.combo = ISComboBox:new(PAD, y, self.width - PAD * 2, BUTTON_HGT, self, ZomBotSetWindow.onChoice)
    self.combo:initialise()
    self:addChild(self.combo)
    for _, k in ipairs(self:keys()) do self.combo:addOptionWithData(k[2], k[1]) end
    self.combo.selected = 1
    y = y + BUTTON_HGT + PAD
    self.copiesY = y
    self.copiesEntry = UI.entry(self, self.width - PAD - 80, y, 80, "1", true)
    y = y + BUTTON_HGT + PAD
    self.infoY = y
    local bw = (self.width - PAD * 4) / 3
    local by = self.height - BUTTON_HGT - PAD
    self.saveButton = UI.button(self, PAD, by, bw, "Controlla", ZomBotSetWindow.onSave, "accept")
    self.removeButton = UI.button(self, PAD * 2 + bw, by, bw, "Smetti di tracciare", ZomBotSetWindow.onRemove, "cancel")
    self.cancelButton = UI.button(self, PAD * 3 + bw * 2, by, bw, "Annulla", ZomBotSetWindow.close)
    self:onChoice()
end

function ZomBotSetWindow:key()
    return self.combo:getOptionData(self.combo.selected)
end

function ZomBotSetWindow:onChoice()
    local key = self:key()
    local rule = Core.ruleOf(Core.findBase(self.baseName), key)
    self.copiesEntry:setText(tostring(rule and rule.good or 1))
    self.removeButton:setVisible(rule ~= nil)
    self.saveButton:setTitle(rule and "Salva" or "Controlla")
    self.info = nil
    Core.send("info", { base = self.baseName, key = key }, function(info)
        if info.key == self:key() then self.info = info end
    end)
end

function ZomBotSetWindow:render()
    ISCollapsableWindow.render(self)
    local y = self:top()
    self:drawText(self.kind == "books" and "Libri delle abilità" or "Riviste che insegnano ricette", PAD, y, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Medium)
    y = y + FONT_HGT_MEDIUM + 4
    self:drawText("Base '" .. self.baseName .. "'. ZomBOT dirà su Discord quali mancano.", PAD, y, 0.85, 0.85, 0.85, 1, UIFont.Small)
    self:drawText(self.kind == "books" and "Un volume manca se ce ne sono meno copie di quante ne vuoi." or "Una rivista manca se ce ne sono meno copie di quante ne vuoi.",
        PAD, y + FONT_HGT_SMALL, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
    self:drawText(self.kind == "books" and "Copie di ogni volume" or "Copie di ogni rivista", PAD, self.copiesY + 3, 1, 1, 1, 1, UIFont.Small)
    if self.info == nil then
        self:drawText("Conto cosa c'è adesso nella base...", PAD, self.infoY, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
    elseif self.info.error then
        self:drawText("Non riesco a contare adesso: " .. tostring(self.info.error), PAD, self.infoY, RED.r, RED.g, RED.b, 1, UIFont.Small)
    else
        local c = (self.info.missing or 0) > 0 and Core.LEVELS.scarce or Core.LEVELS.good
        local text = (self.info.missing or 0) == 0 and string.format("Adesso ci sono tutti e %d.", self.info.total or 0)
            or string.format("Adesso ne mancano %d su %d.", self.info.missing, self.info.total or 0)
        self:drawText(text, PAD, self.infoY, c.r, c.g, c.b, 1, UIFont.Small)
    end
    self:drawStatus(self.infoY + FONT_HGT_SMALL + PAD / 2)
end

function ZomBotSetWindow:onSave()
    local copies = Core.toInt(self.copiesEntry:getText())
    if not copies or copies < 1 or copies > 20 then
        self:setStatus("Copie da 1 a 20.", true)
        return
    end
    ZomBotUI.awaiting = self
    Core.send("setRule", { base = self.baseName, key = self:key(), good = copies })
end

function ZomBotSetWindow:onRemove()
    ZomBotUI.awaiting = self
    Core.send("removeRule", { base = self.baseName, key = self:key() })
end

function ZomBotSetWindow:onResult(ok, text)
    if ok then self:close() else self:setStatus(text, true) end
end

function ZomBotUI.openSet(_, baseName, kind, group)
    return ZomBotUI.show(ZomBotSetWindow, 480, 280, baseName, kind, group)
end

-- -- right click ------------------------------------------------------------------------------------------------
local function firstItem(items)
    for _, entry in ipairs(items or {}) do
        if instanceof(entry, "InventoryItem") then return entry end
        if type(entry) == "table" and entry.items and entry.items[1] then return entry.items[1] end
    end
    return nil
end

local function fluidOf(thing)
    local ok, fluid = pcall(function()
        local container = thing:getFluidContainer()
        if container == nil or container:isEmpty() then return nil end
        return container:getPrimaryFluid():getFluidTypeString()
    end)
    return ok and fluid or nil
end

function ZomBotUI.baseOfPlayer(player)
    if player == nil then return nil end
    return Core.baseAt(math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()))
end

local function addFluidOption(context, base, fluid)
    local key = "liquido:" .. fluid
    local label = Core.fluidLabel(fluid) .. " (litri)"
    local rule = Core.ruleOf(base, key)
    context:addOption((rule and "Scorta: " or "Aggiungi a scorta: ") .. label .. "  [" .. base.name .. "]", nil,
        ZomBotUI.openStock, base.name, key, label, nil)
end

-- the name and icon of an item nobody is holding (the single cigarette of a pack)
local function itemInfo(fullType)
    local name, texture = fullType, nil
    pcall(function() name = getItemNameFromFullType(fullType) or fullType end)
    pcall(function() texture = getItemTex(fullType) end)
    return name, texture
end

-- one entry of the stock menu: add it, or (already watched) change the thresholds or remove it
local function addStockEntry(menu, base, key, name, texture, addText, watchedText)
    if Core.ruleOf(base, key) then
        local option = menu:addOption("Scorta: " .. watchedText)
        local sub = ISContextMenu:getNew(menu)
        menu:addSubMenu(option, sub)
        sub:addOption("Modifica le soglie...", nil, ZomBotUI.openStock, base.name, key, name, texture)
        sub:addOption("Smetti di tracciare", nil, ZomBotUI.removeRule, base.name, key)
        return option
    end
    local option = menu:addOption(addText, nil, ZomBotUI.openStock, base.name, key, name, texture)
    pcall(function() option.iconTexture = texture end)
    return option
end

function ZomBotUI.onInventoryMenu(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    if not Core.isAdmin(player) then return end
    local base = ZomBotUI.baseOfPlayer(player)
    local item = firstItem(items)
    if base == nil or item == nil then return end
    local fullType = item:getFullType()
    local what = Core.describe(fullType)
    local tag = "  [" .. base.name .. "]"
    if what.kind == "book" or what.kind == "set" then
        context:addOption("Controlla i libri" .. tag, nil, ZomBotUI.openSet, base.name, "books", what.skill)
    elseif what.kind == "magazine" then
        context:addOption("Controlla le riviste" .. tag, nil, ZomBotUI.openSet, base.name, "magazines", what.series)
    elseif Core.isFood(fullType) then
        -- all the food is one check: an apple, a can, a box of cans all go to «Alimenti»
        addStockEntry(context, base, Core.FOOD, Core.FOOD_LABEL, item:getTex(), "Aggiungi a scorta: Alimenti" .. tag,
            "Alimenti" .. tag)
    else
        local name = item:getDisplayName()
        local texture = item:getTex()
        -- every item is tracked in its single unit: a pack (cigarettes, a box of screws) is tracked as what it
        -- holds, and the packs count for what is inside them
        local leaves = Core.leaves(fullType)
        if #leaves == 0 then
            addStockEntry(context, base, fullType, Core.unitLabel(fullType, name), texture, "Aggiungi a scorta" .. tag, name .. tag)
        elseif #leaves == 1 then
            local unitName, unitTexture = itemInfo(leaves[1])
            addStockEntry(context, base, leaves[1], Core.unitLabel(leaves[1], unitName), unitTexture,
                "Aggiungi a scorta" .. tag, unitName .. tag)
        else
            -- a box of several things (jars and lids): each is tracked on its own
            local option = context:addOption("Aggiungi a scorta" .. tag)
            local sub = ISContextMenu:getNew(context)
            context:addSubMenu(option, sub)
            for _, leaf in ipairs(leaves) do
                local unitName, unitTexture = itemInfo(leaf)
                addStockEntry(sub, base, leaf, Core.unitLabel(leaf, unitName), unitTexture, unitName, unitName)
            end
        end
    end
    local fluid = fluidOf(item)
    if fluid then addFluidOption(context, base, fluid) end
end

function ZomBotUI.removeRule(_, baseName, key)
    Core.send("removeRule", { base = baseName, key = key })
end

function ZomBotUI.onWorldMenu(playerNum, context, worldobjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end
    local player = getSpecificPlayer(playerNum)
    if not Core.isAdmin(player) then return end
    context:addOption("ZomBOT: basi...", nil, ZomBotUI.openBases)
    local base = ZomBotUI.baseOfPlayer(player)
    if base == nil then return end
    local tag = "  [" .. base.name .. "]"
    context:addOption("ZomBOT: scorte di questa base" .. tag, nil, ZomBotUI.openRules, base.name)
    -- the skill books and the recipe magazines, without having one in hand
    local books = Core.ruleOf(base, "libri") and "Libri delle abilità: modifica" or "Controlla i libri delle abilità"
    context:addOption("ZomBOT: " .. books .. tag, nil, ZomBotUI.openSet, base.name, "books", nil)
    local magazines = Core.ruleOf(base, "riviste") and "Riviste di ricette: modifica" or "Controlla le riviste di ricette"
    context:addOption("ZomBOT: " .. magazines .. tag, nil, ZomBotUI.openSet, base.name, "magazines", nil)
    -- a rain barrel or anything else holding a liquid, inside the base
    local seen = {}
    for _, object in ipairs(worldobjects or {}) do
        local fluid = fluidOf(object)
        if fluid and not seen[fluid] then
            seen[fluid] = true
            addFluidOption(context, base, fluid)
        end
    end
end

-- -- under the item's tooltip: where it is short --------------------------------------------------------------------
function ZomBotUI.drawShortages(tip)
    if tip.item == nil or (ISContextMenu.instance and ISContextMenu.instance.visibleCheck) then return end
    if not Core.isAdmin() then return end
    local lines = Core.shortages(tip.item:getFullType(), fluidOf(tip.item))
    if #lines == 0 then return end
    local title = "ZomBOT - scorte"
    local width = UI.textWidth(title)
    for _, line in ipairs(lines) do width = math.max(width, UI.textWidth(line.text)) end
    width = math.max(width + PAD * 2, tip.width)
    local height = FONT_HGT_SMALL * (#lines + 1) + PAD
    -- below the game's tooltip, or above it near the bottom of the screen
    local y = tip.height
    if tip:getAbsoluteY() + tip.height + height > getCore():getScreenHeight() then y = -height end
    tip:drawRect(0, y, width, height, 0.88, 0.07, 0.07, 0.07)
    tip:drawRectBorder(0, y, width, height, 1, GOLD.r, GOLD.g, GOLD.b)
    tip:drawText(title, PAD, y + PAD / 2, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Small)
    for i, line in ipairs(lines) do
        local c = Core.LEVELS[line.level]
        tip:drawText(line.text, PAD, y + PAD / 2 + FONT_HGT_SMALL * i, c.r, c.g, c.b, 1, UIFont.Small)
    end
end

-- -- start --------------------------------------------------------------------------------------------------------
local lastState = 0

local function keepState()
    -- the bases change from other admins too: ask again every two minutes (and at once, the first time)
    local now = getTimestampMs()
    if now - lastState < 120000 then return end
    lastState = now
    if Core.isAdmin() then Core.send("state") end
end

local function onGameStart()
    if ISToolTipInv and not ZomBotUI.tooltipWrapped then
        ZomBotUI.tooltipWrapped = true
        local render = ISToolTipInv.render
        function ISToolTipInv:render()
            render(self)
            pcall(ZomBotUI.drawShortages, self)
        end
    end
    if ISWorldMap and not ZomBotUI.mapWrapped then
        ZomBotUI.mapWrapped = true
        local prerender = ISWorldMap.prerender
        function ISWorldMap:prerender()
            prerender(self)
            pcall(ZomBotUI.drawBasesOnMap, self)
        end
    end
end

Events.OnServerCommand.Add(Core.onServerCommand)
Events.OnFillInventoryObjectContextMenu.Add(ZomBotUI.onInventoryMenu)
Events.OnFillWorldObjectContextMenu.Add(ZomBotUI.onWorldMenu)
Events.OnGameStart.Add(onGameStart)
Events.OnTick.Add(keepState)
