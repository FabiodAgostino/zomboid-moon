require "simple-suppressors/compatibility"
require "simple-suppressors/diagnostics"

-- Before version 4, suppressors occupied Canon. Vanilla lasers and gun lights
-- also use Canon, even though their meshes sit under the frame. Move only our
-- legacy suppressors to the new Suppressor slot; every other Canon part stays.
if SimpleSuppressorsSlotMigrationLoaded then return end
SimpleSuppressorsSlotMigrationLoaded = true

-- [moon] by item id: Kahlua has no weak tables, so weapon objects as keys were kept alive for the whole session
local migrated = {}
-- [moon] The original walked every player's whole inventory on every player update (each frame, for each player)
-- for the whole session. Once every 10 seconds per player is enough: it still finds a weapon picked up later.
local SCAN_EVERY_MS = 10000
local nextScan = {}

local function migrateWeapon(player, weapon)
	if not weapon or migrated[weapon:getID()] then return end
	local oldPart = weapon:getWeaponPart("Canon")
	if not SimpleSuppressorsCompatibility.isSuppressor(oldPart) then return end
	local current = weapon:getWeaponPart(SimpleSuppressorsCompatibility.PART_TYPE)
	if current then
		-- A partially migrated save has two suppressors. Preserve the current
		-- one and return only the obsolete Canon copy to the inventory.
		weapon:detachWeaponPart(player, oldPart)
		player:getInventory():AddItem(oldPart)
		if isServer() then sendAddItemToContainer(player:getInventory(), oldPart) end
		migrated[weapon:getID()] = true
		return
	end
	weapon:detachWeaponPart(player, oldPart)
	weapon:attachWeaponPart(player, oldPart)
	migrated[weapon:getID()] = true
	if isServer() then
		syncHandWeaponFields(player, weapon)
	end
	SimpleSuppressorsDiagnostics.info("SlotMigration", "migrated",
		"weapon=" .. tostring(weapon:getFullType()) .. " part=" .. tostring(oldPart:getFullType()))
end

local function migrateInventory(player)
	if isClient() or not player then return end
	local key, now = tostring(player:getUsername()), getTimestampMs()
	if nextScan[key] and now < nextScan[key] then return end
	nextScan[key] = now + SCAN_EVERY_MS
	local items = player:getInventory():getAllEvalRecurse(function(item)
		return instanceof(item, "HandWeapon") and item:isRanged()
	end)
	if not items then return end
	for index = 0, items:size() - 1 do
		migrateWeapon(player, items:get(index))
	end
end

if not SimpleSuppressorsSlotMigrationRegistered then
	Events.OnPlayerUpdate.Add(SimpleSuppressorsDiagnostics.guard(
		"SlotMigration.Shared", "OnPlayerUpdate", migrateInventory
	))
	SimpleSuppressorsSlotMigrationRegistered = true
end
