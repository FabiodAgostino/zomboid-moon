-- SilencerMoon: getting the weapons ready before the mod leaves the server (the "restore").
--
-- Why it is needed (checked in the 42.21 jar): a weapon saves its own range and damage, so a suppressed weapon would
-- keep them reduced for ever; and a weapon whose mounted part is of a type that no longer exists is thrown away
-- when its save is read (HandWeapon.load gets nil from InventoryItemFactory.CreateItem and fails, and
-- InventoryItem.loadItem drops the whole weapon). So every SilencerMoon suppressor must come off before the mod goes.
--
-- An admin turns it on from the window "ZomBOT" > "Silenziatori" (client/SilencerMoon/Admin.lua). The server keeps it
-- in the world's mod data (it survives restarts)
-- and while it is on: nobody can mount a SilencerMoon suppressor; the weapons of every player online are fixed at
-- once and every ten game minutes (so also those of whoever logs in later), those in the loaded vehicles too; those
-- in containers, on the ground and on corpses as their area loads. A detached suppressor stays next to its weapon.
-- What is never loaded while it is on (a base nobody visits, a player who never logs in) is not reached.

require "SilencerMoon/Core"
require "SilencerMoon/Stats"
if SilencerMoon.Restore then return SilencerMoon.Restore end

local Core = SilencerMoon.Core
local Restore = {}
SilencerMoon.Restore = Restore

Restore.DATA = "SilencerMoon"         -- the world's mod data: { restoring = bool, fixed = weapons fixed so far }
Restore.COMMAND_START = "restoreStart"
Restore.COMMAND_STOP = "restoreStop"
Restore.COMMAND_QUERY = "restoreQuery" -- the admins' window asks how it stands, changing nothing
Restore.REPLY = "restoreState"

function Restore.data()
	if not ModData.exists(Restore.DATA) then return nil end
	return ModData.get(Restore.DATA)
end

function Restore.active()
	local data = Restore.data()
	return data ~= nil and data.restoring == true
end

-- The same, kept in Lua for the handler of every loading square: read again when the world's mod data arrives,
-- every ten minutes, and when an admin changes it.
function Restore.activeCached()
	if Restore.cache == nil then Restore.cache = Restore.active() end
	return Restore.cache
end

-- An admin, as the game's own tools and ZomBOT check it: admin powers, or the right to draw non-PvP zones. In single
-- player the world is yours.
function Restore.isAdmin(player)
	if not isClient() and not isServer() then return true end
	if not player then return false end
	local ok, admin = pcall(function()
		local role = player:getRole()
		if role == nil then return false end
		return role:hasAdminPower() or role:hasCapability(Capability.CanSetupNonPVPZone)
	end)
	return ok and admin == true
end

-- CanAttach of every SilencerMoon suppressor (SilencerMoon_items.txt): the game's screwdriver check, and never while
-- the restore is on. The game calls it with (character, weapon, part), on the client for the menu and on the server
-- for the action.
function SilencerMoon.canAttach(character, weapon, part)
	if Restore.active() then return false end
	return ItemCodeOnTest.hasScrewdriver(character, weapon, part) == true
end

---------------------------------------------------------------- fixing weapons (server and single player)

-- A ranged weapon with our suppressor, or with our values still applied.
function Restore.needs(item)
	if not item or not instanceof(item, "HandWeapon") or not item:isRanged() then return false end
	if Core.suppressor(item) ~= nil then return true end
	return item:hasModData() and item:getModData()[SilencerMoon.Stats.KEY] ~= nil
end

-- The detached suppressor goes where the weapon is: its container, or the ground under it.
local function keepNextTo(weapon, part)
	local container = weapon:getContainer()
	if container then
		container:AddItem(part)
		if isServer() then sendAddItemToContainer(container, part) end
		return
	end
	local world = weapon:getWorldItem()
	local square = world and world:getSquare()
	if square then square:AddWorldInventoryItem(part, 0.5, 0.5, 0) end
