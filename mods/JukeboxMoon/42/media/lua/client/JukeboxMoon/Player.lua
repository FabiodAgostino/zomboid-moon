-- JukeboxMoon: what a client hears. The server says which jukeboxes play what since when (command "state"); this file
-- plays, for each one within HEAR_TILES, the piece of audio of that moment (tools/jukebox cuts every track in pieces of
-- segmentMs, each overlapping the next by overlapMs). The game cannot start a sound file halfway, so whoever arrives
-- in the middle of a piece waits for the next one: everybody hears the same point (FR-03). A client never decides
-- anything for the others: out of range it simply plays nothing (AT-09).
--
-- The clock: the server's getTimestampMs() is not the client's. The client asks "ping" with its own time and keeps
-- the offset of the quickest answer among the last eight.

require "JukeboxMoon/Core"
require "JukeboxMoon/Catalog"
require "JukeboxMoon/Box"

if JukeboxMoon.Player then return JukeboxMoon.Player end

local Core = JukeboxMoon.Core
local Catalog = JukeboxMoon.Catalog
local Box = JukeboxMoon.Box
local MODULE = Core.MODULE

local Player = {}
JukeboxMoon.Player = Player

Player.boxes = {}          -- key -> the server's state of a jukebox (on or off: the window shows why it stopped)
Player.audio = {}          -- key -> { seq, segment, sounds = { { emitter, id, segment } } }
Player.samples = {}        -- { rtt, offset } of the last answers
Player.offset = 0
Player.synced = false
Player.serverVersion = nil
Player.welcomed = false
Player.volume = 0.7
Player.listeners = {}      -- functions called when a state or a notice arrives (the window)

Player.SAMPLES = 8
Player.CONTINUE_MS = 1000  -- a piece that follows the one playing may start this late (a slow frame)
Player.VOLUME_FILE = "JukeboxMoon_volume.txt"
Player.VOLUME_SAVE_MS = 1000   -- the slider moves many times a second: the file is written once it stops
Player.volumeChangedAt = nil

------------------------------------------------------------------------------------------------- clock

function Player.serverNow()
	return getTimestampMs() + Player.offset
end

function Player.sample(t0, serverMs)
	t0, serverMs = tonumber(t0), tonumber(serverMs)
	if not t0 or not serverMs then return end
	local t1 = getTimestampMs()
	local rtt = t1 - t0
	if rtt < 0 then return end
	table.insert(Player.samples, { rtt = rtt, offset = serverMs - (t0 + t1) / 2 })
	while #Player.samples > Player.SAMPLES do table.remove(Player.samples, 1) end
	local best = Player.samples[1]
	for _, s in ipairs(Player.samples) do
		if s.rtt < best.rtt then best = s end
	end
	Player.offset = best.offset
	Player.synced = true
end

------------------------------------------------------------------------------------------------- what can be played

