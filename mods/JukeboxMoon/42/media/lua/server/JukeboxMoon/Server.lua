-- JukeboxMoon: the server decides everything (FR-07, FR-13, FR-14). It converts the game's jukebox into one with a
-- container, keeps the state of every jukebox that plays (in memory: after a restart they are all off), moves to the
-- next track when the catalogue says the track is over, stops without power or CDs, and takes boredom and stress off
-- the players in range. Clients only play the pieces of audio the state says (client/JukeboxMoon/Player.lua).
--
-- Commands (module "JukeboxMoon"), client -> server:
--   hello {t0}            the state of every jukebox that plays, the server's clock and catalogue version
--   ping {t0}             the server's clock
--   open {x, y, z}        convert the jukebox if needed; answer "opened"
--   play {x, y, z, cd?, track?}, stop, next, prev {x, y, z}, shuffle {x, y, z, on}
--   spawn {album, count}  admins only
-- server -> clients: welcome, key {key, id} (the music's key), pong, opened, notice {key?, what}, state {...} (to
-- everyone).
-- The game's multiplayer client loads media/lua/server too: it stops here.
if isClient() then return end

require "JukeboxMoon/Core"
require "JukeboxMoon/Catalog"
require "JukeboxMoon/Playlist"
require "JukeboxMoon/Box"
require "JukeboxMoon/Mood"

if JukeboxMoon.Server then return JukeboxMoon.Server end

local Core = JukeboxMoon.Core
local Catalog = JukeboxMoon.Catalog
local Playlist = JukeboxMoon.Playlist
local Box = JukeboxMoon.Box
local Mood = JukeboxMoon.Mood
local MODULE = Core.MODULE

local Server = {}
JukeboxMoon.Server = Server

Server.active = {}      -- key -> { key, x, y, z, on, power, seq, entries, index, track, cd, start, ends, shuffle, rand }
Server.count = 0        -- how many are in `active`
Server.recent = {}      -- username -> times of the last commands (a few per seconds at most)
Server.minutes = {}     -- username -> game minutes in range since the last relief
Server.uniqueMinutes = {}   -- username -> of those, the minutes in range of a unique CD (unhappiness too)
Server.elapsed = 0      -- game minutes since the last relief
Server.lastTick = 0
Server.lastCheck = 0
Server.seq = 0

Server.TICK_MS = 250
Server.CHECK_MS = 1000
Server.RATE_COUNT = 8
Server.RATE_MS = 4000

local function now()
	return getTimestampMs()
end

------------------------------------------------------------------------------------------------- talking to clients

