-- JukeboxMoon: what a jukebox is, and the rules of its container. Shared: the game asks the accept function on the
-- client (the loot window) and on the server (which decides every transfer).
--
-- The game's jukeboxes are tiles without a container (recreational_01_0 and _1, CustomName = Jukebox). The first time
-- someone opens one, the server puts in its place an IsoThumpable with the same sprite and a container of type
-- "jukeboxmoon" (Server.convert): the CDs go in and out with the game's own loot window.

require "JukeboxMoon/Core"
require "JukeboxMoon/Catalog"

if JukeboxMoon.Box then return JukeboxMoon.Box end

local Core = JukeboxMoon.Core
local Catalog = JukeboxMoon.Catalog
local Box = {}
JukeboxMoon.Box = Box

local function spriteProperty(object, name)
	local ok, value = pcall(function()
		local sprite = object:getSprite()
		if not sprite then return nil end
		local props = sprite:getProperties()
		if not props then return nil end
		return props:get(name)
	end)
	return ok and value or nil
end

function Box.spriteName(object)
	local ok, name = pcall(function()
		local sprite = object:getSprite()
		return sprite and sprite:getName() or nil
	end)
	return ok and name or nil
end

-- One of ours: a jukebox already converted, with its container.
function Box.isConverted(object)
	if not object then return false end
	local ok, converted = pcall(function()
		local container = object:getContainer()
		return container ~= nil and container:getType() == Core.CONTAINER
	end)
	return ok and converted == true
end

-- A jukebox of the map, still the game's tile: no container yet.
function Box.isVanilla(object)
	if not object then return false end
	local ok, container = pcall(function() return object:getContainer() end)
	if not ok or container ~= nil then return false end
	return spriteProperty(object, "CustomName") == "Jukebox"
end

function Box.isJukebox(object)
	return Box.isConverted(object) or Box.isVanilla(object)
end

-- The jukebox on a square (converted first), and its index among the square's objects.
function Box.onSquare(square)
	if not square then return nil, nil end
	local objects = square:getObjects()
	if not objects then return nil, nil end
	local vanilla, vanillaIndex = nil, nil
	for i = 0, objects:size() - 1 do
		local object = objects:get(i)
		if Box.isConverted(object) then return object, i end
		if not vanilla and Box.isVanilla(object) then vanilla, vanillaIndex = object, i end
	end
	return vanilla, vanillaIndex
end

function Box.keyOf(object)
	return Core.key(object:getX(), object:getY(), object:getZ())
end

-- The CDs in the container, in its order: { { id, album, item } } (album: the catalogue's key). Anything else is
-- skipped (nothing else gets in).
function Box.cds(object)
	local out = {}
	local container = object and object:getContainer()
	if not container then return out end
	local items = container:getItems()
	for i = 0, items:size() - 1 do
		local item = items:get(i)
		local album = Catalog.albumOf(item)
		if album then
			out[#out + 1] = { id = item:getID(), album = album.key, item = item }
		end
	end
	return out
end

-- The game calls AcceptItemFunction.JukeboxMoon(container, item) for every item put in: only CDs of the catalogue
-- (ours, and the game's whose recording it has), and no more than the server's limit.
function Box.accepts(container, item)
	if not Catalog.isCD(item) then return false end
	local ok, count = pcall(function() return container:getItems():size() end)
	if not ok then return false end
	return count < Core.maxCDs()
end

function Box.registerAccept()
	AcceptItemFunction = AcceptItemFunction or {}
	AcceptItemFunction.JukeboxMoon = Box.accepts
end
Box.registerAccept()

-- What a converted jukebox's container must be. The accept function is not saved with the object: set again every
-- time the jukebox is opened or checked.
function Box.applyContainer(object)
	local container = object and object:getContainer()
	if not container then return end
	Box.registerAccept()
	if container:getType() ~= Core.CONTAINER then container:setType(Core.CONTAINER) end
	if container:getCapacity() ~= Core.CAPACITY then container:setCapacity(Core.CAPACITY) end
	if container:getAcceptItemFunction() ~= Core.ACCEPT then container:setAcceptItemFunction(Core.ACCEPT) end
	if not container:isExplored() then container:setExplored(true) end
end

-- The jukebox's own settings, kept with the object: { shuffle = bool, rand = number }.
function Box.settings(object)
	local md = object:getModData()
	if type(md.jbm) ~= "table" then md.jbm = {} end
	local s = md.jbm
	if type(s.shuffle) ~= "boolean" then s.shuffle = false end
	if type(s.rand) ~= "number" then s.rand = 12345 end
	return s
end

-- Power as the game's own ambient sounds check it (ObjectAmbientEmitters$AmbientSoundLogic): the square's
-- electricity (a generator, or the grid while it is on) or the object's grid power.
function Box.hasPower(object)
	local ok, powered = pcall(function()
		local square = object:getSquare()
		if square and square:haveElectricity() then return true end
		return object:hasGridPower()
	end)
	return ok and powered == true
end

return Box
