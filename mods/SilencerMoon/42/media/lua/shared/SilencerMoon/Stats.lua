-- SilencerMoon: range and damage of a suppressed weapon, as percentages, decided by the server.
--
-- Why not the part's own modifiers: the game adds a part's MaxRangeModifier/DamageModifier as fixed numbers (the
-- same number on minimum and maximum damage), and a part does not save its numbers while the weapon does
-- (HandWeapon.save keeps maxRange, minDamage, maxDamage). So the weapon's values are changed here, and the weapon's
-- modData remembers what was applied: refreshing is idempotent (equip, reload, save and load add nothing) and
-- taking the suppressor off gives back exactly what the weapon had, keeping any change made meanwhile by another
-- part or mod. In multiplayer the caller sends the weapon to its owner (syncHandWeaponFields): the server checks
-- every hit against its own copy (AntiCheatHitWeapon), so client and server must agree.

require "SilencerMoon/Core"
if SilencerMoon.Stats then return SilencerMoon.Stats end

local Core = SilencerMoon.Core
local Stats = {}
SilencerMoon.Stats = Stats

Stats.KEY = "SilencerMoon"

-- The weapon's range and damage without our suppressor.
function Stats.unsuppressed(weapon, data)
	local range, low, high = weapon:getMaxRange(), weapon:getMinDamage(), weapon:getMaxDamage()
	local applied = data[Stats.KEY]
	if type(applied) ~= "table" then return range, low, high end
	return applied.baseRange + (range - applied.range),
		applied.baseMin + (low - applied.min),
		applied.baseMax + (high - applied.max)
end

-- Puts the weapon's range and damage in line with its suppressor (or with none). Server and single player only.
-- Answers true when a value changed.
function Stats.refresh(weapon)
	if isClient() then return false end
	if not weapon or not instanceof(weapon, "HandWeapon") or not weapon:isRanged() then return false end
	local data = weapon:getModData()
	local beforeRange, beforeMin, beforeMax = weapon:getMaxRange(), weapon:getMinDamage(), weapon:getMaxDamage()
	local range, low, high = Stats.unsuppressed(weapon, data)
	local tier = Core.activeTier(weapon)
	if tier then
		weapon:setMaxRange(range * tier.range)
		weapon:setMinDamage(low * tier.damage)
		weapon:setMaxDamage(high * tier.damage)
		-- read back: the weapon keeps floats, and an exact comparison later needs what it really holds
		data[Stats.KEY] = {
			tier = tier.id,
			baseRange = range, baseMin = low, baseMax = high,
			range = weapon:getMaxRange(), min = weapon:getMinDamage(), max = weapon:getMaxDamage(),
		}
	else
		weapon:setMaxRange(range)
		weapon:setMinDamage(low)
		weapon:setMaxDamage(high)
		data[Stats.KEY] = nil
	end
	return weapon:getMaxRange() ~= beforeRange or weapon:getMinDamage() ~= beforeMin
		or weapon:getMaxDamage() ~= beforeMax
end

-- OnAttach / OnDetach of every SilencerMoon suppressor (SilencerMoon_items.txt). The game calls them from
-- attachWeaponPart and detachWeaponPart, after its own modifiers, with (character, weapon, part): the server in
-- multiplayer, for the game's "Add weapon upgrade" menu too, whose action then syncs the weapon. Not when a save is
-- loaded (attachWeaponPart(nil, part, false)): the weapon's saved values are already right.
function SilencerMoon.onAttach(character, weapon, part)
	Stats.refresh(weapon)
end

function SilencerMoon.onDetach(character, weapon, part)
	Stats.refresh(weapon)
end

return Stats
