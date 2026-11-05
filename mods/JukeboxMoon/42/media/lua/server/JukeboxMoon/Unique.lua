-- JukeboxMoon: the unique CDs (album.json "unique", docs/jukebox/TECHNICAL_DESIGN.md "Il CD unico"). One copy in the
-- server's whole story: never in the loot, never made by admins (Catalog.activeAlbums leaves it out). It is on a
-- running zombie that a player kills: every such kill rolls 1 in `oneIn` while the CD is waiting.
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
--   - a corpse nobody loots: the CD stays "dropped". It can drop again only when a runner rolls it again and the
--     server's corpse removal time (SandboxVars.HoursForCorpseRemoval, game hours) has passed since it fell without
--     anybody telling the server. The risk, written in the docs: a move the mod does not see, then that time, then a
--     new roll, would make a second copy.
--
-- Saved in the world (global ModData "JukeboxMoon".unique, by album key):
--   { state = "waiting" | "dropped" | "found", x, y, z, at, hours, found = { user, character, at, from, test } }
-- Zomboid/Lua/jukeboxmoon_unique.json, rewritten whole at the start and at every change, is what ZomBOT reads (the
-- contract is ZomBOT's, zomboid-discord: do not change it on one side only):
--   {"v":1,"unique":[{"key":"62","name":"CD: Love storii...","artist":"Prince","found":null}]}
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

-- A CD that fell and nobody reported: it can fall again once the server's corpses are removed (its corpse with it).
-- HoursForCorpseRemoval of 0 or less: corpses stay, so it stays on its corpse.
function Unique.expired(e)
	local hours = tonumber(SandboxVars and SandboxVars.HoursForCorpseRemoval) or -1
	if hours <= 0 then return false end
	return worldHours() - (tonumber(e.hours) or 0) >= hours
end

-- Can this album's CD fall now?
function Unique.open(album)
	if album.unique.from ~= "runner" then return false end
	local e = Unique.entry(album)
	return e.state == "waiting" or (e.state == "dropped" and Unique.expired(e))
end

function Unique.onZombieDead(zombie)
	if not zombie then return end
	local open = {}
	for _, album in ipairs(Catalog.uniqueAlbums()) do
		if Unique.open(album) then open[#open + 1] = album end
	end
	if #open == 0 then return end
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
	for _, album in ipairs(open) do
		if ZombRand(Unique.oneIn(album)) == 0 then
			local item = zombie:getInventory():AddItem(album.item)
			if item then
				local e = Unique.entry(album)
				if e.state == "dropped" then
					Core.warn("the unique CD of album " .. tostring(album.key) .. " fell at " .. tostring(e.x) .. ","
						.. tostring(e.y) .. "," .. tostring(e.z) .. " and nobody took it before the corpses' removal time")
				end
				e.state = "dropped"
				e.x, e.y, e.z = math.floor(zombie:getX()), math.floor(zombie:getY()), math.floor(zombie:getZ())
				e.at = seconds()
				e.hours = worldHours()
				Core.warn("the unique CD of album " .. tostring(album.key) .. " dropped from a runner at " .. e.x .. ","
					.. e.y .. "," .. e.z .. " killed by " .. tostring(try(function() return killer:getUsername() end, "?")))
				Unique.write()
			end
			return                                                 -- one unique CD per zombie at most
		end
	end
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

function Unique.found(album, e, player)
	e.state = "found"
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

-- "taken {album, item}" from the mod of a player who moved the CD (client/JukeboxMoon/Finder.lua): checked once.
function Unique.taken(player, args)
	if type(args) ~= "table" or player:isDead() then return end
	local album = Catalog.albumByKey(tonumber(args.album))
	if not Catalog.isUnique(album) then return end
	local e = Unique.entry(album)
	if e.state ~= "dropped" then return end
	if not holds(try(function() return player:getInventory() end), album.item) then
		-- not on the player: put somewhere where it fell (a crate, a car, the floor), and no longer on its corpse
		if not Unique.near(player, e) or Unique.onCorpse(e, album.item) then return end
	end
	Unique.found(album, e, player)
end

Server.Commands.taken = Unique.taken
Events.OnZombieDead.Add(function(zombie)
	local ok, err = pcall(Unique.onZombieDead, zombie)
	if not ok then Core.warn("unique CD: " .. tostring(err)) end
end)
Events.OnInitGlobalModData.Add(function() Unique.write() end)

return Unique
