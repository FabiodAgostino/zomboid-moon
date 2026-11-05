-- JukeboxMoon: the unique CDs (album.json "unique", docs/jukebox/TECHNICAL_DESIGN.md "Il CD unico"). One copy in the
-- server's whole story: never in the loot, never made by admins (Catalog.activeAlbums leaves it out). It is on a
-- running zombie that a player kills: every such kill rolls 1 in `oneIn` while the CD is waiting.
--
-- One at a time (the user's choice): only one unique CD is in play, the first by album number (the order albums enter
-- the catalogue) not found yet. It enters play (`since`, unix seconds) at the server's start or when the one before is
-- found; the others wait their turn. A CD back from a corpse nobody looted keeps its `since`.
--
-- What the server sees (42.21, read in projectzomboid.jar):
--   - IsoZombie.onKilled runs on the server: it fills the zombie's inventory, fires OnZombieDead, then makes the corpse
--     from that inventory (DoDeath): a CD added during the event lies on the corpse. getAttackedBy() is the killer.
--   - a runner: IsoZombie.getWalkType() starts with "sprint" (sprint1-5; the server's value, sent to the clients in
--     ZombiePacket).
--   - taking an item is a client action (media/lua/client/TimedActions/ISInventoryTransferAction.lua, ISGrabItemAction):
--     the server moves it in Java, with no Lua event. So the mod of whoever moves the CD tells the server ("taken",
--     client/JukeboxMoon/Finder.lua; the mod is required, every player has it), and the server checks once, then: the
--     player carries it (containsTypeRecurse, bags too), or is near where it fell and it is no longer on a corpse
--     there (put in a crate, a car, on the floor). The server does nothing on its own: no look every minute.
--   - a corpse nobody loots must not stop the queue (one at a time): the CD stays "dropped", and can drop again from
--     another runner (a new roll) once the server's corpse removal time has passed since it fell
--     (SandboxVars.HoursForCorpseRemoval, game hours: its corpse has gone with it), or FALLBACK_HOURS when the server
--     never removes corpses. Every copy that falls has its item id; the first copy a player takes is the CD
--     (found.copy). A copy taken after that, from an old corpse, is removed by the server from the player's inventory
--     (getItemWithIDRecursiv, Remove, sendRemoveItemFromContainer) with a word over the player's head: there is still
--     only one. A copy moved by a way the mod does not see is not told, and is not removed.
--
-- Saved in the world (global ModData "JukeboxMoon".unique, by album key):
--   { state = "waiting" | "dropped" | "found", since, name, artist, from, x, y, z, at, hours,
--     found = { user, character, at, from, test } }
-- name and artist are kept from the catalogue: an album taken out of it later keeps its line in the file.
-- Zomboid/Lua/jukeboxmoon_unique.json, rewritten whole at the start and at every change, is what ZomBOT reads (the
-- contract is ZomBOT's, zomboid-discord: do not change it on one side only). Every unique CD ever, by album number:
--   {"v":1,"unique":[{"key":"62","name":"CD: Love storii...","artist":"Prince","from":"runner","since":1762300000,
--                     "found":null}]}
--   from: where it hides (album.json unique.from: "runner", the running zombies)
--   since: null while it waits its turn; at most one line has since and no found (the one in play)
--   found: {"user":"<account>","character":"<name surname>","at":<unix s>,"from":"runner","test":false}
-- test is true in single player and in a game started with -debug (where the CD drops from the first runner, to try
-- it): ZomBOT announces nothing for it.
if isClient() then return end

require "JukeboxMoon/Core"
require "JukeboxMoon/Catalog"
require "JukeboxMoon/Server"

if JukeboxMoon.Unique then return JukeboxMoon.Unique end

local Core = JukeboxMoon.Core
local Catalog = JukeboxMoon.Catalog
local Server = JukeboxMoon.Server

local Unique = {}
JukeboxMoon.Unique = Unique

Unique.FILE = "jukeboxmoon_unique.json"
Unique.MODDATA = "JukeboxMoon"
Unique.SAME_ZOMBIE_MS = 10000   -- the fire paths fire OnZombieDead twice for one zombie
Unique.NEAR_TILES = 5           -- a player this close to where it fell can have put it in a crate or a car there
Unique.AROUND = 2               -- squares around where it fell: its corpse
Unique.FALLBACK_HOURS = 168     -- 7 game days: how long it waits for somebody when the server never removes corpses
Unique.recent = {}              -- zombie -> when it was rolled

local function try(f, default)
	local ok, value = pcall(f)
	if ok and value ~= nil then return value end
	return default
end

local function seconds()
	return math.floor(getTimestampMs() / 1000)
end

local function worldHours()
	return try(function() return getGameTime():getWorldAgeHours() end, 0)
end

-- Single player and -debug are trials: the bot announces nothing.
function Unique.testing()
	return not isServer() or try(function() return isDebugEnabled() end, false) == true
end

------------------------------------------------------------------------------------------------- the saved state

function Unique.data()
	local root = ModData.getOrCreate(Unique.MODDATA)
	if type(root.unique) ~= "table" then root.unique = {} end
	return root.unique
end

-- The saved entry of a catalogue's unique album, with its names (already escaped for JSON, generate.json_text).
function Unique.entry(album)
	local all = Unique.data()
	local key = tostring(album.key)
	if type(all[key]) ~= "table" then all[key] = { state = "waiting" } end
	local e = all[key]
	e.name, e.artist = album.unique.jsonName or e.name, album.unique.jsonArtist or e.artist
	e.from = album.unique.from or e.from
	return e
end

-- The catalogue's unique albums by number: the order they entered the catalogue.
function Unique.albums()
	local out = {}
	for _, album in ipairs(Catalog.uniqueAlbums()) do out[#out + 1] = album end
	table.sort(out, function(a, b) return a.key < b.key end)
	return out
end

-- The unique CD in play, or nil: since set and not found. When none is, the next by number enters play (since =
-- now) and the file says so.
function Unique.current()
	local upcoming = nil
	for _, album in ipairs(Unique.albums()) do
		local e = Unique.entry(album)
		if e.state ~= "found" then
			if e.since then return album, e end
			upcoming = upcoming or album
		end
	end
	if not upcoming then return nil, nil end
	local e = Unique.entry(upcoming)
	e.since = seconds()
	Core.warn("the unique CD of album " .. tostring(upcoming.key) .. " is now in play")
	Unique.write()
	return upcoming, e
end

------------------------------------------------------------------------------------------------- the file for ZomBOT

-- Names from the game (Java strings): quotes and backslashes escaped, every character beyond ASCII as \uXXXX, so the
-- file is the same whatever the encoding of the game's file writer. (No %s on players' texts: concatenation only.)
function Unique.esc(text)
	local out = {}
	text = tostring(text or "")
	for i = 1, #text do
		local c = string.byte(text, i)
		if c == 34 then
			out[#out + 1] = "\\\""
		elseif c == 92 then
			out[#out + 1] = "\\\\"
		elseif c < 32 or c > 126 then
			out[#out + 1] = string.format("\\u%04x", c)
		else
			out[#out + 1] = string.char(c)
		end
	end
	return table.concat(out)
end

local function whole(value)
	return string.format("%d", math.floor(tonumber(value) or 0))
end

-- Every unique CD ever (the saved entries, also of albums taken out of the catalogue later), by album number.
function Unique.json()
	for _, album in ipairs(Unique.albums()) do Unique.entry(album) end
	local keys = {}
	for key in pairs(Unique.data()) do
		if tonumber(key) then keys[#keys + 1] = tonumber(key) end
	end
	table.sort(keys)
	local list = {}
	for _, key in ipairs(keys) do
		local e = Unique.data()[tostring(key)]
		local found = "null"
		local f = e.found
		if e.state == "found" and type(f) == "table" then
			found = "{\"user\":\"" .. Unique.esc(f.user) .. "\",\"character\":\"" .. Unique.esc(f.character)
				.. "\",\"at\":" .. whole(f.at) .. ",\"from\":\"" .. Unique.esc(f.from) .. "\",\"test\":"
				.. (f.test == true and "true" or "false") .. "}"
		end
		-- name and artist come already escaped from the catalogue (tools/jukebox, generate.json_text)
		list[#list + 1] = "{\"key\":\"" .. tostring(key) .. "\",\"name\":\"" .. tostring(e.name or "")
			.. "\",\"artist\":\"" .. tostring(e.artist or "") .. "\",\"from\":\"" .. Unique.esc(e.from or "runner")
			.. "\",\"since\":" .. (e.since and whole(e.since) or "null")
			.. ",\"found\":" .. found .. "}"
	end
	return "{\"v\":1,\"unique\":[" .. table.concat(list, ",") .. "]}\n"
end

function Unique.write()
	local ok, err = pcall(function()
		local writer = getFileWriter(Unique.FILE, true, false)
		writer:write(Unique.json())
		writer:close()
	end)
	if not ok then Core.warn("cannot write " .. Unique.FILE .. ": " .. tostring(err)) end
end

------------------------------------------------------------------------------------------------- the drop

function Unique.isRunner(zombie)
	local walk = try(function() return zombie:getWalkType() end)
	return type(walk) == "string" and string.sub(walk, 1, 6) == "sprint"
end

function Unique.oneIn(album)
	if try(function() return isDebugEnabled() end, false) == true then return 1 end
	return math.max(1, math.floor(tonumber(album.unique.oneIn) or 1))
end

-- How long a CD that fell can wait for somebody, in game hours: the server's corpse removal time (its corpse goes
-- with it), or FALLBACK_HOURS on a server that never removes corpses (the old copy may still be there: if somebody
-- takes it once the CD is found, the server removes it, Unique.leftover).
function Unique.unclaimedHours()
	local hours = tonumber(SandboxVars and SandboxVars.HoursForCorpseRemoval) or -1
	if hours > 0 then return hours end
	return Unique.FALLBACK_HOURS
end

-- A CD that fell and nobody reported for that long: it can fall again.
function Unique.expired(e)
	return worldHours() - (tonumber(e.hours) or 0) >= Unique.unclaimedHours()
end

-- The unique CD that can fall from a runner now, or nil: the one in play, waiting or back from an unlooted corpse.
function Unique.open()
	local album, e = Unique.current()
	if not album or album.unique.from ~= "runner" then return nil end
	if e.state == "waiting" or (e.state == "dropped" and Unique.expired(e)) then return album end
	return nil
end

function Unique.onZombieDead(zombie)
	if not zombie then return end
	local album = Unique.open()
	if not album then return end
	-- a burning zombie leaves a burning corpse: it would take the CD with it
	if try(function() return zombie:isOnFire() end, false) then return end
	local killer = try(function() return zombie:getAttackedBy() end)
	if not killer or not instanceof(killer, "IsoPlayer") or instanceof(killer, "IsoAnimal") then return end
	if not Unique.isRunner(zombie) then return end
	local t = getTimestampMs()
	local old = {}
	for z, at in pairs(Unique.recent) do
		if t - at >= Unique.SAME_ZOMBIE_MS then old[#old + 1] = z end
	end
	for _, z in ipairs(old) do Unique.recent[z] = nil end
	if Unique.recent[zombie] then return end
	Unique.recent[zombie] = t
	if ZombRand(Unique.oneIn(album)) ~= 0 then return end
	local item = zombie:getInventory():AddItem(album.item)
	if not item then return end
	local e = Unique.entry(album)
	if e.state == "dropped" then
		Core.warn("the unique CD of album " .. tostring(album.key) .. " fell at " .. tostring(e.x) .. "," .. tostring(e.y)
			.. "," .. tostring(e.z) .. " and nobody took it before the corpses' removal time")
	end
	e.state = "dropped"
	e.x, e.y, e.z = math.floor(zombie:getX()), math.floor(zombie:getY()), math.floor(zombie:getZ())
	e.at = seconds()
	e.hours = worldHours()
	e.copy = try(function() return item:getID() end)
	Core.warn("the unique CD of album " .. tostring(album.key) .. " dropped from a runner at " .. e.x .. "," .. e.y .. ","
		.. e.z .. " killed by " .. tostring(try(function() return killer:getUsername() end, "?")))
	Unique.write()
end

------------------------------------------------------------------------------------------------- taken

local function holds(container, fullType)
	return container ~= nil and try(function() return container:containsTypeRecurse(fullType) end, false) == true
end

-- Still on a corpse where it fell (asked once, when a player says it was taken).
function Unique.onCorpse(e, fullType)
	local cell = getCell()
	if not cell then return false end
	for dx = -Unique.AROUND, Unique.AROUND do
		for dy = -Unique.AROUND, Unique.AROUND do
			local square = cell:getGridSquare(e.x + dx, e.y + dy, e.z)
			local bodies = square and try(function() return square:getDeadBodys() end)
			if bodies then
				for i = 0, bodies:size() - 1 do
					if holds(try(function() return bodies:get(i):getContainer() end), fullType) then return true end
				end
			end
		end
	end
	return false
end

function Unique.near(player, e)
	if math.floor(player:getZ()) ~= tonumber(e.z) then return false end
	local dx, dy = player:getX() - (e.x + 0.5), player:getY() - (e.y + 0.5)
	return dx * dx + dy * dy <= Unique.NEAR_TILES * Unique.NEAR_TILES
end

-- copy: the item id of the copy taken, the only one there is from now on (Unique.leftover)
function Unique.found(album, e, player, copy)
	e.state = "found"
	e.found = {
		user = try(function() return player:getUsername() end, "?"),
		character = try(function() return player:getFullName() end, ""),
		at = seconds(),
		from = album.unique.from,
		test = Unique.testing(),
		copy = copy,
	}
	Core.warn("the unique CD of album " .. tostring(album.key) .. " was found by " .. tostring(e.found.user))
	Unique.write()
	Unique.current()                                           -- the next one, if any, enters play
end

-- A copy of a CD already found, taken by a player (it fell on a corpse nobody looted, and the CD fell again): the
-- server removes it from the player's inventory and says why over the player's head.
function Unique.leftover(player, inventory, album, e, id)
	local real = type(e.found) == "table" and tonumber(e.found.copy) or nil
	if not id or not real or id == real or not inventory then return end
	local item = try(function() return inventory:getItemWithIDRecursiv(id) end)
	if not item or try(function() return item:getFullType() end) ~= album.item then return end
	local container = item:getContainer()
	if not container then return end
	pcall(function() player:removeFromHands(item) end)
	container:Remove(item)
	if isServer() then sendRemoveItemFromContainer(container, item) end
	Core.warn("a leftover copy of the unique CD of album " .. tostring(album.key) .. " taken by "
		.. tostring(try(function() return player:getUsername() end, "?")) .. " went")
	Server.notice(player, "leftover")
end

-- "taken {album, item}" from the mod of a player who moved the CD (client/JukeboxMoon/Finder.lua): checked once.
function Unique.taken(player, args)
	if type(args) ~= "table" or player:isDead() then return end
	local album = Catalog.albumByKey(tonumber(args.album))
	if not Catalog.isUnique(album) then return end
	local e = Unique.entry(album)
	local id = tonumber(args.item)
	local inventory = try(function() return player:getInventory() end)
	if e.state == "found" then return Unique.leftover(player, inventory, album, e, id) end
	if e.state ~= "dropped" then return end
	local carried = id and try(function() return inventory:getItemWithIDRecursiv(id) end)
	if carried and try(function() return carried:getFullType() end) ~= album.item then carried = nil end
	if not carried and holds(inventory, album.item) then
		carried = try(function() return inventory:getFirstTypeRecurse(album.item) end)
	end
	if not carried then
		-- not on the player: put somewhere where it fell (a crate, a car, the floor), and no longer on its corpse
		if not Unique.near(player, e) or Unique.onCorpse(e, album.item) then return end
	end
	local copy = carried and try(function() return carried:getID() end) or id
	Unique.found(album, e, player, copy)
end

Server.Commands.taken = Unique.taken
Events.OnZombieDead.Add(function(zombie)
	local ok, err = pcall(Unique.onZombieDead, zombie)
	if not ok then Core.warn("unique CD: " .. tostring(err)) end
end)
-- at the start: the first unique CD not found enters play if none is, and the file is written for ZomBOT
Events.OnInitGlobalModData.Add(function()
	Unique.current()
	Unique.write()
end)

return Unique