end

-- Takes our suppressor off one weapon and gives it its own values back. Answers true when it changed something.
function Restore.weapon(weapon, owner)
	if isClient() or not Restore.needs(weapon) then return false end
	local part = Core.suppressor(weapon)
	if part then
		-- the game takes off its own modifiers (0 for ours) and calls our OnDetach, which gives the values back
		weapon:detachWeaponPart(owner, part)
		keepNextTo(weapon, part)
	end
	SilencerMoon.Stats.refresh(weapon)
	return true
end

-- Every weapon in a container, bags inside included. The owner (a player) gets each fixed weapon sent back.
function Restore.container(container, owner)
	if not container then return 0 end
	local found = container:getAllEvalRecurse(Restore.needs)
	local fixed = 0
	for i = 0, found:size() - 1 do
		local weapon = found:get(i)
		if Restore.weapon(weapon, owner) then
			fixed = fixed + 1
			if owner and isServer() then syncHandWeaponFields(owner, weapon) end
		end
	end
	return fixed
end

function Restore.onlinePlayers()
	local list = {}
	if isServer() then
		local online = getOnlinePlayers()
		for i = 0, online:size() - 1 do list[#list + 1] = online:get(i) end
	else
		for i = 0, getNumActivePlayers() - 1 do
			local player = getSpecificPlayer(i)
			if player then list[#list + 1] = player end
		end
	end
	return list
end

function Restore.players()
	local fixed = 0
	for _, player in ipairs(Restore.onlinePlayers()) do
		fixed = fixed + Restore.container(player:getInventory(), player)
	end
	return fixed
end

function Restore.vehicles()
	local cell = getCell()
	if not cell then return 0 end
	local fixed = 0
	local vehicles = cell:getVehicles():iterator()
	while vehicles:hasNext() do
		local vehicle = vehicles:next()
		for i = 0, vehicle:getPartCount() - 1 do
			local container = vehicle:getPartByIndex(i):getItemContainer()
			if container then fixed = fixed + Restore.container(container, nil) end
		end
	end
	return fixed
end

-- One square as it loads: the containers of its objects, what lies on the ground (a weapon, or a bag), the corpses.
function Restore.square(square)
	local fixed = 0
	local objects = square:getObjects()
	for i = 0, objects:size() - 1 do
		local object = objects:get(i)
		for c = 0, object:getContainerCount() - 1 do
			fixed = fixed + Restore.container(object:getContainerByIndex(c), nil)
		end
	end
	local onGround = square:getWorldObjects()
	for i = 0, onGround:size() - 1 do
		local item = onGround:get(i):getItem()
		if item then
			if Restore.weapon(item, nil) then fixed = fixed + 1 end
			if instanceof(item, "InventoryContainer") then fixed = fixed + Restore.container(item:getInventory(), nil) end
		end
	end
	local bodies = square:getDeadBodys()
	for i = 0, bodies:size() - 1 do
		fixed = fixed + Restore.container(bodies:get(i):getContainer(), nil)
	end
	return fixed
end

-- Counts what was fixed in the world's mod data, for the admin's menu.
function Restore.count(fixed)
	if fixed <= 0 then return end
	local data = ModData.getOrCreate(Restore.DATA)
	data.fixed = (tonumber(data.fixed) or 0) + fixed
end

-- Turns it on or off (the server, or single player). Answers the weapons fixed now.
function Restore.set(on)
	local data = ModData.getOrCreate(Restore.DATA)
	data.restoring = on == true
	data.fixed = tonumber(data.fixed) or 0
	Restore.cache = data.restoring
	local fixed = 0
	if data.restoring then
		fixed = Restore.players() + Restore.vehicles()
		Restore.count(fixed)
	end
	if isServer() then ModData.transmit(Restore.DATA) end
	return fixed
end

return Restore