-- On a server, over the network. In single player there is no network and sendServerCommand does nothing (it sends
-- only when GameServer.server, 42.21; the game's own server files do "if isServer() then ... else ..."): the local
-- game's handlers get the message directly.
local function deliver(player, command, args)
	if isServer() then
		if player then
			sendServerCommand(player, MODULE, command, args)
		else
			sendServerCommand(MODULE, command, args)
		end
	else
		triggerEvent("OnServerCommand", MODULE, command, args)
	end
end

local function reply(player, command, args)
	deliver(player, command, args or {})
end

local function notice(player, what, key)
	reply(player, "notice", { what = what, key = key })
end
Server.notice = notice

-- What clients know of a jukebox: enough to play it and to show it, never the whole playlist (they read the CDs from
-- the container themselves).
function Server.public(state)
	return {
		key = state.key, x = state.x, y = state.y, z = state.z, on = state.on == true, seq = state.seq,
		track = state.track, cd = state.cd, start = state.start, ends = state.ends, index = state.index,
		count = #(state.entries or {}), shuffle = state.shuffle == true, reason = state.reason,
	}
end

function Server.list()
	local out = {}
	for _, state in pairs(Server.active) do out[#out + 1] = Server.public(state) end
	return out
end

local function broadcast(state)
	deliver(nil, "state", Server.public(state))
end

------------------------------------------------------------------------------------------------- the jukebox itself

function Server.objectAt(x, y, z)
	local cell = getCell()
	local square = cell and cell:getGridSquare(x, y, z)
	if not square then return nil, nil, nil end
	local object, index = Box.onSquare(square)
	return object, square, index
end

-- The game's tile becomes an IsoThumpable with a container, on the server: a thumpable with a container made by a
-- client is never saved (the idea is True Moozic's, the code ours). Returns the converted jukebox.
function Server.convert(square, object, index)
	if Box.isConverted(object) then
		Box.applyContainer(object)
		return object
	end
	local sprite = Box.spriteName(object)
	if not sprite then return nil end
	square:transmitRemoveItemFromSquare(object)
	local box = IsoThumpable.new(getCell(), square, sprite, false, {})
	box:setIsContainer(true)
	Box.applyContainer(box)
	box:setIsDismantable(false)
	box:setCanBarricade(false)
	box:setIsThumpable(false)
	box:setCanBeLockByPadlock(false)
	box:setBlockAllTheSquare(true)
	box:setMaxHealth(500)
	box:setHealth(500)
	if index and index <= square:getObjects():size() then
		square:AddSpecialObject(box, index)
	else
		square:AddSpecialObject(box)
	end
	box:transmitCompleteItemToClients()
	square:RecalcProperties()
	square:RecalcAllWithNeighbours(true)
	Core.log("converted the jukebox at " .. Box.keyOf(box))
	return box
end

------------------------------------------------------------------------------------------------- playing

-- Start entry `index` of the state's playlist, LEAD_MS from now. A track the catalogue does not know (an older
-- catalogue on the server than the CD) is skipped; with none playable the jukebox stops.
function Server.start(state, index)
	local entries = state.entries
	for _ = 1, #entries do
		local entry = entries[index]
		local track = entry and Catalog.track(entry.track)
		if track and (tonumber(track.ms) or 0) > 0 then
			Server.seq = Server.seq + 1
			state.on = true
			state.index = index
			state.track = entry.track
			state.cd = entry.cd
			state.start = now() + Core.LEAD_MS
			state.ends = state.start + track.ms
			state.seq = Server.seq
			state.reason = nil
			broadcast(state)
			return true
		end
		index = (index % #entries) + 1
	end
	Server.stop(state, "unavailable")
	return false
end

function Server.stop(state, reason)
	if Server.active[state.key] then
		Server.active[state.key] = nil
		Server.count = Server.count - 1
	end
	Server.seq = Server.seq + 1
	state.on = false
	state.reason = reason or "off"
	state.seq = Server.seq
	broadcast(state)
end

-- The state of a jukebox about to get a command: the one that plays, brought up to date with its CDs, or a new one.
local function stateFor(object)
	local key = Box.keyOf(object)
	local state = Server.active[key]
	if state then
		Server.check(state)
		state = Server.active[key]
		if state then return state end
	end
	local settings = Box.settings(object)
	local x, y, z = math.floor(object:getX()), math.floor(object:getY()), math.floor(object:getZ())
	return {
		key = key, x = x, y = y, z = z,
		on = false, power = true, entries = Playlist.build(Box.cds(object)), index = nil, seq = 0,
		-- a new random order every time it is switched on, different for every jukebox
		shuffle = settings.shuffle and Core.option("ShuffleAllowed"), rand = Playlist.seed(now() + x * 7919 + y * 104729),
	}
end

local function activate(state)
	if not Server.active[state.key] then
		Server.active[state.key] = state
		Server.count = Server.count + 1
	end
end

-- The next or previous track (dir 1 or -1), or a random one with shuffle.
function Server.advance(state, dir)
	local index, rand = Playlist.step(#state.entries, state.index, dir, state.shuffle, state.rand)
	state.rand = rand
	if not index then
		Server.stop(state, "nocd")
		return
	end
	Server.start(state, index)
end

------------------------------------------------------------------------------------------------- every tick and second

-- Is the object still there, powered, with which CDs? Only when the server has its square loaded (somebody is near).
function Server.check(state)
	local object, square = Server.objectAt(state.x, state.y, state.z)
	if not square then return end              -- not loaded: it goes on with what it knows
	if not object or not Box.isConverted(object) then
		Server.stop(state, "gone")
		return
	end
	Box.applyContainer(object)
	if not Box.hasPower(object) then
		state.power = false
		Server.stop(state, "nopower")
		return
	end
	state.power = true
	local entries = Playlist.build(Box.cds(object))
	if not Playlist.same(entries, state.entries) then
		local index, moved = Playlist.follow(state.entries, state.index, entries)
		state.entries = entries
		if not index then
			Server.stop(state, "nocd")
		elseif moved then
			Server.start(state, index)
		else
			state.index = index
			broadcast(state)
		end
	end
end

function Server.onTick()
	if Server.count == 0 then return end
	local t = now()
	if t - Server.lastTick < Server.TICK_MS then return end
	Server.lastTick = t
	local check = t - Server.lastCheck >= Server.CHECK_MS
	if check then Server.lastCheck = t end
	local states = {}
	for _, state in pairs(Server.active) do states[#states + 1] = state end
	for _, state in ipairs(states) do
		if check then Server.check(state) end
		if state.on and t >= state.ends then Server.advance(state, 1) end
	end
end

------------------------------------------------------------------------------------------------- boredom and stress

-- The players of this game: every one connected on a server, the local ones in single player.
function Server.players()
	local out = {}
	if isServer() then
		local list = getOnlinePlayers()
		for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
	else
		for i = 0, getNumActivePlayers() - 1 do
			local player = getSpecificPlayer(i)
			if player then out[#out + 1] = player end
		end
	end
	return out
end

local function hasTrait(player, trait)
	local ok, has = pcall(function() return trait ~= nil and player:hasTrait(trait) end)
	return ok and has == true
end

function Server.relieve(player, minutes, uniqueMinutes)
	local deaf = hasTrait(player, CharacterTrait.DEAF)
	local hard = hasTrait(player, CharacterTrait.HARD_OF_HEARING)
	local multiplier = Mood.multiplier(deaf, hard)
	if multiplier <= 0 then return end
	local stats = player:getStats()
	-- unhappiness only after minutes with a unique CD (Mood.uniqueInRange): read only then
	local unhappyNow = 0
	if (uniqueMinutes or 0) > 0 then
		local ok, value = pcall(function() return stats:get(CharacterStat.UNHAPPINESS) end)
		unhappyNow = ok and tonumber(value) or 0
	end
	local boredom, stress, unhappiness = Mood.relief(minutes, multiplier,
		stats:get(CharacterStat.BOREDOM), stats:get(CharacterStat.STRESS), uniqueMinutes, unhappyNow)
	if boredom <= 0 and stress <= 0 and unhappiness <= 0 then return end
	if boredom > 0 then stats:remove(CharacterStat.BOREDOM, boredom) end
	if stress > 0 then stats:remove(CharacterStat.STRESS, stress) end
	if unhappiness > 0 then stats:remove(CharacterStat.UNHAPPINESS, unhappiness) end
	-- the player's stats belong to the server: tell the player's game, as the game's own farming does
	if isServer() then
		pcall(function()
			local mask = SyncPlayerStatsPacket.getBitMaskForStat(CharacterStat.BOREDOM)
				+ SyncPlayerStatsPacket.getBitMaskForStat(CharacterStat.STRESS)
			if unhappiness > 0 then mask = mask + SyncPlayerStatsPacket.getBitMaskForStat(CharacterStat.UNHAPPINESS) end
			syncPlayerStats(player, mask)
		end)
	end
	-- the words over the head with the green arrow, as the game's TV and VHS do (09/11/2026, the user): only to who
	-- got the relief, once per evaluation (MoodEvaluationMinutes), never to a deaf player (multiplier 0, above)
	reply(player, "relief", { boredom = boredom > 0 and 1 or 0, stress = stress > 0 and 1 or 0,
		unhappiness = unhappiness > 0 and 1 or 0 })
end

function Server.everyMinute()
	if not Core.option("Enabled") or not Core.option("MoodEffectsEnabled") then return end
	if Server.count > 0 then
		local t = now()
		for _, player in ipairs(Server.players()) do
			if not player:isDead() and Mood.anyInRange(Server.active, player:getX(), player:getY(), player:getZ(), t) then
				local name = player:getUsername() or "?"
				Server.minutes[name] = (Server.minutes[name] or 0) + 1
				if Mood.uniqueInRange(Server.active, player:getX(), player:getY(), player:getZ(), t) then
					Server.uniqueMinutes[name] = (Server.uniqueMinutes[name] or 0) + 1
				end
			end
		end
	end
	Server.elapsed = Server.elapsed + 1
	if Server.elapsed < Core.option("MoodEvaluationMinutes") then return end
	Server.elapsed = 0
	local minutes, unique = Server.minutes, Server.uniqueMinutes
	Server.minutes, Server.uniqueMinutes = {}, {}
	for _, player in ipairs(Server.players()) do
		local name = player:getUsername() or "?"
		local m = minutes[name]
		if m and m > 0 and not player:isDead() then Server.relieve(player, m, unique[name] or 0) end
	end
end

------------------------------------------------------------------------------------------------- commands

function Server.allowed(player)
	local name = player:getUsername() or "?"
	local t = now()
	local times = Server.recent[name] or {}
	local kept = {}
	for _, at in ipairs(times) do
		if t - at < Server.RATE_MS then kept[#kept + 1] = at end
	end
	if #kept >= Server.RATE_COUNT then
		Server.recent[name] = kept
		return false
	end
	kept[#kept + 1] = t
	Server.recent[name] = kept
	return true
end

-- The jukebox a player asks about, if the player can use it: alive, on the same floor, close enough.
function Server.reach(player, args)
	if type(args) ~= "table" then return nil end
	local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
	if not x or not y or not z then return nil end
	x, y, z = math.floor(x), math.floor(y), math.floor(z)
	if player:isDead() or math.floor(player:getZ()) ~= z then return nil end
	local dx, dy = player:getX() - (x + 0.5), player:getY() - (y + 0.5)
	if dx * dx + dy * dy > Core.USE_TILES * Core.USE_TILES then return nil end
	local object, square, index = Server.objectAt(x, y, z)
	if not object then return nil end
	return object, square, index
end

local Commands = {}
Server.Commands = Commands

------------------------------------------------------------------------------------------------- the music's key

-- The key that opens the music published on GitHub (docs/jukebox/TECHNICAL_DESIGN.md, "La chiave"): two lines in
-- Zomboid/Lua/JukeboxMoon_server_key.txt on the server, written by tools/jukebox publish: 64 hex characters and the
-- key's id. Every player let in by the server receives it; the launcher uses it to download the albums.
Server.KEY_FILE = "JukeboxMoon_server_key.txt"

function Server.readKey()
	local ok, key, id = pcall(function()
		local reader = getFileReader(Server.KEY_FILE, false)
		if not reader then return nil, nil end
		local key = reader:readLine()
		local id = reader:readLine()
		reader:close()
		return key, id
	end)
	if not ok or type(key) ~= "string" or type(id) ~= "string" then return nil end
	key, id = string.lower(key), string.lower(id)
	if not string.match(key, "^%x+$") or #key ~= 64 or not string.match(id, "^%x+$") or #id ~= 16 then
		Core.warn(Server.KEY_FILE .. " is not a key: no music for the launchers")
		return nil
	end
	return { key = key, id = id }
end

Server.key = Server.readKey()

function Commands.hello(player, args)
	reply(player, "welcome", {
		t0 = type(args) == "table" and tonumber(args.t0) or 0, now = now(), version = Catalog.version(),
		list = Server.list(),
	})
	if Server.key then reply(player, "key", { key = Server.key.key, id = Server.key.id }) end
end

function Commands.ping(player, args)
	reply(player, "pong", { t0 = type(args) == "table" and tonumber(args.t0) or 0, now = now() })
end

function Commands.open(player, args)
	local object, square, index = Server.reach(player, args)
	if not object then return notice(player, "far") end
	object = Server.convert(square, object, index)
	if not object then return notice(player, "far") end
	reply(player, "opened", { x = math.floor(object:getX()), y = math.floor(object:getY()), z = math.floor(object:getZ()) })
end

-- The converted jukebox a command is about, ready to play: nil (and a notice) when it cannot.
local function playable(player, args)
	local object = Server.reach(player, args)
	if not object or not Box.isConverted(object) then
		notice(player, "far")
		return nil
	end
	Box.applyContainer(object)
	local key = Box.keyOf(object)
	if not Core.option("Enabled") then
		notice(player, "disabled", key)
		return nil
	end
	if not Catalog.available() then
		notice(player, "nocatalog", key)
		return nil
	end
	if not Box.hasPower(object) then
		notice(player, "nopower", key)
		return nil
	end
	local state = stateFor(object)
	if #state.entries == 0 then
		notice(player, "nocd", key)
		return nil
	end
	return state, object
end

function Commands.play(player, args)
	local state = playable(player, args)
	if not state then return end
	local index = nil
	local cd, track = tonumber(args.cd), tonumber(args.track)
	if cd and track then index = Playlist.indexOf(state.entries, cd, track) end
	if not index then
		if state.on and state.index then return end        -- already playing, nothing chosen: nothing to do
		index = 1
		if state.shuffle and #state.entries > 1 then
			index, state.rand = Playlist.step(#state.entries, 0, 1, true, state.rand)
		end
	end
	activate(state)
	Server.start(state, index)
end

function Commands.stop(player, args)
	local object = Server.reach(player, args)
	if not object then return notice(player, "far") end
	local state = Server.active[Box.keyOf(object)]
	if state then Server.stop(state, "off") end
end

local function step(player, args, dir)
	local state = playable(player, args)
	if not state then return end
	if not state.on then
		state.index = state.index or 0
	end
	activate(state)
	Server.advance(state, dir)
end

function Commands.next(player, args) step(player, args, 1) end
function Commands.prev(player, args) step(player, args, -1) end

function Commands.shuffle(player, args)
	local object = Server.reach(player, args)
	if not object or not Box.isConverted(object) then return notice(player, "far") end
	local on = args.on == true and Core.option("ShuffleAllowed")
	local state = Server.active[Box.keyOf(object)]
	local settings = Box.settings(object)
	settings.shuffle = on
	object:transmitModData()
	if state then
		state.shuffle = on
		broadcast(state)
	end
end

function Commands.spawn(player, args)
	if not Core.isAdmin(player) then return notice(player, "notadmin") end
	if type(args) ~= "table" then return end
	local count = math.floor(tonumber(args.count) or 0)
	if count < 1 or count > Core.SPAWN_MAX then return notice(player, "badcount") end
	local album = nil
	for _, a in ipairs(Catalog.activeAlbums()) do
		if a.key == tonumber(args.album) then album = a end
	end
	if not album then return notice(player, "noalbum") end
	-- a CD of the game: the game's disc with that recording
	local media = nil
	if album.media then
		local ok, found = pcall(function() return getZomboidRadio():getRecordedMedia():getMediaData(album.media) end)
		media = ok and found or nil
		if not media then return notice(player, "noalbum") end
	end
	local inventory = player:getInventory()
	local made = 0
	for _ = 1, count do
		local item = inventory:AddItem(album.item or Catalog.GAME_CD)
		if item then
			if media then item:setRecordedMediaData(media) end
			made = made + 1
			if isServer() then sendAddItemToContainer(inventory, item) end
		end
	end
	Core.warn(string.format("%s made %d CD of album %d", tostring(player:getUsername()), made, album.key))
	reply(player, "notice", { what = "spawned", count = made })
end

-- hello and ping have their own limit: one a second each (the game asks one every 2 s at most), so a modified client
-- cannot make the server send the whole list and the key as fast as it likes.
Server.QUIET_MS = 1000
Server.asked = {}       -- "username command" -> last time

function Server.quiet(player, command)
	local name = (player:getUsername() or "?") .. " " .. command
	local t = now()
	if t - (Server.asked[name] or -Server.QUIET_MS) < Server.QUIET_MS then return false end
	Server.asked[name] = t
	return true
end

function Server.onClientCommand(module, command, player, args)
	if module ~= MODULE or not player then return end
	local handler = Commands[command]
	if not handler then return end
	if command == "hello" or command == "ping" then
		if not Server.quiet(player, command) then return end
	elseif not Server.allowed(player) then
		return
	end
	local ok, err = pcall(handler, player, args)
	if not ok then Core.warn("command " .. tostring(command) .. ": " .. tostring(err)) end
end

Events.OnClientCommand.Add(Server.onClientCommand)
Events.OnTick.Add(Server.onTick)
Events.EveryOneMinute.Add(Server.everyMinute)

return Server
