-- JukeboxMoon: the unique CDs (album.json "unique", docs/jukebox/TECHNICAL_DESIGN.md "Il CD unico"). One copy in the
-- server's whole story: never in the loot, never made by admins (Catalog.activeAlbums leaves it out). It is on a
-- running zombie that a player kills: every such kill rolls 1 in `oneIn`, only while the CD is waiting.
--
-- What the server sees (42.21, read in projectzomboid.jar):
--   - IsoZombie.onKilled runs on the server: it fills the zombie's inventory, fires OnZombieDead, then makes the corpse
--     from that inventory (DoDeath): a CD added during the event lies on the corpse. getAttackedBy() is the killer.
--   - a runner: IsoZombie.getWalkType() starts with "sprint" (sprint1-5; the server's value, sent to the clients in
--     ZombiePacket).
--   - taking an item is a client action (media/lua/client/TimedActions/ISInventoryTransferAction.lua): the server moves
--     it in Java, with no Lua event. So while the CD is out, once a game minute, the server looks: a player carrying it
--     (containsTypeRecurse) found it; still on its corpse, it waits; moved next to the corpse, or gone with a player
--     near, the nearest player found it; gone with nobody near, twice in a row, the corpse went with it and the CD waits
--     for another runner. Nothing at all while no unique CD is out.
--
-- Saved in the world (global ModData "JukeboxMoon".unique, by album key):
--   { state = "waiting" | "dropped" | "found", x, y, z, at, missing, found = { user, character, at, from, test } }
-- Zomboid/Lua/jukeboxmoon_unique.json, rewritten whole at the start and at every change, is what ZomBOT reads (the
-- contract is ZomBOT's, zomboid-discord: do not change it on one side only):
--   {"v":1,"unique":[{"key":"62","name":"CD: Love storii...","artist":"Prince","found":null}]}
--   found: {"user":"<account>","character":"<name surname>","at":<unix s>,"from":"runner","test":false}
-- test is true in single player and in a game started with -debug (where the CD drops from the first runner, to try
-- it): ZomBOT announces nothing for it.
if isClient() then return end

require "JukeboxMoon/Core"
require "JukeboxMoon/Catalog"

if JukeboxMoon.Unique then return JukeboxMoon.Unique end

local Core = JukeboxMoon.Core
local Catalog = JukeboxMoon.Catalog

local Unique = {}
JukeboxMoon.Unique = Unique

Unique.FILE = "jukeboxmoon_unique.json"
Unique.MODDATA = "JukeboxMoon"
Unique.SAME_ZOMBIE_MS = 10000   -- the fire paths fire OnZombieDead twice for one zombie
Unique.AROUND = 2               -- squares around where it dropped: the corpse, and where a hand can move it
Unique.NEAR_TILES = 20          -- a player this close to the corpse when the CD leaves it is who took it
Unique.MISSING_LOOKS = 2        -- looks in a row without the CD before it waits again (a square still loading)
Unique.recent = {}              -- zombie -> when it was rolled

local function try(f, default)
	local ok, value = pcall(f)
	if ok and value ~= nil then return value end
	return default
end

local function seconds()
	return math.floor(getTimestampMs() / 1000)
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

function Unique.entry(album)
	local all = Unique.data()
	local key = tostring(album.key)
	if type(all[key]) ~= "table" then all[key] = { state = "waiting" } end
	return all[key]
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

function Unique.json()
	local list = {}
	for _, album in ipairs(Catalog.uniqueAlbums()) do
		local e = Unique.entry(album)
		local found = "null"
		local f = e.found
		if e.state == "found" and type(f) == "table" then
			found = "{\"user\":\"" .. Unique.esc(f.user) .. "\",\"character\":\"" .. Unique.esc(f.character)
				.. "\",\"at\":" .. string.format("%d", math.floor(tonumber(f.at) or 0))
				.. ",\"from\":\"" .. Unique.esc(f.from) .. "\",\"test\":" .. (f.test == true and "true" or "false") .. "}"
		end
		-- name and artist come already escaped from the catalogue (tools/jukebox, generate.json_text)
		list[#list + 1] = "{\"key\":\"" .. tostring(album.key) .. "\",\"name\":\"" .. tostring(album.unique.jsonName or "")
			.. "\",\"artist\":\"" .. tostring(album.unique.jsonArtist or "") .. "\",\"found\":" .. found .. "}"
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

function Unique.onZombieDead(zombie)
	if not zombie then return end
	local waiting = {}
	for _, album in ipairs(Catalog.uniqueAlbums()) do
		if album.unique.from == "runner" and Unique.entry(album).state == "waiting" then waiting[#waiting + 1] = album end
	end
	if #waiting == 0 then return end
	-- a burning zombie leaves a burning corpse: it would take the CD with it
	if try(function() return zombie:isOnFire() end, false) then return end
	local killer = try(function() return zombie:getAttackedBy() end)
	if not killer or not instanceof(killer, "IsoPlayer") or instanceof(killer, "IsoAnimal") then return end
	if not Unique.isRunner(zombie) then return end
	local t = getTimestampMs()
	local last = Unique.recent[zombie]
	if last and t - last < Unique.SAME_ZOMBIE_MS then return end
	Unique.recent[zombie] = t
	for _, album in ipairs(waiting) do
		if ZombRand(Unique.oneIn(album)) == 0 then
			local item = zombie:getInventory():AddItem(album.item)
			if item then
				local e = Unique.entry(album)
				e.state = "dropped"
				e.x, e.y, e.z = math.floor(zombie:getX()), math.floor(zombie:getY()), math.floor(zombie:getZ())
				e.at = seconds()
				e.missing = 0
				Core.warn("the unique CD of album " .. tostring(album.key) .. " dropped from a runner at " .. e.x .. ","
					.. e.y .. "," .. e.z .. " killed by " .. tostring(try(function() return killer:getUsername() end, "?")))
				Unique.write()
			end
			return                                                 -- one unique CD per zombie at most
		end
	end
end

------------------------------------------------------------------------------------------------- found, or gone

-- The players of this game: every one connected on a server, the local ones in single player.
function Unique.players()
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

local function holds(container, fullType)
	return container ~= nil and try(function() return container:containsTypeRecurse(fullType) end, false) == true
end

-- Where the CD is around the square it dropped on: "corpse" (still on a dead body), "moved" (in another container or
-- on the floor there), nil (not there). Only squares the server has loaded; `loaded` says whether the centre is.
function Unique.around(e, fullType)
	local cell = getCell()
	if not cell or not cell:getGridSquare(e.x, e.y, e.z) then return nil, false end
	local moved = false
	for dx = -Unique.AROUND, Unique.AROUND do
		for dy = -Unique.AROUND, Unique.AROUND do
			local square = cell:getGridSquare(e.x + dx, e.y + dy, e.z)
			if square then
				local bodies = try(function() return square:getDeadBodys() end)
				if bodies then
					for i = 0, bodies:size() - 1 do
						if holds(try(function() return bodies:get(i):getContainer() end), fullType) then return "corpse", true end
					end
				end
				local objects = square:getObjects()
				for i = 0, objects:size() - 1 do
					local object = objects:get(i)
					local count = try(function() return object:getContainerCount() end, 0)
					for c = 0, count - 1 do
						if holds(try(function() return object:getContainerByIndex(c) end), fullType) then moved = true end
					end
				end
				local floor = try(function() return square:getWorldObjects() end)
				if floor then
					for i = 0, floor:size() - 1 do
						local item = try(function() return floor:get(i):getItem() end)
						if item and (try(function() return item:getFullType() end) == fullType
								or holds(try(function() return item:getInventory() end), fullType)) then
							moved = true
						end
					end
				end
			end
		end
	end
	return moved and "moved" or nil, true
end

function Unique.nearest(e)
	local best, bestD = nil, Unique.NEAR_TILES * Unique.NEAR_TILES
	for _, player in ipairs(Unique.players()) do
		if not player:isDead() and math.floor(player:getZ()) == e.z then
			local dx, dy = player:getX() - (e.x + 0.5), player:getY() - (e.y + 0.5)
			local d = dx * dx + dy * dy
			if d <= bestD then best, bestD = player, d end
		end
	end
	return best
end

function Unique.found(album, e, player)
	e.state = "found"
	e.missing = nil
	e.found = {
		user = try(function() return player:getUsername() end, "?"),
		character = try(function() return player:getFullName() end, ""),
		at = seconds(),
		from = album.unique.from,
		test = Unique.testing(),
	}
	Core.warn("the unique CD of album " .. tostring(album.key) .. " was found by " .. tostring(e.found.user))
	Unique.write()
end

function Unique.look(album, e)
	for _, player in ipairs(Unique.players()) do
		if not player:isDead() and holds(try(function() return player:getInventory() end), album.item) then
			return Unique.found(album, e, player)
		end
	end
	local where, loaded = Unique.around(e, album.item)
	if not loaded then return end                              -- nobody near it: it waits as it is
	if where == "corpse" then
		e.missing = 0
		return
	end
	local who = Unique.nearest(e)
	if who then return Unique.found(album, e, who) end        -- moved, or taken away (a car, the corpse carried)
	if where == "moved" then return end                         -- moved, and nobody near now: whoever picks it up
	e.missing = (tonumber(e.missing) or 0) + 1
	if e.missing < Unique.MISSING_LOOKS then return end
	Core.warn("the unique CD of album " .. tostring(album.key) .. " went with its corpse: it waits for another runner")
	e.state, e.x, e.y, e.z, e.at, e.missing = "waiting", nil, nil, nil, nil, nil
	Unique.write()
end

function Unique.everyMinute()
	local t = getTimestampMs()
	local old = {}
	for zombie, at in pairs(Unique.recent) do
		if t - at >= Unique.SAME_ZOMBIE_MS then old[#old + 1] = zombie end
	end
	for _, zombie in ipairs(old) do Unique.recent[zombie] = nil end
	for _, album in ipairs(Catalog.uniqueAlbums()) do
		local e = Unique.entry(album)
		if e.state == "dropped" then
			local ok, err = pcall(Unique.look, album, e)
			if not ok then Core.warn("unique CD: " .. tostring(err)) end
		end
	end
end

Events.OnZombieDead.Add(function(zombie)
	local ok, err = pcall(Unique.onZombieDead, zombie)
	if not ok then Core.warn("unique CD: " .. tostring(err)) end
end)
Events.EveryOneMinute.Add(Unique.everyMinute)
Events.OnInitGlobalModData.Add(function() Unique.write() end)

return Unique