-- nil when this game can play the jukeboxes, else why not: "nocatalog" (no music installed) or "update" (another
-- catalogue than the server's: the launcher must update it). Fail closed: no sound for an unknown id.
function Player.problem()
	if not Catalog.available() then return "nocatalog" end
	if Player.serverVersion ~= nil and Player.serverVersion ~= Catalog.version() then return "update" end
	return nil
end

------------------------------------------------------------------------------------------------- the local volume

function Player.loadVolume()
	local ok, value = pcall(function()
		local reader = getFileReader(Player.VOLUME_FILE, false)
		if not reader then return nil end
		local line = reader:readLine()
		reader:close()
		return tonumber(line)
	end)
	if ok and value and value >= 0 and value <= 1 then Player.volume = value end
end

-- The sounds follow the slider at once; the file is written by saveVolume, a second after the last change.
function Player.setVolume(value)
	value = math.max(0, math.min(1, tonumber(value) or Player.volume))
	Player.volume = value
	for _, audio in pairs(Player.audio) do
		for _, sound in ipairs(audio.sounds) do
			pcall(function() sound.emitter:setVolume(sound.id, value) end)
		end
	end
	Player.volumeChangedAt = getTimestampMs()
end

function Player.saveVolume(force)
	if not Player.volumeChangedAt then return end
	if not force and getTimestampMs() - Player.volumeChangedAt < Player.VOLUME_SAVE_MS then return end
	Player.volumeChangedAt = nil
	pcall(function()
		local writer = getFileWriter(Player.VOLUME_FILE, true, false)
		writer:write(tostring(Player.volume))
		writer:close()
	end)
end

------------------------------------------------------------------------------------------------- playing

function Player.stopAudio(key)
	local audio = Player.audio[key]
	if not audio then return end
	for _, sound in ipairs(audio.sounds) do
		pcall(function() sound.emitter:stopSound(sound.id) end)
	end
	Player.audio[key] = nil
end

function Player.stopAll()
	local keys = {}
	for key in pairs(Player.audio) do keys[#keys + 1] = key end
	for _, key in ipairs(keys) do Player.stopAudio(key) end
end

-- The game's own sound of a jukebox: its sprite has AmbientSound = JukeboxAmbiance, and the game gives every object
-- with that property an ambient emitter when it enters the world (IsoObject.addToWorld, 42.21), the converted one too.
-- While ours plays it would play under the music: it goes (it comes back when the square is loaded again).
function Player.quietGameSound(box)
	pcall(function()
		local square = getCell():getGridSquare(box.x, box.y, box.z)
		local object = square and Box.onSquare(square)
		local chunk = object and square:getChunk()
		if chunk and Box.isConverted(object) and chunk:hasObjectAmbientEmitter(object) then
			chunk:removeObjectAmbientEmitter(object)
		end
	end)
end

-- Piece `segment` of the track the jukebox plays, from a free emitter of the world on the jukebox's square. The
-- piece before keeps playing its last overlapMs, which fade out while this one fades in.
function Player.startPiece(box, audio, segment)
	Player.quietGameSound(box)
	local world = getWorld()
	local emitter = world and world:getFreeEmitter(box.x + 0.5, box.y + 0.5, box.z)
	if not emitter then return false end
	emitter:setPos(box.x + 0.5, box.y + 0.5, box.z)
	-- playSoundImpl: only here. playSound on a client also sends the sound to every other client near (PlayWorldSound,
	-- 42.21), and each of them already plays its own piece: they would hear it twice, late.
	local id = emitter:playSoundImpl(Catalog.soundName(box.track, segment), false, nil)
	if not id or id == 0 then return false end
	emitter:set3D(id, true)
	emitter:setVolume(id, Player.volume)
	audio.segment = segment
	table.insert(audio.sounds, { emitter = emitter, id = id, segment = segment })
	while #audio.sounds > 2 do
		local old = table.remove(audio.sounds, 1)
		pcall(function() old.emitter:stopSound(old.id) end)
	end
	return true
end

local function inRange(player, box)
	if math.abs(math.floor(player:getZ()) - box.z) > 1 then return false end
	local dx, dy = player:getX() - (box.x + 0.5), player:getY() - (box.y + 0.5)
	return dx * dx + dy * dy <= Core.HEAR_TILES * Core.HEAR_TILES
end

-- One jukebox, every tick.
function Player.manage(key, box, player, nowMs)
	local track = box.on and Catalog.track(box.track) or nil
	if not track or not inRange(player, box) then
		Player.stopAudio(key)
		return
	end
	local audio = Player.audio[key]
	if audio and audio.seq ~= box.seq then
		Player.stopAudio(key)
		audio = nil
	end
	local elapsed = nowMs - box.start
	if elapsed < 0 then return end
	local segMs = Catalog.segmentMs()
	local segment = math.floor(elapsed / segMs)
	if segment >= (tonumber(track.segments) or 0) then return end   -- over: the server moves on
	local into = elapsed - segment * segMs
	if not audio then
		if into > Core.JOIN_MS then return end                       -- in the middle of a piece: the next one
		audio = { seq = box.seq, segment = -1, sounds = {} }
		Player.audio[key] = audio
		Player.startPiece(box, audio, segment)
		return
	end
	if segment > audio.segment then
		local late = segment == audio.segment + 1 and Player.CONTINUE_MS or Core.JOIN_MS
		if into <= late then Player.startPiece(box, audio, segment) end
	end
end

function Player.onTick()
	local player = getPlayer()
	if not player then return end
	if Player.problem() or not Player.synced then
		Player.stopAll()
		return
	end
	local nowMs = Player.serverNow()
	for key, box in pairs(Player.boxes) do
		if box.on then
			Player.manage(key, box, player, nowMs)
		elseif Player.audio[key] then
			Player.stopAudio(key)
		end
	end
end

------------------------------------------------------------------------------------------------- the server

function Player.send(command, args)
	local player = getPlayer()
	if not player then return end
	sendClientCommand(player, MODULE, command, args or {})
end

local function tell(kind, data)
	for _, listener in ipairs(Player.listeners) do
		pcall(listener, kind, data)
	end
end

function Player.receive(state)
	if type(state) ~= "table" or type(state.key) ~= "string" then return end
	local known = Player.boxes[state.key]
	if known and (tonumber(known.seq) or 0) > (tonumber(state.seq) or 0) then return end   -- an older message
	state.x, state.y, state.z = math.floor(tonumber(state.x) or 0), math.floor(tonumber(state.y) or 0),
		math.floor(tonumber(state.z) or 0)
	state.start, state.ends = tonumber(state.start) or 0, tonumber(state.ends) or 0
	state.track, state.cd = tonumber(state.track), tonumber(state.cd)
	Player.boxes[state.key] = state
	if not state.on then Player.stopAudio(state.key) end
	tell("state", state)
end

local Handlers = {}

function Handlers.welcome(args)
	Player.sample(args.t0, args.now)
	Player.serverVersion = args.version
	Player.welcomed = true
	Player.boxes = {}
	Player.stopAll()
	local list = args.list or {}
	for _, state in ipairs(list) do Player.receive(state) end
	tell("welcome", args)
end

function Handlers.pong(args)
	Player.sample(args.t0, args.now)
end

function Handlers.state(args)
	Player.receive(args)
end

function Handlers.opened(args)
	tell("opened", args)
end

-- The music's key, from the server: the launcher reads it from Zomboid/Lua/JukeboxMoon_key.txt to download and open
-- the albums (docs/jukebox/TECHNICAL_DESIGN.md, "La chiave"). Written only when it is a key and it changed.
Player.KEY_FILE = "JukeboxMoon_key.txt"

function Player.storedKey()
	local ok, key, id = pcall(function()
		local reader = getFileReader(Player.KEY_FILE, false)
		if not reader then return nil, nil end
		local key = reader:readLine()
		local id = reader:readLine()
		reader:close()
		return key, id
	end)
	if not ok then return nil, nil end
	return key, id
end

function Handlers.key(args)
	local key, id = tostring(args.key or ""), tostring(args.id or "")
	if #key ~= 64 or not string.match(key, "^%x+$") or #id ~= 16 or not string.match(id, "^%x+$") then return end
	local oldKey, oldId = Player.storedKey()
	if oldKey == key and oldId == id then return end
	pcall(function()
		local writer = getFileWriter(Player.KEY_FILE, true, false)
		writer:write(key .. "\n" .. id .. "\n")
		writer:close()
	end)
end

function Handlers.notice(args)
	tell("notice", args)
end

-- The server took boredom and/or stress off this player (Server.relieve): the same words and green arrow down as the
-- game's TV and VHS (ISRadioInteractions.addHalo -> HaloTextHelper.addTextWithArrow, IGUI_HaloNote_*).
function Handlers.relief(args)
	local player = getPlayer()
	if not player or not HaloTextHelper or not HaloTextHelper.addTextWithArrow then return end
	local color = HaloTextHelper.getGoodColor()
	if args.boredom == 1 then
		HaloTextHelper.addTextWithArrow(player, getText("IGUI_HaloNote_Boredom"), "[br/]", false, color)
	end
	if args.stress == 1 then
		HaloTextHelper.addTextWithArrow(player, getText("IGUI_HaloNote_Stress"), "[br/]", false, color)
	end
end

function Player.onServerCommand(module, command, args)
	if module ~= MODULE then return end
	local handler = Handlers[command]
	if handler and type(args) == "table" then handler(args) end
end

------------------------------------------------------------------------------------------------- starting

Player.pings = 0
Player.nextPing = 0

-- Five pings at the start (one every 2 s), then one every 5 minutes: the clock drifts very little.
function Player.everyTick()
	local t = getTimestampMs()
	if t < Player.nextPing then return end
	if not Player.welcomed then
		Player.send("hello", { t0 = t })
		Player.nextPing = t + 5000
		return
	end
	Player.send("ping", { t0 = t })
	Player.pings = Player.pings + 1
	Player.nextPing = t + (Player.pings < 5 and 2000 or 300000)
end

function Player.onGameStart()
	Player.loadVolume()
	Player.welcomed = false
	Player.nextPing = 0
end

Events.OnGameStart.Add(Player.onGameStart)
Events.OnServerCommand.Add(Player.onServerCommand)
Events.OnTick.Add(function()
	Player.everyTick()
	Player.onTick()
	Player.saveVolume(false)
end)

return Player
