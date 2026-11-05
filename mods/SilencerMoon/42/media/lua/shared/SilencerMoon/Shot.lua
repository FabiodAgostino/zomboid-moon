-- SilencerMoon: what happens when a suppressed weapon fires.
--
-- Noise (every game that shows the shot): the game's own Lua makes the shot's noise (ISReloadWeaponAction.attackHook,
-- on Hook.Attack, where the radius is weapon:getSoundRadius() times the sandbox FirearmNoiseMultiplier, halved
-- indoors) and in multiplayer the shooter's game sends it to the server. OnWeaponSwing fires just before
-- (SwipeStatePlayer.enter, for every player in that state, before any check of who is local), so the radius, the
-- sound and the muzzle flash are set there, for the other players' shots too: on their screens the shot sound comes
-- from the weapon of that player as their game has it (SwipeStatePlayer.OnAnimEvent_PlaySwingSoundAlways reads
-- getSwingSound()). None of them is saved with the weapon: they are set again before every shot and given back when
-- the suppressor is gone or worn out.
--
-- Wear (decided by the server): OnWeaponSwingHitPoint fires on the shooter's game for every round, missed shots
-- included, but on a dedicated server only for rounds that hit something (network/fields/hit/Player.attack). So the
-- shooter's game reports each round and the server rolls the dice (server/SilencerMoon/Commands.lua). A dry trigger
-- pull is not a round: the game marks it with setRangedWeaponEmpty(true) until the attack ends, and so do we.

require "SilencerMoon/Core"
require "SilencerMoon/Stats"
if SilencerMoon.Shot then return SilencerMoon.Shot end

local Core = SilencerMoon.Core
local Shot = {}
SilencerMoon.Shot = Shot

Shot.COMMAND_MODULE = "SilencerMoon"
Shot.COMMAND_SHOT = "shot"

---------------------------------------------------------------- noise

local baselines = {}   -- by weapon type: what a fresh weapon of that type has
local touched = {}     -- by item id: weapons whose sound we changed
local flashRefused = {} -- by weapon type: the muzzle flash cannot be hidden

local function baseline(weapon)
	local fullType = weapon:getFullType()
	local known = baselines[fullType]
	if known then return known end
	local fresh = instanceItem(fullType)
	if not fresh then return nil end
	known = { radius = fresh:getSoundRadius(), swing = fresh:getSwingSound(), flash = fresh:getMuzzleFlashModelKey() }
	baselines[fullType] = known
	return known
end

local function setFlash(weapon, key)
	local fullType = weapon:getFullType()
	if key == nil and flashRefused[fullType] then return end
	local ok = pcall(function() weapon:setMuzzleFlashModelKey(key) end)
	if not ok and key == nil then
		flashRefused[fullType] = true
		print("[SilencerMoon] the muzzle flash of " .. tostring(fullType) .. " cannot be hidden")
	end
end

-- Sets (or gives back) the noise radius, the shot sound and the muzzle flash of a weapon.
function Shot.applyNoise(weapon)
	if isServer() then return end
	if not weapon or not instanceof(weapon, "HandWeapon") or not weapon:isRanged() then return end
	local tier = Core.activeTier(weapon)
	local id = weapon:getID()
	if not tier and not touched[id] then return end
	local base = baseline(weapon)
	if not base then return end
	if tier then
		weapon:setSoundRadius(Core.radius(base.radius, tier))
		local calibre = Core.CALIBER_SOUND[weapon:getFullType()]
		if tier.suppressedSound and calibre then
			weapon:setSwingSound("SilencerMoon_Suppressed" .. calibre)
			setFlash(weapon, nil)
		else
			weapon:setSwingSound(base.swing)
			setFlash(weapon, base.flash)
		end
		touched[id] = true
	else
		weapon:setSoundRadius(base.radius)
		weapon:setSwingSound(base.swing)
		setFlash(weapon, base.flash)
		touched[id] = nil
	end
end

---------------------------------------------------------------- wear

-- One fired round (single player, or the server on the shooter's report). Answers true when the suppressor or the
-- weapon changed and must be sent to the owner.
function Shot.wear(weapon)
	local tier, part = Core.activeTier(weapon)
	if not tier then return false end
	local changed = false
	if Core.wears(tier, ZombRand) then
		part:setCondition(math.max(0, part:getCondition() - 1))
		changed = true
	end
	-- a worn-out suppressor stops costing range and damage at once; another part may have changed them too
	if SilencerMoon.Stats.refresh(weapon) then changed = true end
	return changed
end

-- The shooter's game: is this a round actually fired through our working suppressor?
function Shot.isRound(character, weapon)
	if not character or not instanceof(character, "IsoPlayer") or not character:isLocalPlayer() then return false end
	if not weapon or not instanceof(weapon, "HandWeapon") or not weapon:isRanged() then return false end
	if character:isDoShove() or character:isRangedWeaponEmpty() then return false end
	return Core.activeTier(weapon) ~= nil
end

-- Every player's shot, not only ours: the others must hear and see it suppressed too.
local function onWeaponSwing(character, weapon)
	if character and instanceof(character, "IsoPlayer") then
		Shot.applyNoise(weapon)
	end
end

local function onHitPoint(character, weapon)
	if isServer() or not Shot.isRound(character, weapon) then return end
	if isClient() then
		sendClientCommand(character, Shot.COMMAND_MODULE, Shot.COMMAND_SHOT, { id = weapon:getID() })
	else
		Shot.wear(weapon)
	end
end

-- Errors are written once and the handler rests a little: a broken feature must never take the shot with it.
local function guarded(name, callback)
	local seen, restUntil = {}, 0
	return function(...)
		if restUntil > 0 and getTimestampMs() < restUntil then return end
		local ok, result = pcall(callback, ...)
		if ok then return result end
		restUntil = getTimestampMs() + 10000
		local text = tostring(result)
		if not seen[text] then
			seen[text] = true
			print("[SilencerMoon] " .. name .. ": " .. text)
		end
	end
end
Shot.guarded = guarded

if not SilencerMoon.shotEventsAdded then
	SilencerMoon.shotEventsAdded = true
	Events.OnWeaponSwing.Add(guarded("OnWeaponSwing", onWeaponSwing))
	Events.OnWeaponSwingHitPoint.Add(guarded("OnWeaponSwingHitPoint", onHitPoint))
end

---------------------------------------------------------------- recipes

-- OnTest of the two alloy recipes: the game calls it with (item, character) for every candidate item. A firearm
-- goes into the furnace only empty (no rounds, nothing in the chamber, no spent case) and with no part mounted,
-- so nothing is lost by mistake. Broken guns are welcome.
function SilencerMoon.recipeTestShotgun(item, character)
	if not item or not instanceof(item, "HandWeapon") or not item:isRanged() then return true end
	if item:getCurrentAmmoCount() > 0 then return false end
	if item:isRoundChambered() or item:isSpentRoundChambered() then return false end
	if item:getSpentRoundCount() > 0 then return false end
	if item:getMagazineType() and item:isContainsClip() then return false end
	local parts = item:getAllWeaponParts()
	if parts and parts:size() > 0 then return false end
	return true
end

return Shot
