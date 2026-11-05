-- SilencerMoon: the shared rules. Which items are ours, what each tier does to a shot, the wear roll.
-- Loaded on clients and on the server. No game state lives here.
--
-- Kahlua (the game's Lua, 42.21) has no next, xpcall, table.pack, table.unpack, os.clock, and loses accented letters
-- written in string literals: every player-facing text is in Translate/*.json.

SilencerMoon = SilencerMoon or {}
if SilencerMoon.Core then return SilencerMoon.Core end

local Core = {}
SilencerMoon.Core = Core

Core.MODULE = "SilencerMoon"
Core.PART_TYPE = "Suppressor"

-- What remains of the unsuppressed value (0.60 = 60%): radius = the noise radius towards zombies (05/11/2026,
-- the user's test: with 0.35 a rifle still drew zombies from 30 tiles and more; now 0.35, 0.20, 0.10), range = the
-- maximum range, damage = minimum and maximum damage. oneIn: one chance in N, per shot, to lose a condition point.
-- conditionMax matches ConditionMax in SilencerMoon_items.txt. suppressedSound: the shot plays the calibre's
-- suppressed sound and hides the muzzle flash (the alloys); the oil filter keeps the game's sound and flash.
Core.TIERS = {
	oilfilter = { id = "oilfilter", radius = 0.35, range = 0.60, damage = 0.75, oneIn = 5, conditionMax = 5,
		suppressedSound = false },
	copper = { id = "copper", radius = 0.20, range = 0.70, damage = 0.80, oneIn = 10, conditionMax = 10,
		suppressedSound = true },
	ballistic = { id = "ballistic", radius = 0.10, range = 0.80, damage = 0.875, oneIn = 100, conditionMax = 10,
		suppressedSound = true },
}

Core.PARTS = {
	["SilencerMoon.Suppressor_OilFilter"] = "oilfilter",
	["SilencerMoon.Suppressor_Pistol_Copper"] = "copper",
	["SilencerMoon.Suppressor_Rifle_Copper"] = "copper",
	["SilencerMoon.Suppressor_Pistol_Ballistic"] = "ballistic",
	["SilencerMoon.Suppressor_Rifle_Ballistic"] = "ballistic",
}

-- The suppressed sound of each supported firearm, by its calibre (sounds in SilencerMoon_sounds.txt).
Core.CALIBER_SOUND = {
	["Base.Pistol"] = "9mm",
	["Base.Pistol2"] = "45ACP",
	["Base.TrapperCarbine"] = "45ACP",
	["Base.Pistol3"] = "44",
	["Base.L92_Carbine"] = "357",
	["Base.AssaultRifle"] = "556",
	["Base.VarmintRifle"] = "556",
	["Base.JS14_Rifle"] = "556",
	["Base.AssaultRifle2"] = "308",
	["Base.HuntingRifle"] = "308",
	["Base.MSR7T_Rifle"] = "308",
	["Base.L94_Rifle"] = "3030",
}

function Core.tierOfType(fullType)
	local id = fullType and Core.PARTS[fullType]
	return id and Core.TIERS[id] or nil
end

-- Our suppressor on a weapon (working or worn out), or nil.
function Core.suppressor(weapon)
	if not weapon or not instanceof(weapon, "HandWeapon") then return nil end
	local part = weapon:getWeaponPart(Core.PART_TYPE)
	if part and Core.PARTS[part:getFullType()] then return part end
	return nil
end

-- The tier of the weapon's suppressor if it still works (condition above 0), and the part itself.
function Core.activeTier(weapon)
	local part = Core.suppressor(weapon)
	if not part then return nil, nil end
	if part:getCondition() <= 0 then return nil, part end
	return Core.tierOfType(part:getFullType()), part
end

-- The noise radius of a shot with this tier. The game then multiplies it by the sandbox FirearmNoiseMultiplier
-- and halves it indoors (ISReloadWeaponAction.attackHook).
function Core.radius(baseRadius, tier)
	return math.max(1, math.floor(baseRadius * tier.radius))
end

-- One fired round: true when the suppressor loses a condition point. rand(n) answers 0 .. n-1 (ZombRand).
function Core.wears(tier, rand)
	return rand(tier.oneIn) == 0
end

-- The average number of shots a new suppressor lasts (a negative binomial: conditionMax losses, 1 in oneIn each).
function Core.averageShots(tier)
	return tier.conditionMax * tier.oneIn
end

-- A share as the tooltip writes it: 0.125 -> "12,5", 0.4 -> "40".
function Core.percentText(share)
	local tenths = math.floor(share * 1000 + 0.5)
	local whole = math.floor(tenths / 10)
	local rest = tenths - whole * 10
	if rest == 0 then return tostring(whole) end
	return tostring(whole) .. "," .. tostring(rest)
end

return Core
