-- SilencerMoon: what happens when a suppressed weapon fires.
--
-- Noise (every game that shows the shot, never the dedicated server). The game makes a shot's noise in its own Lua:
-- ISReloadWeaponAction.attackHook, on Hook.Attack (IsoLivingCharacter.AttemptAttack), reads the weapon's sound radius
-- (times the sandbox FirearmNoiseMultiplier, halved indoors) and its swing sound before the attack starts.
-- OnWeaponSwing (SwipeStatePlayer.enter) comes later: too late for that shot. So the weapon in hand always carries the
-- right values. They are set when a player takes it in hand (OnEquipPrimary, for every player: also another player,
-- whose weapon arrives whole, parts included, with each EquipPacket) and checked at every update of a local player
-- (OnPlayerUpdate: a suppressor mounted, removed or worn out changes them before the next trigger pull).
-- OnWeaponSwing stays as a last check. None of them is saved with the weapon: a fresh copy has the game's values.
--
-- What the others get. The sound goes by name from the shooter's game (IsoPlayer.playRangedWeaponShootSound sends
-- RangedWeaponSound), and so does the noise the zombies hear: the shooter's values are what everyone gets. The muzzle
-- flash is drawn by each game from its own copy of the shooter's weapon (EffectsManager.startMuzzleFlash reads
-- getMuzzleFlashModelKey): hidden by the same values on that copy. When a suppressor wears out, the server tells
-- every game (COMMAND_WORN), so the others' copies show the flash again. The short light of every firearm shot (an
-- IsoLightSource that startMuzzleFlash makes whatever the weapon) cannot be removed by a mod.
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
Shot.COMMAND_WORN = "worn" -- server to every game: { player = online id, id = weapon id }

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

-- What was applied last to the weapon in each local player's hand: { weapon, part, working }.
local held = {}

-- Every update of a local player: one look at the weapon in hand; the values are set again only when the weapon, its
-- suppressor or the suppressor's state changed (a few calls a frame, nothing else).
function Shot.keep(player)
	local index = player:getPlayerNum()
	local weapon = player:getPrimaryHandItem()
	local last = held[index]
	if not weapon or not instanceof(weapon, "HandWeapon") or not weapon:isRanged() then
		if last then held[index] = nil end
		return
	end
	local part = weapon:getWeaponPart(Core.PART_TYPE)
	local working = part ~= nil and part:getCondition() > 0
	if last and last.weapon == weapon and last.part == part and last.working == working then return end
	held[index] = { weapon = weapon, part = part, working = working }
	Shot.applyNoise(weapon)
end

-- The server says another player's suppressor wore out: our copy of that weapon learns it (the shooter's own copy
-- comes with syncHandWeaponFields).
function Shot.onWorn(args)
	if type(args) ~= "table" or not args.player or not args.id then return end
	local player = getPlayerByOnlineID(args.player)
	if not player or player:isLocalPlayer() then return end
	local weapon = player:getPrimaryHandItem()
	if not weapon or not instanceof(weapon, "HandWeapon") or weapon:getID() ~= args.id then return end
	local part = Core.suppressor(weapon)
	if part and part:getCondition() > 0 then part:setCondition(0) end
	Shot.applyNoise(weapon)
end

local function onPlayerUpdate(player)
	if player and player:isLocalPlayer() then Shot.keep(player) end
end

local function onEquipPrimary(character, item)
	if character and item and instanceof(character, "IsoPlayer") then Shot.applyNoise(item) end
end

local function onWeaponSwing(character, weapon)
	if character and instanceof(character, "IsoPlayer") then Shot.applyNoise(weapon) end
end

local function onServerCommand(module, command, args)
	if module == Shot.COMMAND_MODULE and command == Shot.COMMAND_WORN then Shot.onWorn(args) end
end

local function onHitPoint(character, weapon)
	if isServer() or not Shot.isRound(character, weapon) then return end
	if isClient() then
		sendClientCommand(character, Shot.COMMAND_MODULE, Shot.COMMAND_SHOT, { id = weapon:getID() })
	else
		Shot.wear(weapon)
	end
end

-- Each different error is written once (at most 20 for a handler) and the handler keeps working: a failure on one
-- shot, square or command must never skip the next ones, nor take the game's own work with it.
local function guarded(name, callback)
	local seen, written = {}, 0
	return function(...)
		local ok, result = pcall(callback, ...)
		if ok then return result end
		local text = tostring(result)
		if not seen[text] and written < 20 then
			seen[text] = true
			written = written + 1
			print("[SilencerMoon] " .. name .. ": " .. text)
		end
	end
end
Shot.guarded = guarded

if not SilencerMoon.shotEventsAdded then
	SilencerMoon.shotEventsAdded = true
	Events.OnWeaponSwingHitPoint.Add(guarded("OnWeaponSwingHitPoint", onHitPoint))
	-- the noise is for the games that show the shot: not the dedicated server
	if not isServer() then
		Events.OnPlayerUpdate.Add(guarded("OnPlayerUpdate", onPlayerUpdate))
		Events.OnEquipPrimary.Add(guarded("OnEquipPrimary", onEquipPrimary))
		Events.OnWeaponSwing.Add(guarded("OnWeaponSwing", onWeaponSwing))
		Events.OnServerCommand.Add(guarded("OnServerCommand", onServerCommand))
	end
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
