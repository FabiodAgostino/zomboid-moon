-- ZomBotAutoPilot (client): the private Discord alerts of AutoPilot (Moon), the players' half of the bridge
-- (20/11/2026). Client only, in the mod «ZomBOT (Moon)». The server's half is server/ZomBotAutoPilot.lua (module
-- "ZomBotAP"), which checks everything again and keeps the register the bot reads: nothing here gives anyone a power.
--
-- AutoPilot never talks to the network. Since its version 1.5 it raises local events (AutoPilotMoon.Notify, contract
-- version 1, AutoPilot's tests/notify_contract.json: subscribe, unsubscribe, getMode, getRun, control, setStatus) and
-- this file forwards them:
--   - at the start of a game, or at the first ticks if AutoPilot loads later, it looks for AutoPilotMoon.Notify with
--     version 1. Without it (no AutoPilot, an older one, a newer contract) it does nothing at all;
--   - handshake: "hello" {v = 1, ap, mode, to, lang}; the server answers "welcome" {v, sess}. Until then the events
--     wait (the last 20); with no answer in 10 s the server has no bridge: nothing more is sent this game and
--     AutoPilot shows «noserver» (a late welcome still opens the way);
--   - every event goes to the server as "event" (a flat copy, with `to`, the Discord key the player confirmed), for
--     the player of the job (event.playerNum), at most 5 a second and 60 a minute (a stop or a critical event passes
--     beyond them, at most 10 a minute); the ones left out become one "flood" event with how many;
--   - "beat" {run, job, title} every 30 s while a job runs (the last event counts as one): the server's sentinel
--     says when the game stops answering;
--   - the server's "control" {id, action, text}:
--       stop     -> AutoPilot's Notify:control("stop") (it stops the job, the chain or the macro and empties the
--                   queue of actions, the ones queued by hand too), then "ack" {id, action, result =
--                   "stopped" | "nothing" | "noautopilot"};
--       logout   -> the game's own way out, as «Esci» of the pause menu: two players on this computer -> "ack"
--                   "splitscreen"; the game's safety wait (isQuitCooldown) -> "cooldown"; else AutoPilot stopped,
--                   the queue of actions emptied, "ack" "leaving", and 30 ticks later (at least 500 ms, for the ack to
--                   leave) setGameSpeed(1), pauseSoundAndMusic(), setShowPausedMessage(true) and
--                   getCore():exitToMenu(), once. Never getCore():quit() (it closes the whole game when no player is
--                   there). The server saves the character when it sees the connection close, as for «Esci»;
--       linkinfo -> who gets the alerts: "ok|<key>|<Discord name>": a key this account has not confirmed on this
--                   computer opens «andranno a <nome>. Sei tu?» once; «Sì» keeps it in Zomboid/Lua/zombot_autopilot.txt
--                   (key TAB account) and sends the setting again with it, «No» sends nothing but the setting for the
--                   rest of the game. Before a confirmed key only the setting (kind "pref") ever leaves this computer.
--                   "nolink", "dmclosed": a line in the chat, once a game; "botoff": AutoPilot's status only.
-- The texts follow the language of the game (Italian, else English).
--
-- Verified in 42.22 (the game's Lua and projectzomboid.jar with javap): «Esci» in game is setGameSpeed(1);
-- pauseSoundAndMusic(); setShowPausedMessage(true); getCore():quit() (OptionScreens/MainScreen.lua, refused while
-- isQuitCooldown()); the death screen uses setGameSpeed(1) and getCore():exitToMenu() (ISPostDeathUI.lua). Core.quit
-- and Core.exitToMenu only set Core.exiting when a player is there; IngameState then disconnects ("exiting"), saves
-- the map and goes back to the menu, and the server saves the character in GameServer.disconnect
-- (ServerPlayerDB.serverUpdateNetworkCharacter). OnTickEvenPaused fires on every frame of a client.
-- ISTimedActionQueue.clear(player) stops the action under way and empties the queue. ISModalDialog:new(x, y, w, h,
-- text, yesno, target, onclick, player, param1, param2) calls onclick(target, button, param1, param2), button.internal
-- "YES" or "NO". Translator.getLanguage():name() is "IT", "EN"...
if isServer() and not isClient() then return end

ZomBotAutoPilot = ZomBotAutoPilot or {}
local Z = ZomBotAutoPilot

Z.MODULE = "ZomBotAP"
Z.CONTRACT = 1 -- AutoPilotMoon.Notify.version this file speaks
Z.FILE = "zombot_autopilot.txt"
Z.WELCOME_MS = 10000
Z.BEAT_MS = 30000
Z.STEP_MS = 1000 -- the bridge's own work, once a second
Z.DETECT_MS = 60000 -- looking for AutoPilot after the game starts
Z.PER_SECOND, Z.PER_MINUTE = 5, 60
Z.URGENT_PER_MINUTE = 10
Z.WAITING_KEEP = 20
Z.LOGOUT_TICKS = 30
Z.LOGOUT_MS = 500
Z.MAX_NAME = 40
Z.MAX_KEYS = 20

Z.TEXTS = {
    IT = {
        confirm = function(name)
            return "Gli avvisi di AutoPilot andranno in privato su Discord a " .. name .. ". Sei tu?"
        end,
        confirmed = function(name) return "gli avvisi di AutoPilot andranno in privato su Discord a " .. name .. "." end,
        declined = function(name)
            return "non mando gli avvisi di AutoPilot a " .. name .. ". Se non sei tu, avvisa un admin del server."
        end,
        nolink = function()
            return "per mandarti gli avvisi di AutoPilot devo sapere chi sei su Discord: nel canale di ZomBOT scrivi "
                .. "/sono e il tuo nome utente del gioco."
        end,
        dmclosed = function()
            return "non riesco a scriverti in privato su Discord: nelle impostazioni del server Discord attiva i "
                .. "messaggi diretti."
        end,
    },
    EN = {
        confirm = function(name) return "AutoPilot alerts will go privately to " .. name .. " on Discord. Is that you?" end,
        confirmed = function(name) return "AutoPilot alerts will go privately to " .. name .. " on Discord." end,
        declined = function(name)
            return "I will not send AutoPilot alerts to " .. name .. ". If that is not you, tell a server admin."
        end,
        nolink = function()
            return "to send you AutoPilot alerts I need to know who you are on Discord: in ZomBOT's channel type "
                .. "/sono and your in-game username."
        end,
        dmclosed = function()
            return "I cannot write to you privately on Discord: in the Discord server's settings allow direct messages."
        end,
    },
}

-- Control characters spelled out, never %c: in a C Lua (the tests) it follows the locale and can match a byte of «à»
local CONTROL = "[" .. string.char(1) .. "-" .. string.char(31) .. string.char(127) .. "]"
-- true in a C Lua, where a string is its UTF-8 bytes; false in the game's, where "\195\160" is one letter
local BYTES = #"\195\160" == 2

local function now()
    return getTimestampMs()
end

-- at most `max` letters, never half of one
local function cut(text, max)
    if #text <= max then return text end
    text = string.sub(text, 1, max)
    if not BYTES then return text end
    local i = #text
    while i > 0 do
        local b = string.byte(text, i)
        if b < 128 then break end
        if b >= 192 then
            local need = 2
            if b >= 240 then need = 4 elseif b >= 224 then need = 3 end
            if #text - i + 1 < need then text = string.sub(text, 1, i - 1) end
            break
        end
        i = i - 1
    end
    return text
end

local function cleanName(value)
    local text = string.gsub(tostring(value or ""), CONTROL, " ")
    text = string.gsub(text, " +", " ")
    text = string.gsub(text, "^ ", "")
    text = string.gsub(text, " $", "")
    text = cut(text, Z.MAX_NAME)
    if text == "" then return "?" end
    return text
end

local function hexId(value, max)
    if type(value) ~= "string" or #value < 1 or #value > max or not string.match(value, "^%x+$") then return nil end
    return string.lower(value)
end

-- the timestamps of `list` (oldest first) still within `span` ms of t
local function keepRecent(list, t, span)
    local drop = 0
    for i = 1, #list do
        if t - list[i] >= span then drop = i else break end
    end
    if drop == 0 then return end
    local n = #list
    for i = 1, n - drop do list[i] = list[i + drop] end
    for i = n - drop + 1, n do list[i] = nil end
end

-- -- the game ------------------------------------------------------------------------------------------------------
function Z.mainPlayer()
    local ok, player = pcall(function() return getPlayer() end)
    if ok then return player end
    return nil
end

function Z.playerOf(num)
    if type(num) == "number" then
        local ok, player = pcall(function() return getSpecificPlayer(num) end)
        if ok and player ~= nil then return player end
    end
    return Z.mainPlayer()
end

function Z.username(player)
    if player == nil then return nil end
    local ok, user = pcall(function() return player:getUsername() end)
    if ok and type(user) == "string" and user ~= "" then return user end
    return nil
end

function Z.lang()
    local ok, name = pcall(function() return Translator.getLanguage():name() end)
    if ok and type(name) == "string" and name ~= "" then return tostring(name) end
    return "IT"
end

function Z.text(key, name)
    local texts = Z.TEXTS[Z.lang() == "IT" and "IT" or "EN"]
    return texts[key](name)
end

-- a line of ZomBOT in this player's chat (ZomBotGioco.lua of the same mod), over the head without it
function Z.chat(text)
    if ZomBotGioco and ZomBotGioco.say and pcall(ZomBotGioco.say, text, "note") then return end
    pcall(function() HaloTextHelper.addGoodText(getPlayer(), "ZomBOT: " .. text) end)
end

function Z.chatOnce(key)
    if Z.said[key] then return end
    Z.said[key] = true
    Z.chat(Z.text(key))
end

function Z.send(player, command, args)
    if player == nil then return false end
    local ok, err = pcall(sendClientCommand, player, Z.MODULE, command, args)
    if not ok then print("ZomBotAutoPilot: cannot send " .. tostring(command) .. ": " .. tostring(err)) end
    return ok
end

-- -- AutoPilot -------------------------------------------------------------------------------------------------------
function Z.status(code, text)
    Z.lastStatus = code
    local notify = Z.notify
    if notify and type(notify.setStatus) == "function" then pcall(notify.setStatus, notify, code, text) end
end

function Z.mode()
    local notify = Z.notify
    local ok, mode = pcall(function() return notify:getMode() end)
    if ok and (mode == "all" or mode == "problems" or mode == "off") then return mode end
    return "off"
end

-- the job AutoPilot says is running: {run, job, title}, or nil
function Z.autoPilotRun()
    local notify = Z.notify
    if notify == nil or type(notify.getRun) ~= "function" then return nil end
    local ok, run = pcall(notify.getRun, notify)
    if not ok or type(run) ~= "table" then return nil end
    local id = run.run
    if type(id) ~= "string" and type(id) ~= "number" then return nil end
    return { run = tostring(id), job = run.job, title = run.title }
end

-- AutoPilot stopped as its own «Ferma» would: "stopped", "nothing", or "noautopilot" without a contract to call
function Z.stopAutoPilot()
    local notify = Z.notify or Z.find()
    if notify == nil or type(notify.control) ~= "function" then return "noautopilot" end
    local ok, first, second = pcall(notify.control, notify, "stop")
    if not ok then return "noautopilot" end
    for _, answer in ipairs({ second, first }) do
        if answer == "stopped" or answer == "nothing" then return answer end
    end
    return "noautopilot"
end

-- AutoPilotMoon.Notify when it speaks this file's contract; nil otherwise ("incompatible": a newer one)
function Z.find()
    local ok, notify = pcall(function() return AutoPilotMoon and AutoPilotMoon.Notify end)
    if not ok or type(notify) ~= "table" then return nil end
    if notify.version ~= Z.CONTRACT or type(notify.subscribe) ~= "function" then
        Z.state = "incompatible"
        return nil
    end
    return notify
end

Z.listener = Z.listener or function(event)
    local ok, err = pcall(Z.receive, event)
    if not ok then print("ZomBotAutoPilot: event failed: " .. tostring(err)) end
end

function Z.detect()
    if Z.notify then return true end
    local notify = Z.find()
    if notify == nil then return false end
    local ok = pcall(notify.subscribe, notify, Z.listener)
    if not ok then return false end
    Z.notify = notify
    Z.state = "hello"
    Z.hello()
    return true
end

-- -- the Discord key this computer confirmed for each account ------------------------------------------------------
function Z.loadKeys()
    Z.keys = {}
    pcall(function()
        local reader = getFileReader(Z.FILE, false)
        if reader == nil then return end
        local line = reader:readLine()
        while line do
            local key, user = string.match(line, "^(%x+)\t([^\r\n]+)")
            if key and #key <= 12 then Z.keys[user] = string.lower(key) end
            line = reader:readLine()
        end
        reader:close()
    end)
end

function Z.saveKeys()
    local lines = { "# ZomBOT (Moon): the Discord key confirmed for the AutoPilot alerts of each account (key TAB account)" }
    if Z.mainUser and Z.keys[Z.mainUser] then lines[#lines + 1] = Z.keys[Z.mainUser] .. "\t" .. Z.mainUser end
    for user, key in pairs(Z.keys) do
        if user ~= Z.mainUser and #lines <= Z.MAX_KEYS then lines[#lines + 1] = key .. "\t" .. user end
    end
    local ok, err = pcall(function()
        local writer = getFileWriter(Z.FILE, true, false)
        writer:write(table.concat(lines, "\n") .. "\n")
        writer:close()
    end)
    if not ok then print("ZomBotAutoPilot: cannot save " .. Z.FILE .. ": " .. tostring(err)) end
end

-- the key the events of `player` carry, or nil (none confirmed, or a new one waiting for «Sì»)
function Z.keyFor(player)
    local user = Z.username(player)
    if user == nil then return nil end
    if user == Z.mainUser then return Z.active end
    return Z.keys[user]
end

-- -- to the server ---------------------------------------------------------------------------------------------------
function Z.hello()
    local player = Z.mainPlayer()
    local user = Z.username(player)
    if user == nil then return end -- no player yet: tried again at the next step
    Z.mainUser = user
    Z.active = Z.keys[user]
    local args = { v = 1, ap = Z.notify.version, mode = Z.mode(), to = Z.active or "", lang = Z.lang() }
    Z.state, Z.helloAt = "waiting", now() -- before sending: the answer may come back at once
    if not Z.send(player, "hello", args) then Z.state = "hello" end
end

-- whether one more event may leave now
function Z.allowed(urgent, t)
    keepRecent(Z.sentAt, t, 60000)
    local lastSecond = 0
    for i = #Z.sentAt, 1, -1 do
        if t - Z.sentAt[i] < 1000 then lastSecond = lastSecond + 1 else break end
    end
    if #Z.sentAt < Z.PER_MINUTE and lastSecond < Z.PER_SECOND then
        Z.sentAt[#Z.sentAt + 1] = t
        return true
    end
    if urgent then
        keepRecent(Z.urgentAt, t, 60000)
        if #Z.urgentAt < Z.URGENT_PER_MINUTE then
            Z.urgentAt[#Z.urgentAt + 1] = t
            return true
        end
    end
    return false
end

-- the events left out, as one: the last one's job and place, kind "warn", code "flood", n1 = how many
function Z.flood()
    local last = Z.lastDropped
    local e = {}
    for key, value in pairs(last or {}) do e[key] = value end
    e.kind, e.code, e.sev, e.n1 = "warn", "flood", "notice", Z.dropped
    e.text, e.detail, e.a1, e.a2, e.n2, e.after = nil, nil, nil, nil, nil, nil
    Z.dropped, Z.lastDropped = 0, nil
    Z.send(Z.playerOf(e.playerNum), "event", e)
end

-- an event to the server, with the key; nothing but the setting before a key is confirmed
function Z.forward(e)
    local player = Z.playerOf(e.playerNum)
    local to = Z.keyFor(player)
    if to == nil and e.kind ~= "pref" then return end
    e.to = to or ""
    local t = now()
    if not Z.allowed(e.kind == "stop" or e.sev == "critical", t) then
        Z.dropped = Z.dropped + 1
        Z.lastDropped = e
        return
    end
    if Z.dropped > 0 then Z.flood() end
    if Z.send(player, "event", e) and e.run ~= nil and Z.run and Z.run.run == e.run then
        Z.beatFor, Z.beatAt = e.run, t -- an event is a sign of life as good as a beat
    end
end

-- the job the events say is open (start, or running = true; closed by its stop)
local function track(e)
    local run = e.run
    if run == nil then return end
    if e.kind == "stop" then
        if Z.run and Z.run.run == run then Z.run = nil end
        Z.ended = run
        return
    end
    if (e.kind ~= "start" and e.running ~= true) or Z.ended == run then return end
    if Z.run == nil or Z.run.run ~= run then
        Z.run = { run = run }
        Z.beatFor, Z.beatAt = run, now() -- its first event is its first sign of life
    end
    Z.run.job, Z.run.title, Z.run.num = e.job or Z.run.job, e.title or Z.run.title, e.playerNum
end

-- AutoPilot's listener: a flat copy (strings, numbers, booleans), never the table AutoPilot made
function Z.receive(event)
    if type(event) ~= "table" then return end
    local e = {}
    for key, value in pairs(event) do
        local kind = type(value)
        if type(key) == "string" and (kind == "string" or kind == "number" or kind == "boolean") then e[key] = value end
    end
    e.to = nil
    if e.run ~= nil then e.run = tostring(e.run) end
    track(e)
    if Z.state == "hello" or Z.state == "waiting" then
        Z.waiting[#Z.waiting + 1] = e
        while #Z.waiting > Z.WAITING_KEEP do table.remove(Z.waiting, 1) end
    elseif Z.state == "ready" then
        Z.forward(e)
    end
end

-- the beat: every BEAT_MS while a job runs, the first one as soon as a job is seen (with the setting on and a key)
function Z.beat(t)
    local run = Z.run or Z.autoPilotRun()
    if run == nil or run.run == Z.ended or Z.mode() == "off" then return end
    local player = Z.playerOf(run.num)
    if Z.keyFor(player) == nil then return end
    if Z.beatFor == run.run and t - Z.beatAt < Z.BEAT_MS then return end
    if Z.send(player, "beat", { run = run.run, job = run.job, title = run.title }) then
        Z.beatFor, Z.beatAt = run.run, t
    end
end

-- -- from the server -------------------------------------------------------------------------------------------------
function Z.onWelcome(args)
    if Z.notify == nil then return end
    Z.sess = type(args.sess) == "string" and args.sess or nil
    Z.state = "ready"
    local waiting = Z.waiting
    Z.waiting = {}
    for _, e in ipairs(waiting) do Z.forward(e) end
end

function Z.ack(id, action, result)
    Z.send(Z.mainPlayer(), "ack", { id = id, action = action, result = result })
end

function Z.logout(id)
    if Z.leaving then return Z.ack(id, "logout", "leaving") end
    local players = 1
    pcall(function() players = getNumActivePlayers() end)
    if (tonumber(players) or 1) > 1 then return Z.ack(id, "logout", "splitscreen") end -- both would leave
    local cooldown = false
    pcall(function() cooldown = isQuitCooldown() == true end)
    if cooldown then return Z.ack(id, "logout", "cooldown") end -- the game itself greys «Esci» out now
    Z.stopAutoPilot()
    local player = Z.mainPlayer()
    if player then pcall(function() ISTimedActionQueue.clear(player) end) end
    Z.ack(id, "logout", "leaving")
    Z.leaving = { ticks = 0, at = now() }
end

-- the way out of «Esci» (and of the death screen, whose window goes first), once
function Z.exit()
    pcall(setGameSpeed, 1)
    pcall(pauseSoundAndMusic)
    pcall(setShowPausedMessage, true)
    pcall(function()
        for _, window in pairs(ISPostDeathUI.instance) do window:removeFromUIManager() end
    end)
    local ok, err = pcall(function() getCore():exitToMenu() end)
    if not ok then print("ZomBotAutoPilot: cannot leave: " .. tostring(err)) end
end

-- OnTickEvenPaused: the logout waits LOGOUT_TICKS ticks and LOGOUT_MS, for the ack to leave first
function Z.exitTick()
    local leaving = Z.leaving
    if leaving == nil or leaving.done then return end
    leaving.ticks = leaving.ticks + 1
    if leaving.ticks < Z.LOGOUT_TICKS or now() - leaving.at < Z.LOGOUT_MS then return end
    leaving.done = true
    Z.exit()
end

function Z.closeDialog()
    local dialog = Z.dialog
    Z.dialog, Z.asking = nil, nil
    if dialog then
        pcall(function()
            dialog:setVisible(false)
            dialog:removeFromUIManager()
        end)
    end
end

-- «Gli avvisi di AutoPilot andranno a <nome>. Sei tu?», once for a key this account has not confirmed here
function Z.ask(key, name)
    if Z.dialog and Z.asking == key then return end
    Z.closeDialog()
    local ok, dialog = pcall(function()
        local width, height = 460, 140
        local x = (getCore():getScreenWidth() - width) / 2
        local y = (getCore():getScreenHeight() - height) / 2
        local num = 0
        pcall(function() num = getPlayer():getPlayerNum() end)
        local d = ISModalDialog:new(x, y, width, height, Z.text("confirm", name), true, Z, Z.onConfirm, num, key, name)
        d:initialise()
        d:addToUIManager()
        return d
    end)
    if ok and dialog then
        Z.dialog, Z.asking = dialog, key
    else
        print("ZomBotAutoPilot: cannot ask: " .. tostring(dialog))
        Z.status("nolink")
    end
end

function Z.onConfirm(_, button, key, name)
    Z.dialog, Z.asking = nil, nil
    if Z.mainUser == nil then return end
    if button and button.internal == "YES" then
        Z.keys[Z.mainUser] = key
        Z.saveKeys()
        Z.active = key
        Z.declined[key] = nil
        Z.status("ok", name)
        Z.chat(Z.text("confirmed", name))
        -- the bot learns of the «Sì» from the first event with the key: the setting, now with it
        Z.receive({ v = 1, kind = "pref", code = "pref", sev = "info", mode = Z.mode(), lang = Z.lang(), seq = 0,
            running = false, dur = 0, playerNum = 0 })
    else
        Z.declined[key] = true
        Z.active = nil
        Z.status("nolink")
        Z.chat(Z.text("declined", name))
    end
end

function Z.linkinfo(text)
    text = tostring(text or "")
    local key, name = string.match(text, "^ok|(%x+)|(.*)$")
    if key then
        key = hexId(key, 12) -- the contract's key: 12 hex
        if key == nil or Z.mainUser == nil then return end
        name = cleanName(name)
        if Z.keys[Z.mainUser] == key then
            Z.active = key
            Z.status("ok", name)
            return
        end
        Z.active = nil -- a key not confirmed here: nothing but the setting leaves until «Sì»
        if Z.declined[key] then
            Z.status("nolink")
            return
        end
        Z.ask(key, name)
    elseif text == "nolink" or text == "dmclosed" then
        Z.status(text)
        Z.chatOnce(text)
    elseif text == "botoff" then
        Z.status("botoff")
    end
end

function Z.onControl(args)
    local id = hexId(args.id, 32)
    if id == nil then return end
    if args.action == "stop" then
        Z.ack(id, "stop", Z.stopAutoPilot())
    elseif args.action == "logout" then
        Z.logout(id)
    elseif args.action == "linkinfo" then
        Z.linkinfo(args.text)
    end
end

function Z.onServerCommand(module, command, args)
    if module ~= Z.MODULE then return end
    if type(args) ~= "table" then args = {} end
    if command == "welcome" then
        Z.onWelcome(args)
    elseif command == "control" then
        Z.onControl(args)
    end
end

-- -- start -----------------------------------------------------------------------------------------------------------
function Z.start()
    if Z.begun then return end
    Z.begun = true
    if Z.notify then pcall(Z.notify.unsubscribe, Z.notify, Z.listener) end
    Z.notify, Z.state, Z.helloAt, Z.sess = nil, "none", 0, nil
    Z.waiting, Z.sentAt, Z.urgentAt, Z.dropped, Z.lastDropped = {}, {}, {}, 0, nil
    Z.run, Z.ended, Z.beatFor, Z.beatAt = nil, nil, nil, 0
    Z.said, Z.declined, Z.active, Z.mainUser, Z.leaving = {}, {}, nil, nil, nil
    Z.closeDialog()
    Z.loadKeys()
    Z.nextStep = 0
    Z.detectUntil = now() + Z.DETECT_MS
    Z.detect()
end

function Z.tick()
    if not Z.begun then Z.start() end
    local t = now()
    if t < Z.nextStep then return end
    Z.nextStep = t + Z.STEP_MS
    local state = Z.state
    if state == "none" then
        if t <= Z.detectUntil then Z.detect() end
    elseif state == "hello" then
        Z.hello()
    elseif state == "waiting" then
        if t - Z.helloAt >= Z.WELCOME_MS then
            -- the server has no bridge (yet): nothing more leaves this game
            Z.state, Z.waiting = "noserver", {}
            Z.status("noserver")
        end
    elseif state == "ready" then
        if Z.dropped > 0 and Z.allowed(false, t) then Z.flood() end
        Z.beat(t)
    end
end

local function safe(f, name)
    return function(...)
        local ok, err = pcall(f, ...)
        if not ok then print("ZomBotAutoPilot: " .. name .. " failed: " .. tostring(err)) end
    end
end

if not Z.registered then
    Z.registered = true
    Events.OnServerCommand.Add(safe(function(...) Z.onServerCommand(...) end, "server command"))
    Events.OnGameStart.Add(safe(function() Z.start() end, "start"))
    Events.OnTick.Add(safe(function() Z.tick() end, "tick"))
    local exitEvent = Events.OnTickEvenPaused or Events.OnTick
    exitEvent.Add(safe(function() Z.exitTick() end, "logout"))
end
