-- Weapon Systems is optional.  This adapter only declares muzzle exclusivity;
-- Simple Suppressors remains responsible for sound, condition, and visuals.
-- Keeping those systems separate avoids conflicting stat writes or a hard
-- dependency for players who do not use Weapon Systems.
require "simple-suppressors/compatibility"

if SimpleSuppressorsWeaponSystemsLoaded then return end
SimpleSuppressorsWeaponSystemsLoaded = true

SimpleSuppressorsWeaponSystems = SimpleSuppressorsWeaponSystems or {}
local Bridge = SimpleSuppressorsWeaponSystems
Bridge.available, Bridge.registered = false, false
Bridge.detail = "Weapon Systems is not installed"

local ok, UpgradeExclusives = pcall(require, "WeaponSystems/Utils/UpgradeExclusives")
if not ok or not UpgradeExclusives or not UpgradeExclusives.RegisterMultipleSetOfExclusives then
	return
end

Bridge.available = true
local ours = {}
for partType in pairs(SimpleSuppressorsCompatibility.PART_CALIBERS) do
	ours[#ours + 1] = partType
end
table.sort(ours)

-- These are the currently supported third-party muzzle families.  Missing
-- item types are harmless to Weapon Systems; the list prevents a duplicate
-- suppressor, muzzle brake, or bayonet occupying the same muzzle position.
local otherMuzzles = {
	"Base.Pistol_Silencer", "Base.Heavy_Pistol_Silencer", "Base.AR_Silencer",
	"Base.556Muzzle", "Base.762Muzzle", "Base.M9_Bayonet_Attachment",
	"MarzGuns.LR2_Compensator", "MarzGuns.LX_Flashhider", "MarzGuns.Trix42_Muzzlebreak",
	"MarzGuns.MKI_Suppressor", "MarzGuns.NDR_Suppressor", "MarzGuns.PBS-1_Suppressor",
	"MarzGuns.M&P_Suppressor", "MarzGuns.Shh9_Suppressor", "MarzGuns.P45_Suppressor",
	"MarzGuns.M9_Bayonet_Attachment", "MarzGuns.M5_Bayonet_Attachment", "MarzGuns.K98_Bayonet_Attachment",
}

local function joined(...)
	local result, seen = {}, {}
	for _, group in ipairs({ ... }) do
		for _, value in ipairs(group) do
			if not seen[value] then seen[value] = true; result[#result + 1] = value end
		end
	end
	return result
end

local function register()
	local sets = {}
	for _, suppressor in ipairs(ours) do sets[suppressor] = joined(ours, otherMuzzles) end
	for _, muzzle in ipairs(otherMuzzles) do sets[muzzle] = joined(ours) end
	local registered, err = pcall(function()
		UpgradeExclusives.RegisterMultipleSetOfExclusives(sets)
	end)
	Bridge.registered = registered
	Bridge.detail = registered and ("registered " .. #ours .. " suppressor parts") or tostring(err)
	if SimpleSuppressorsDiagnostics then
		SimpleSuppressorsDiagnostics.info("WeaponSystems", "exclusivity", Bridge.detail)
	end
end

register()
if Events and Events.OnGameBoot then Events.OnGameBoot.Add(register) end
if Events and Events.OnGameStart then Events.OnGameStart.Add(register) end
