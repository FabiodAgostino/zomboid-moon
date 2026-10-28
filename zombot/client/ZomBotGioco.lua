-- ZomBotGioco: the players' «ZomBOT» mod for Moon (28/10/2026). Client only: with client/ZomBotMenu.lua (the one
-- «ZomBOT» entry of the right click, the same file Admin-Scorte ships) it is the whole mod, copied by each player into
-- their own game with the installer. Optional: the server runs with DoLuaChecksum=false and a player without it
-- joins as before. The server's half is server/ZomBotGiocoServer.lua (module "ZomBotGioco"), which checks everything
-- again: nothing here gives anyone a power.
--
-- What it adds:
--   questions from the chat: a line that starts with «zombot» (any case, «@ZomBOT», «zombot,» or «zombot:», after
--     /all, /say... too) still goes to the chat as always, and the words after the name go to the server as a
--     question for the bot (one every 10 s, 30 an hour, here and there). «ZomBOT ci pensa...» right away; the answer
--     arrives as ZomBOT's lines in this player's own chat window, seen by nobody else;
--   the container that holds what was asked for blinks for 60 s when the asker is inside a base, until clicked or
--     opened (or until another one starts blinking);
--   coloured crates: any player picks a colour from the «ZomBOT» right click on a crate (the user, 28/10/2026: not
--     only the admins), the server keeps it in the object's modData (zombotColor) and tells everyone; the colour is
--     the same for the whole server, seen by all the players with this mod, each painting it on their own screen;
--     «Colora le casse» turns it off for oneself (Zomboid/Lua/zombot_gioco.txt on this computer);
--   the «ZomBOT» window (ZomBotMenu main «zombot», order 20, for everyone): how to ask, the last answers, the
--     colouring switch and the buttons other mods add (ZomBotMenu extras). An admin with Admin-Scorte gets that mod's
--     bases window instead (order 10), where two extras of this file reach everything: the switch and this window.
--
-- Verified in 42.21 (the game's Lua in media/lua and projectzomboid.jar with javap):
--   the chat: ISChat.onCommandEntered reads ISChat.instance.textEntry:getText(), strips the stream prefixes of
--     ISChat.allChatStreams (/all, /say, /s, /yell, /y, /whisper, /w, /faction, /f, /safehouse, /sh, /admin, /a),
--     refuses a stream of another tab and the slow mode (timerMessageSlowMode, Capability.IgnoreChatSlowMode);
--     ISChat:createChildren gives the entry box that function (textEntry.onCommandEntered), so both are wrapped.
--     ISChat.addLineInChat(message, tabID) is Lua and only calls message:getTextWithPrefix() / getAuthor() (and
--     setText for a muted author); updateChatPrefixSettings calls getTextWithPrefix() again: a Lua table with those
--     methods is a local line, never sent. Lines are rich text (<RGB:r,g,b>, <SIZE:small|medium|large>, as
--     ChatBase.getMessagePrefix makes them) with < and > as &lt; &gt; (ChatMessage.getTextWithReplacedParentheses);
--     tab.tabID is the game's zero-based id, chatText the visible tab;
--   the tint: IsoObject.setCustomColor multiplies the object's colour when drawn (IsoObject.prepareToRender) and is
--     sent to others only by transmitCustomColorToClients, which does nothing outside the server: set here it stays
--     on this screen. The object is made again from the server's data whenever its square loads, so the tint is put
--     back on LoadGridsquare (fired on clients too: WorldStreamer.DoChunkAlways -> IsoChunk.doLoadGridsquare), only
--     for objects with our modData key (IsoObject.hasModData first: getModData would create a table on every one);
--   the blink: setHighlighted(playerIndex, on, false) with setHighlightColor(playerIndex, r, g, b, a), as the loot
--     window highlights the open container; ISInventoryPage.OnObjectHighlighted(playerNum, object, true) tells the
--     loot window to leave it alone meanwhile. The open container: getPlayerLoot(playerNum).inventory (its
--     getParent() is the object), not collapsed. A click: Events.OnObjectLeftMouseButtonDown(object, x, y), fired by
--     UIManager with the object under the mouse;
--   getFileReader(name, false) is nil when the file is missing, getFileWriter(name, true, false) rewrites it, both in
--     Zomboid/Lua of this computer.
if isServer() and not isClient() then return end

ZomBotGioco = ZomBotGioco or {}
local G = ZomBotGioco

G.MODULE = "ZomBotGioco"
G.SETTINGS = "zombot_gioco.txt"
G.KEY = "zombotColor"
G.MIN_TEXT, G.MAX_TEXT = 3, 300
G.GAP_MS = 10000 -- between two questions, as the server
G.PER_HOUR = 30
G.BLINK_MS = 60000
G.BLINK_STEP_MS = 400
G.KEEP_ANSWERS = 8
G.HOW_TO = "Scrivi in chat: zombot dove trovo le asce?"
G.BLINK_RGBA = { 1.0, 0.92, 0.15, 0.9 }

-- readable on wood and metal; the ids are what the server keeps
G.PALETTE = {
    { id = "red", label = "Rosso", r = 1.00, g = 0.32, b = 0.30 },
    { id = "orange", label = "Arancione", r = 1.00, g = 0.62, b = 0.22 },
    { id = "yellow", label = "Giallo", r = 1.00, g = 0.92, b = 0.30 },
    { id = "green", label = "Verde", r = 0.42, g = 0.90, b = 0.42 },
    { id = "cyan", label = "Azzurro", r = 0.38, g = 0.88, b = 1.00 },
    { id = "blue", label = "Blu", r = 0.42, g = 0.55, b = 1.00 },
    { id = "purple", label = "Viola", r = 0.75, g = 0.48, b = 1.00 },
    { id = "pink", label = "Rosa", r = 1.00, g = 0.55, b = 0.82 },
}

G.answers = G.answers or {} -- newest first: {question, text}
G.known = G.known or {} -- coloured objects seen: "x,y,z" -> {x, y, z, objects = {[index] = {color, original}}}
G.pending = G.pending or {} -- question id -> its words
G.asked = G.asked or {} -- getTimestampMs() of the questions sent in the last hour

-- Spaces and control characters spelled out, never %s or %c: in a C Lua those follow the locale and can split the
-- bytes of «à» (the tests run in one); the game's Lua (Kahlua) works on whole characters.
local CONTROL = "[" .. string.char(1) .. "-" .. string.char(31) .. string.char(127) .. "]"

local function trim(text)
    text = string.gsub(tostring(text or ""), CONTROL, " ")
    text = string.gsub(text, " +", " ")
    text = string.gsub(text, "^ ", "")
    return (string.gsub(text, " $", ""))
end

local function starts(text, prefix)
    return prefix ~= nil and string.sub(text, 1, #prefix) == prefix
end

local function playerNum()
    local ok, n = pcall(function() return getPlayer():getPlayerNum() end)
    return ok and n or 0
end

-- -- the setting on this computer ----------------------------------------------------------------------------------
function G.loadSettings()
    G.settings = { colors = true }
    pcall(function()
        local reader = getFileReader(G.SETTINGS, false)
        if reader == nil then return end
        local line = reader:readLine()
        while line do
            local key, value = string.match(line, "^ *([%w_]+) *= *([%w_]*)")
            if key == "colori" then G.settings.colors = value ~= "0" end
            line = reader:readLine()
        end
        reader:close()
    end)
    return G.settings
end

function G.setting()
    return G.settings or G.loadSettings()
end

function G.saveSettings()
    local ok, err = pcall(function()
        local writer = getFileWriter(G.SETTINGS, true, false)
        writer:write("colori=" .. (G.setting().colors and "1" or "0") .. "\n")
        writer:close()
    end)
    if not ok then print("ZomBotGioco: cannot save " .. G.SETTINGS .. ": " .. tostring(err)) end
end

-- -- ZomBOT's lines in this player's chat --------------------------------------------------------------------------
local GOLD = { r = 0.94, g = 0.70, b = 0.20 }
local GOLD_TAG = "<RGB:0.94,0.70,0.20>"

-- how = nil: «ZomBOT: text»; "note": «ZomBOT text» in grey («ZomBOT ci pensa...»); "more": a further line of an answer
function G.lineText(text, how)
    local font = "medium"
    pcall(function() font = ISChat.instance.chatFont or font end)
    local safe = string.gsub(tostring(text or ""), "<", "&lt;")
    safe = string.gsub(safe, ">", "&gt;")
    local head = how == "note" and "ZomBOT" or (how == "more" and "" or "ZomBOT:")
    local colour = how == "note" and "<RGB:0.75,0.75,0.75>" or "<RGB:1,1,1>"
    return GOLD_TAG .. " <SIZE:" .. tostring(font) .. "> " .. head .. " " .. colour .. " " .. safe
end

-- a chat message that exists only here: what ISChat.addLineInChat and updateChatPrefixSettings call on one
function G.chatMessage(text, how)
    local message = { text = text, how = how }
    function message:getTextWithPrefix() return G.lineText(self.text, self.how) end
    function message:getText() return self.text end
    function message:setText(value) self.text = value end
    function message:getAuthor() return nil end
    return message
end

-- one or more lines from ZomBOT in the visible chat tab; false when the chat could not take them
function G.say(text, how)
    local lines = {}
    for raw in string.gmatch(tostring(text or "") .. "\n", "([^\n]*)\n") do
        local line = trim(raw)
        if line ~= "" then lines[#lines + 1] = line end
    end
    if #lines == 0 then return true end
    local ok = pcall(function()
        local chat = ISChat.instance
        local tab = chat.chatText or chat.tabs[1]
        for i, line in ipairs(lines) do
            local style = how
            if i > 1 then style = "more" end
            ISChat.addLineInChat(G.chatMessage(line, style), tab.tabID)
        end
    end)
    if not ok then
        -- no chat window (yet): over the head, and the «ZomBOT» window keeps the answers
        pcall(function() HaloTextHelper.addGoodText(getPlayer(), "ZomBOT: " .. string.sub(lines[1], 1, 80)) end)
    end
    return ok
end

-- -- questions from the chat ---------------------------------------------------------------------------------------
G.DEFAULT_STREAMS = {
    { name = "say", command = "/say ", shortCommand = "/s ", tabID = 1 },
    { name = "yell", command = "/yell ", shortCommand = "/y ", tabID = 1 },
    { name = "whisper", command = "/whisper ", shortCommand = "/w ", tabID = 1 },
    { name = "faction", command = "/faction ", shortCommand = "/f ", tabID = 1 },
    { name = "safehouse", command = "/safehouse ", shortCommand = "/sh ", tabID = 1 },
    { name = "general", command = "/all ", tabID = 1 },
    { name = "admin", command = "/admin ", shortCommand = "/a ", tabID = 2 },
}

-- The question in a line typed in the chat, or nil when the line is not for ZomBOT: «zombot dove trovo le asce?»,
-- «/all @ZomBOT, dove...», «Zombot: ...». "" for the name alone. `tabID`: the chat's tab (one-based, as
-- ISChat.currentTabID); a stream of another tab never leaves (the game refuses it), a whisper is for someone else.
function G.questionOf(line, tabID)
    local text = string.gsub(tostring(line or ""), "[\r\n]", " ")
    local streams = (ISChat and ISChat.allChatStreams) or G.DEFAULT_STREAMS
    for _, stream in ipairs(streams) do
        local prefix = nil
        if starts(text, stream.command) then
            prefix = stream.command
        elseif stream.shortCommand and starts(text, stream.shortCommand) then
            prefix = stream.shortCommand
        end
        if prefix then
            if stream.name == "whisper" then return nil end
            if tabID and stream.tabID and tabID ~= stream.tabID then return nil end
            text = string.sub(text, #prefix + 1)
            break
        end
    end
    text = trim(text)
    local at = string.sub(text, 1, 1) == "@" and 1 or 0
    if string.lower(string.sub(text, at + 1, at + 6)) ~= "zombot" then return nil end
    local rest = string.sub(text, at + 7)
    if rest ~= "" and not string.match(rest, "^[ ,:]") then return nil end -- «zombottone», «zombot!»
    return trim((string.gsub(rest, "^[ ,:]+", "")))
end

-- what the game will do with the line: nothing at all in slow mode, as ISChat.onCommandEntered
local function chatSends(chat)
    local blocked = false
    pcall(function()
        if (chat.timerMessageSlowMode or 0) > getTimestampMs()
            and not getPlayer():getRole():hasCapability(Capability.IgnoreChatSlowMode) then
            blocked = true
        end
    end)
    return not blocked
end

-- the question goes to the server, if this player has not asked too much (the server counts again)
function G.ask(question)
    question = trim(question)
    if #question < G.MIN_TEXT then
        G.say("scrivi la domanda dopo il mio nome, per esempio: zombot dove trovo le asce?", "note")
        return false
    end
    if #question > G.MAX_TEXT then
        G.say("la domanda è troppo lunga: al massimo 300 caratteri.", "note")
        return false
    end
    local nowMs = getTimestampMs()
    local recent = {}
    for _, t in ipairs(G.asked) do
        if nowMs - t < 3600000 then recent[#recent + 1] = t end
    end
    G.asked = recent
    local last = recent[#recent]
    if last and nowMs - last < G.GAP_MS then
        G.say("una domanda ogni 10 secondi: aspetta un attimo e riprova.", "note")
        return false
    end
    if #recent >= G.PER_HOUR then
        G.say("hai già fatto 30 domande nell'ultima ora: riprova più tardi.", "note")
        return false
    end
    table.insert(G.asked, nowMs)
    G.lastQuestion = question
    sendClientCommand(getPlayer(), G.MODULE, "ask", { text = question })
    G.say("ci pensa...", "note")
    return true
end

-- the game's own handling first (the message reaches the chat as always), then the question
function G.onChatEntered(original, ...)
    local question = nil
    pcall(function()
        local chat = ISChat.instance
        if chat and chat.textEntry and chatSends(chat) then
            question = G.questionOf(chat.textEntry:getText(), chat.currentTabID)
        end
    end)
    local result = original(...)
    if question then
        local ok, err = pcall(G.ask, question)
        if not ok then print("ZomBotGioco: ask failed: " .. tostring(err)) end
    end
    return result
end

function G.hookChat()
    if ISChat == nil or type(ISChat.onCommandEntered) ~= "function" then return false end
    if ISChat.onCommandEntered ~= G.chatWrapper then
        local original = ISChat.onCommandEntered
        G.chatOriginal = original
        G.chatWrapper = function(...) return G.onChatEntered(original, ...) end
        ISChat.onCommandEntered = G.chatWrapper
    end
    -- the entry box keeps the function it got when the chat was made; another mod's wrapper there stays
    pcall(function()
        local entry = ISChat.instance and ISChat.instance.textEntry
        if entry and entry.onCommandEntered == G.chatOriginal then entry.onCommandEntered = G.chatWrapper end
    end)
    return true
end

-- the answers this player received, for the «ZomBOT» window
function G.remember(questionId, text)
    table.insert(G.answers, 1, { question = questionId and G.pending[questionId] or "", text = text })
    while #G.answers > G.KEEP_ANSWERS do table.remove(G.answers) end
    if questionId then G.pending[questionId] = nil end
end

-- -- coloured crates (local paint) ---------------------------------------------------------------------------------
function G.colorOf(id)
    for _, colour in ipairs(G.PALETTE) do
        if colour.id == id then return colour end
    end
    return nil
end

local function hasContainer(object)
    local ok, container = pcall(function() return object:getContainer() end)
    return ok and container ~= nil
end

-- the object with a container at `index` on the square, or the first one there (as the server does)
function G.containerObject(square, index)
    local objects = square:getObjects()
    if index and index >= 0 and index < objects:size() and hasContainer(objects:get(index)) then
        return objects:get(index)
    end
    for i = 0, objects:size() - 1 do
        if hasContainer(objects:get(i)) then return objects:get(i) end
    end
    return nil
end

local function squareKey(x, y, z)
    return x .. "," .. y .. "," .. z
end

-- the colour the game itself gave the object (almost always none), kept to put back
local function originalOf(object)
    local ok, values = pcall(function()
        local colour = object:getCustomColor()
        if colour == nil then return false end
        return { colour:getR(), colour:getG(), colour:getB(), colour:getA() }
    end)
    return ok and values or false
end

local function restore(object, original)
    pcall(function()
        if original then
            object:setCustomColor(original[1], original[2], original[3], original[4])
        elseif not pcall(function() object:setCustomColor(nil) end) then
            object:setCustomColor(1, 1, 1, 1) -- white: the same as no colour
        end
    end)
end

-- a coloured object as it should look on this screen: its colour, or the game's when colouring is off. An object
-- that was never coloured (entry nil) is never touched.
function G.paint(object, entry)
    if entry == nil then return end
    local colour = G.setting().colors and G.colorOf(entry.color) or nil
    if colour then
        pcall(function() object:setCustomColor(colour.r, colour.g, colour.b, 1) end)
    else
        restore(object, entry and entry.original)
    end
end

function G.entryAt(x, y, z, index)
    local square = G.known[squareKey(x, y, z)]
    return square and square.objects[index] or nil
end

-- A square loaded from the server: its objects are new, read again which ones are coloured. Only the objects that
-- carry modData are looked at, and only known coloured ones are ever painted.
function G.onLoadSquare(square)
    if square == nil then return end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local key = squareKey(x, y, z)
    G.known[key] = nil
    -- the square of the container blinking came again: its object is a new one
    local blink = G.blink
    if blink and blink.x == x and blink.y == y and blink.z == z then blink.object, blink.nextMs = nil, 0 end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object:hasModData() then
            local colour = object:getModData()[G.KEY]
            if colour and G.colorOf(colour) then
                G.known[key] = G.known[key] or { x = x, y = y, z = z, objects = {} }
                local entry = { color = colour, original = originalOf(object) }
                G.known[key].objects[i] = entry
                G.paint(object, entry)
            end
        end
    end
end

-- the server says a player coloured (or cleared) a crate
function G.onColor(args)
    local x, y, z, index = tonumber(args.x), tonumber(args.y), tonumber(args.z), tonumber(args.index)
    if not (x and y and z and index) then return end
    local key = squareKey(x, y, z)
    local entry = G.entryAt(x, y, z, index)
    local square = nil
    pcall(function() square = getCell():getGridSquare(x, y, z) end)
    local object = square and G.containerObject(square, index) or nil
    local colour = G.colorOf(args.color) and args.color or nil
    if colour then
        if entry == nil then
            entry = { original = object and originalOf(object) or false }
            G.known[key] = G.known[key] or { x = x, y = y, z = z, objects = {} }
            G.known[key].objects[index] = entry
        end
        entry.color = colour
    else
        if entry == nil then return end -- never coloured here: nothing to take off
        G.known[key].objects[index] = nil
        if next(G.known[key].objects) == nil then G.known[key] = nil end
        entry = { original = entry.original } -- no colour: the game's own back
    end
    -- a blinking container gets its colour back when the blink ends
    if object and not (G.blink and G.blink.object == object) then G.paint(object, entry) end
end

-- «Colora le casse»: only the coloured objects already seen, never a look around
function G.setColors(on)
    G.setting().colors = on and true or false
    G.saveSettings()
    for _, square in pairs(G.known) do
        local loaded = nil
        pcall(function() loaded = getCell():getGridSquare(square.x, square.y, square.z) end)
        if loaded then
            for index, entry in pairs(square.objects) do
                local object = G.containerObject(loaded, index)
                if object and not (G.blink and G.blink.object == object) then G.paint(object, entry) end
            end
        end
    end
end

-- -- the container that blinks -------------------------------------------------------------------------------------
function G.label(name, kind)
    if name and name ~= "" then return name end
    local text = nil
    pcall(function() text = getTextOrNull("IGUI_ContainerTitle_" .. tostring(kind)) end)
    return text or (kind and kind ~= "" and kind) or "contenitore"
end

local function findBlinkObject(blink)
    if blink.object then return blink.object end
    local square = nil
    pcall(function() square = getCell():getGridSquare(blink.x, blink.y, blink.z) end)
    if square == nil then return nil end -- not loaded here yet: tried again at the next step
    local object = G.containerObject(square, blink.index)
    if object == nil then return nil end
    blink.object = object
    blink.entry = G.entryAt(blink.x, blink.y, blink.z, blink.index)
    if blink.entry then restore(object, blink.entry.original) end -- the blink in its own colour, not mixed
    pcall(function() ISInventoryPage.OnObjectHighlighted(blink.playerNum, object, true) end)
    return object
end

-- whether the loot window shows this object's container
function G.isOpen(object, num)
    local open = false
    pcall(function()
        local loot = getPlayerLoot(num)
        if loot and not loot.isCollapsed and loot.inventory and loot.inventory:getParent() == object then open = true end
    end)
    return open
end

function G.stopBlink(why)
    local blink = G.blink
    if blink == nil then return end
    G.blink = nil
    G.blinkStopped = why
    local object = blink.object
    if object then
        pcall(function() object:setHighlighted(blink.playerNum, false, false) end)
        -- the game's own colour back: vanilla highlights it again without one (moving it: ISMoveablesAction), and it
        -- would come out in the blink's yellow
        pcall(function()
            local c = getCore():getObjectHighlitedColor()
            object:setHighlightColor(blink.playerNum, c:getR(), c:getG(), c:getB(), c:getA())
        end)
        -- the loot window takes it back (and highlights it again if it is the open container)
        pcall(function() ISInventoryPage.OnObjectHighlighted(blink.playerNum, object, false) end)
        G.paint(object, G.entryAt(blink.x, blink.y, blink.z, blink.index))
    end
end

function G.startBlink(args)
    G.stopBlink("another")
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not (x and y and z) then return end
    local seconds = math.min(tonumber(args.seconds) or 60, 60)
    G.blink = { x = x, y = y, z = z, index = tonumber(args.index) or -1, playerNum = playerNum(),
        untilMs = getTimestampMs() + seconds * 1000, nextMs = 0, on = false }
    G.tick()
end

function G.tick()
    local blink = G.blink
    if blink == nil then return end
    local nowMs = getTimestampMs()
    if nowMs >= blink.untilMs then return G.stopBlink("time") end
    if nowMs < blink.nextMs then return end
    blink.nextMs = nowMs + G.BLINK_STEP_MS
    local object = findBlinkObject(blink)
    if object == nil then return end
    if G.isOpen(object, blink.playerNum) then return G.stopBlink("open") end
    blink.on = not blink.on
    local c = G.BLINK_RGBA
    pcall(function()
        object:setHighlightColor(blink.playerNum, c[1], c[2], c[3], c[4])
        object:setHighlighted(blink.playerNum, blink.on, false)
    end)
end

-- a left click on the object, or on anything on its square (the floor in front of a low crate)
function G.onObjectClick(object)
    local blink = G.blink
    if blink == nil or object == nil then return end
    if object == blink.object then return G.stopBlink("click") end
    local x, y, z = nil, nil, nil
    pcall(function()
        local square = object:getSquare()
        x, y, z = square:getX(), square:getY(), square:getZ()
    end)
    if x == blink.x and y == blink.y and z == blink.z then G.stopBlink("click") end
end

-- -- the server's messages -------------------------------------------------------------------------------------------
G.windows = G.windows or {}

function G.onServerCommand(module, command, args)
    if module ~= G.MODULE then return end
    args = args or {}
    if command == "asked" then
        if args.question then G.pending[args.question] = G.lastQuestion or "" end
    elseif command == "refused" then
        G.say(args.text, "note")
    elseif command == "reply" then
        G.say(args.text)
        G.remember(args.question, tostring(args.text or ""))
    elseif command == "blink" then
        G.startBlink(args)
        local where = G.label(args.name, args.type)
        local distance = tonumber(args.distance)
        local far = distance and string.format(", a %d m", math.floor(distance + 0.5)) or ""
        G.say("lampeggia '" .. where .. "'" .. far .. ". Si ferma con un clic, aprendo il contenitore o dopo un minuto.")
    elseif command == "color" then
        G.onColor(args)
    elseif command == "done" or command == "error" then
        pcall(function()
            if command == "done" then HaloTextHelper.addGoodText(getPlayer(), args.text)
            else HaloTextHelper.addBadText(getPlayer(), args.text) end
        end)
        local window = G.windows.ZomBotGiocoPalette
        if window then window:setStatus(args.text, command == "error") end
    end
end

-- -- windows --------------------------------------------------------------------------------------------------------
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local PAD = 10
local BUTTON_HGT = FONT_HGT_SMALL + 8
local GREY = { r = 0.62, g = 0.64, b = 0.68 }
local GREEN = { r = 0.40, g = 0.82, b = 0.45 }
local RED = { r = 0.95, g = 0.35, b = 0.32 }

local function textWidth(text, font)
    return getTextManager():MeasureStringX(font or UIFont.Small, text)
end

-- the words of `text` in lines no wider than `width`
function G.wrap(text, width, font)
    local lines, line = {}, ""
    for word in string.gmatch(trim(text), "[^ ]+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if line ~= "" and textWidth(candidate, font) > width then
            lines[#lines + 1] = line
            line = word
        else
            line = candidate
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

local function button(parent, x, y, w, title, onClick, kind)
    local b = ISButton:new(x, y, w, BUTTON_HGT, title, parent, onClick)
    b:initialise()
    b:instantiate()
    if kind == "accept" then b:enableAcceptColor() end
    if kind == "cancel" then b:enableCancelColor() end
    parent:addChild(b)
    return b
end

-- a window that goes away when closed, with Admin-Scorte's look (its class is not here: this mod stands alone)
ZomBotGiocoWindow = ISCollapsableWindow:derive("ZomBotGiocoWindow")

function ZomBotGiocoWindow:new(x, y, width, height, title)
    local o = ISCollapsableWindow.new(self, x, y, width, height)
    o:setTitle(title)
    o:setResizable(false)
    o.status, o.statusBad = nil, false
    return o
end

function ZomBotGiocoWindow:top()
    return self:titleBarHeight() + PAD
end

function ZomBotGiocoWindow:setStatus(text, bad)
    self.status, self.statusBad = text, bad
end

function ZomBotGiocoWindow:close()
    self:setVisible(false)
    self:removeFromUIManager()
    if G.windows[self.Type] == self then G.windows[self.Type] = nil end
end

function G.show(class, width, height, ...)
    local old = G.windows[class.Type]
    if old then old:close() end
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local window = class:new(x, y, width, height, ...)
    window:initialise()
    window:addToUIManager()
    G.windows[class.Type] = window
    return window
end

-- the main window: how to ask, the colouring switch, the last answers, the other mods' buttons
ZomBotGiocoMain = ZomBotGiocoWindow:derive("ZomBotGiocoMain")
G.OWN_EXTRAS = { ["zombot-colors"] = true, ["zombot-window"] = true } -- the switch and the window are here already

function ZomBotGiocoMain:new(x, y, width, height, ctx, extras)
    local o = ZomBotGiocoWindow.new(self, x, y, width, height, "ZomBOT")
    o.ctx, o.extras = ctx or {}, extras or {}
    return o
end

function ZomBotGiocoMain:createChildren()
    ISCollapsableWindow.createChildren(self)
    local width = self.width - PAD * 2
    self.intro = G.wrap(G.HOW_TO .. " Se sei dentro una base, il contenitore più vicino che le ha lampeggia per un "
        .. "minuto: cliccalo o aprilo per fermarlo.", width)
    local y = self:top() + FONT_HGT_MEDIUM + 4 + #self.intro * FONT_HGT_SMALL + PAD
    self.colorsBox = ISTickBox:new(PAD, y, textWidth("Colora le casse") + 40, BUTTON_HGT, "", self,
        ZomBotGiocoMain.onColorsBox)
    self.colorsBox:initialise()
    self.colorsBox:instantiate()
    self.colorsBox:addOption("Colora le casse")
    self.colorsBox:setSelected(1, G.setting().colors)
    self:addChild(self.colorsBox)
    -- the note under the switch, on its own line: beside it, it would leave the window with the larger fonts
    self.answersTop = y + BUTTON_HGT + FONT_HGT_SMALL + PAD
    -- from the bottom: «Chiudi», then one button for each extra
    local bottom = self.height - PAD - BUTTON_HGT
    self.closeButton2 = button(self, self.width - PAD - 100, bottom, 100, "Chiudi", ZomBotGiocoMain.close)
    self.extraButtons = {}
    for i = #self.extras, 1, -1 do
        bottom = bottom - BUTTON_HGT - 6
        local extra = self.extras[i]
        local b = button(self, PAD, bottom, width, extra.label, ZomBotGiocoMain.onExtra)
        b.extra = extra
        table.insert(self.extraButtons, 1, b)
    end
    self.answersBottom = bottom - PAD
end

function ZomBotGiocoMain:onColorsBox(index, selected)
    G.setColors(selected)
end

function ZomBotGiocoMain:onExtra(b)
    ZomBotMenu.press(b.extra, self.ctx)
    -- a label may have changed (a switch): ask the extra again
    pcall(function() b:setTitle(b.extra.def.label(self.ctx) or b.title) end)
end

function ZomBotGiocoMain:render()
    ISCollapsableWindow.render(self)
    local y = self:top()
    self:drawText("Chiedi a ZomBOT", PAD, y, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Medium)
    y = y + FONT_HGT_MEDIUM + 4
    for _, line in ipairs(self.intro or {}) do
        self:drawText(line, PAD, y, 1, 1, 1, 1, UIFont.Small)
        y = y + FONT_HGT_SMALL
    end
    self:drawText("Solo per te: chi non ha la mod non vede i colori.", PAD, self.colorsBox.y + BUTTON_HGT, GREY.r,
        GREY.g, GREY.b, 1, UIFont.Small)
    y = self.answersTop
    self:drawText("Ultime risposte", PAD, y, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Medium)
    y = y + FONT_HGT_MEDIUM + 4
    local width = self.width - PAD * 2
    if #G.answers == 0 then
        self:drawText("Nessuna risposta ancora.", PAD, y, GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
        return
    end
    for _, answer in ipairs(G.answers) do
        local lines = {}
        if answer.question ~= "" then
            for _, line in ipairs(G.wrap("Tu: " .. answer.question, width)) do lines[#lines + 1] = { line, GREY } end
        end
        for part in string.gmatch(answer.text .. "\n", "([^\n]*)\n") do
            for _, line in ipairs(G.wrap(part, width)) do lines[#lines + 1] = { line } end
        end
        for _, line in ipairs(lines) do
            if y + FONT_HGT_SMALL > self.answersBottom then return end
            local c = line[2] or { r = 1, g = 1, b = 1 }
            self:drawText(line[1], PAD, y, c.r, c.g, c.b, 1, UIFont.Small)
            y = y + FONT_HGT_SMALL
        end
        y = y + 6
    end
end

function G.openWindow(ctx)
    ctx = ctx or {}
    local player = ctx.player or getPlayer()
    local extras = {}
    for _, extra in ipairs(ZomBotMenu.extras and ZomBotMenu.extras(player, ctx) or {}) do
        if not G.OWN_EXTRAS[extra.def.id] then extras[#extras + 1] = extra end
    end
    local height = 470 + #extras * (BUTTON_HGT + 6)
    return G.show(ZomBotGiocoMain, 500, height, ctx, extras)
end

-- the palette, for the crate right-clicked (any player: the colour is for the whole server)
ZomBotGiocoPalette = ZomBotGiocoWindow:derive("ZomBotGiocoPalette")
local SWATCH = 18

function ZomBotGiocoPalette:new(x, y, width, height, target)
    local o = ZomBotGiocoWindow.new(self, x, y, width, height, "ZomBOT  -  Colore della cassa")
    o.target = target
    local name, kind = nil, nil
    pcall(function()
        local container = target.object:getContainer()
        name, kind = container:getCustomName(), container:getType()
    end)
    o.what = G.label(name, kind)
    return o
end

ZomBotGiocoPalette.NOTE = "Lo vedono tutti quelli che hanno la mod ZomBOT."
ZomBotGiocoPalette.STATUS_LINES = 2

function ZomBotGiocoPalette:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.note = G.wrap(ZomBotGiocoPalette.NOTE, self.width - PAD * 2)
    local top = self:top() + FONT_HGT_MEDIUM + FONT_HGT_SMALL * #self.note + PAD
    local w = (self.width - PAD * 3) / 2 - SWATCH - 4
    self.colorButtons = {}
    for i, colour in ipairs(G.PALETTE) do
        local column, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local x = PAD + column * (w + SWATCH + 4 + PAD) + SWATCH + 4
        local b = button(self, x, top + row * (BUTTON_HGT + 6), w, colour.label, ZomBotGiocoPalette.onColour)
        b.colour = colour
        self.colorButtons[#self.colorButtons + 1] = b
    end
    local y = top + math.ceil(#G.PALETTE / 2) * (BUTTON_HGT + 6) + 4
    self.noneButton = button(self, PAD, y, self.width - PAD * 2, "Nessun colore", ZomBotGiocoPalette.onNone, "cancel")
    self.statusY = y + BUTTON_HGT + PAD
    -- the window as tall as what it holds, with the game's fonts at any size: a status of two lines, then «Chiudi»
    local bottom = self.statusY + FONT_HGT_SMALL * ZomBotGiocoPalette.STATUS_LINES + PAD
    self:setHeight(bottom + BUTTON_HGT + PAD)
    self.doneButton = button(self, self.width - PAD - 100, bottom, 100, "Chiudi", ZomBotGiocoPalette.close)
end

function ZomBotGiocoPalette:render()
    ISCollapsableWindow.render(self)
    local y = self:top()
    self:drawText(self.what, PAD, y, GOLD.r, GOLD.g, GOLD.b, 1, UIFont.Medium)
    for i, line in ipairs(self.note or {}) do
        self:drawText(line, PAD, y + FONT_HGT_MEDIUM + FONT_HGT_SMALL * (i - 1), GREY.r, GREY.g, GREY.b, 1, UIFont.Small)
    end
    for _, b in ipairs(self.colorButtons or {}) do
        local c = b.colour
        self:drawRect(b.x - SWATCH - 4, b.y + (BUTTON_HGT - SWATCH) / 2, SWATCH, SWATCH, 1, c.r, c.g, c.b)
        self:drawRectBorder(b.x - SWATCH - 4, b.y + (BUTTON_HGT - SWATCH) / 2, SWATCH, SWATCH, 1, 0, 0, 0)
    end
    if self.status and self.status ~= "" then
        local c = self.statusBad and RED or GREEN
        for i, line in ipairs(G.wrap(self.status, self.width - PAD * 2)) do
            if i > ZomBotGiocoPalette.STATUS_LINES then break end
            self:drawText(line, PAD, self.statusY + FONT_HGT_SMALL * (i - 1), c.r, c.g, c.b, 1, UIFont.Small)
        end
    end
end

function ZomBotGiocoPalette:send(colour)
    local t = self.target
    self:setStatus("Invio al server...", false)
    sendClientCommand(getPlayer(), G.MODULE, "setColor", { x = t.x, y = t.y, z = t.z, index = t.index, color = colour })
end

function ZomBotGiocoPalette:onColour(b)
    self:send(b.colour.id)
end

function ZomBotGiocoPalette:onNone()
    self:send("none")
end

function G.openPalette(target)
    if target == nil then return nil end
    return G.show(ZomBotGiocoPalette, 380, 300, target) -- the height follows the content (createChildren)
end

-- -- the one «ZomBOT» entry of the right click (client/ZomBotMenu.lua) ----------------------------------------------
ZomBotMenu = ZomBotMenu or {}
ZomBotMenu.defs = ZomBotMenu.defs or {}

G.mainDef = {
    kind = "main", id = "zombot", order = 20,
    available = function() return true end,
    open = function(ctx) G.openWindow(ctx) end,
}
table.insert(ZomBotMenu.defs, G.mainDef)

table.insert(ZomBotMenu.defs, {
    kind = "extra", id = "zombot-color", order = 20,
    available = function(_, ctx) return ctx ~= nil and ctx.container ~= nil end,
    label = function() return "Colore di questa cassa..." end,
    onClick = function(ctx) G.openPalette(ctx and ctx.container) end,
})

-- the same palette straight from the right click on a crate, without the window (28/10/2026, the user: «tasto destro
-- sulla cassa -> Zombot: colora il contenitore»)
table.insert(ZomBotMenu.defs, {
    kind = "shortcut", id = "zombot-color-now", order = 20,
    available = function(_, ctx) return ctx ~= nil and ctx.container ~= nil end,
    label = function() return "ZomBOT: colora il contenitore" end,
    onClick = function(ctx) G.openPalette(ctx and ctx.container) end,
})

-- the switch and this window, from another mod's main window (Admin-Scorte's bases, for an admin)
local function elsewhere(player, ctx)
    return ZomBotMenu.mainFor ~= nil and ZomBotMenu.mainFor(player, ctx or {}) ~= G.mainDef
end

table.insert(ZomBotMenu.defs, {
    kind = "extra", id = "zombot-colors", order = 21, available = elsewhere,
    label = function() return "Casse colorate: " .. (G.setting().colors and "sì" or "no") end,
    onClick = function() G.setColors(not G.setting().colors) end,
})

table.insert(ZomBotMenu.defs, {
    kind = "extra", id = "zombot-window", order = 22, available = elsewhere,
    label = function() return "ZomBOT: domande e risposte..." end,
    onClick = function(ctx) G.openWindow(ctx) end,
})

-- -- start ---------------------------------------------------------------------------------------------------------
local function onTick()
    if G.blink == nil then return end -- nothing to do on almost every tick
    local ok, err = pcall(G.tick)
    if not ok then
        print("ZomBotGioco: blink failed: " .. tostring(err))
        G.blink = nil
    end
end

local function safe(f, name)
    return function(...)
        local ok, err = pcall(f, ...)
        if not ok then print("ZomBotGioco: " .. name .. " failed: " .. tostring(err)) end
    end
end

if not G.started then
    G.started = true
    Events.OnServerCommand.Add(safe(function(...) G.onServerCommand(...) end, "server command"))
    Events.LoadGridsquare.Add(safe(function(square) G.onLoadSquare(square) end, "square"))
    Events.OnObjectLeftMouseButtonDown.Add(safe(function(object) G.onObjectClick(object) end, "click"))
    Events.OnTick.Add(onTick)
    Events.OnGameStart.Add(safe(function() G.loadSettings(); G.hookChat() end, "start"))
end
G.hookChat()
