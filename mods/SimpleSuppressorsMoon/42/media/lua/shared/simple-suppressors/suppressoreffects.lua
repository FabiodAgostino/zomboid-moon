require "simple-suppressors/diagnostics"
require "simple-suppressors/compatibility"
require "simple-suppressors/weaponsystemscompat"
require "simple-suppressors/suppressorrepair"
require "simple-suppressors/slotmigration"
require "simple-suppressors/recipemigration"
if SimpleSuppressorsEffectsLoaded then return end
SimpleSuppressorsEffectsLoaded = true
local Diagnostics = SimpleSuppressorsDiagnostics
Diagnostics.loaded("SuppressorEffects.Shared")

local DEFAULTS = {
	MachinedSoundRadiusReduction = 25,
	OilFilterSoundRadiusReduction = 35,
	SoundVolumeReduction = 55,
}

local function setting(name, legacyName)
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	local value = vars and (vars[name] or (legacyName and vars[legacyName]))
	return type(value) == "number" and value / 100 or DEFAULTS[name] / 100
end

local function suppressorPart(weapon)
	return SimpleSuppressorsCompatibility.getAttachedSuppressor(weapon)
end
local function isSuppressed(weapon)
	local part = suppressorPart(weapon)
	if not part then return false end
	local ok, condition, fullType = pcall(function()
		return part:getCondition(), part:getFullType()
	end)
	if ok and type(fullType) == "string" then
		if not SimpleSuppressorsCompatibility.isPartEnabled(fullType) then return false end
	end
	return not ok or type(condition) ~= "number" or condition > 0
end

-- True when the attached suppressor was built from a scavenged oil filter,
-- which suppresses less effectively than a machined baffle-stack suppressor.
local function oilFilterSuppressed(weapon)
	local part = suppressorPart(weapon)
	if SimpleSuppressorsCompatibility.isOilFilterSuppressor then
		return SimpleSuppressorsCompatibility.isOilFilterSuppressor(part)
	end
	local ok, fullType = pcall(function() return part and part:getFullType() end)
	return ok and type(fullType) == "string" and string.find(fullType, ".Suppressor_OilFilter_", 1, true) ~= nil
end

-- Every gun sharing a caliber shares its suppressor's sound, matching the
-- mod's own caliber system: a suppressor barely touches a supersonic
-- bullet's crack (the bullet's own sonic boom, not muzzle blast), so
-- mechanism does not change what the suppressor itself sounds like.
local CALIBER_SOUND = {
	["12Gauge"] = "Shotgun",
	["9mm"] = "9mm",
	["45ACP"] = "45ACP",
	["44"] = "44",
	["357"] = "357",
	["556"] = "556",
	["308"] = "308",
	["3030"] = "3030",
}

local function suppressedSound(weapon)
	local part = suppressorPart(weapon)
	local ok, kind = pcall(function() return part and part:getFullType() end)
	if not ok then kind = nil end
	-- Gunworks uses RealAuto/RealBurst; vanilla uses Auto/Burst. Both should use
	-- the automatic clips rather than replaying the single-shot tail per round.
	local fireMode = ""
	pcall(function() fireMode = weapon:getFireMode() or "" end)
	local automatic = fireMode == "Auto" or fireMode == "Burst" or fireMode == "RealAuto" or fireMode == "RealBurst"
	local suffix = automatic and "FullAuto" or ""

	local caliber = kind and SimpleSuppressorsCompatibility.PART_CALIBERS[kind]
	local definition = caliber and SimpleSuppressorsCompatibility.getCaliberDefinition
		and SimpleSuppressorsCompatibility.getCaliberDefinition(caliber)
	local sound = CALIBER_SOUND[caliber] or (definition and definition.sound) or "45ACP"
	return "SimpleSuppressors_Suppressed" .. sound .. suffix
end

local DURABILITY_SHOTS = {
	[1] = 2500,
	[2] = 5000,
	[3] = 10000,
}
local DURABILITY_SHOTS_KEY = "SimpleSuppressors.SuppressorShots"
local HEAT_KEY = "SimpleSuppressors.SuppressorHeat"
local HEAT_TIME_KEY = "SimpleSuppressors.SuppressorHeatTime"
local HEAT_PER_SHOT = 4
local HEAT_WEAR_THRESHOLD = 25
-- A full heat bar takes 4,000 in-game seconds to dissipate.  That leaves a
-- meaningful post-magazine smoke/glow window without turning cosmetic heat
-- into a permanent status effect.
local HEAT_COOL_PER_WORLD_SECOND = 0.025

local function worldSeconds()
	local ok, hours = pcall(function() return getGameTime():getWorldAgeHours() end)
	return ok and type(hours) == "number" and hours * 3600 or 0
end

local function heatAt(data, now)
    local previous = tonumber(data[HEAT_KEY]) or 0
    local last = tonumber(data[HEAT_TIME_KEY]) or now
    return math.max(0, previous - math.max(0, now - last) * HEAT_COOL_PER_WORLD_SECOND)
end

SimpleSuppressorsEffects = SimpleSuppressorsEffects or {}
function SimpleSuppressorsEffects.getHeat(part)
    if not part then return 0 end
    local ok, data = pcall(function() return part:getModData() end)
    return ok and data and heatAt(data, worldSeconds()) or 0
end

-- [moon] Heat and wear are counted once per round, from OnWeaponSwingHitPoint only: the round has left the gun.
-- The original counted from Hook.Attack too, and asked both paths whether a round was still in the chamber. But the
-- game's own shot handler (registered earlier, it runs first) has already emptied the chamber by then, and a
-- dedicated server never raises Hook.Attack: in multiplayer pump, bolt and lever guns never wore or heated their
-- suppressor, and the others skipped the last round of every magazine. In single player the two paths could count
-- the same round twice (they are not in the same frame), and Hook.Attack also counted shoves and dry trigger pulls.
local function trackHeat(weapon)
    local vars = SandboxVars and SandboxVars.SimpleSuppressors
    if vars and vars.EnableSuppressorHeat == false then return end
    local part = suppressorPart(weapon)
    if not part then return end
    local ok, data = pcall(function() return part:getModData() end)
    if not ok or not data then return end
    local now = worldSeconds()
    data[HEAT_KEY] = math.min(100, heatAt(data, now) + HEAT_PER_SHOT)
    data[HEAT_TIME_KEY] = now
end

local function suppressorDurabilityShots()
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	local value = vars and tonumber(vars.SuppressorDurability) or 4
	return DURABILITY_SHOTS[math.floor(value)]
end

function SimpleSuppressorsEffects.getDurabilityProgress(part)
	local shotsToBreak = suppressorDurabilityShots()
	if not part or not shotsToBreak then return nil end
	local ok, condition, modData = pcall(function()
		return part:getCondition(), part:getModData()
	end)
	if not ok or type(condition) ~= "number" or not modData then return nil end
	local shots = tonumber(modData[DURABILITY_SHOTS_KEY])
	if not shots then
		local startingCondition = math.min(100, math.max(0, condition))
		shots = math.floor((100 - startingCondition) * shotsToBreak / 100)
	end
	return math.min(shotsToBreak, math.max(0, shots)), shotsToBreak
end

local function wearSuppressor(weapon)
	local shotsToBreak = suppressorDurabilityShots()
	if not shotsToBreak then return end
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	local part = suppressorPart(weapon)
	if not part then return end
	local ok, condition = pcall(function() return part:getCondition() end)
	if not ok or type(condition) ~= "number" or condition <= 0 then return end
	local modDataOk, modData = pcall(function() return part:getModData() end)
	if not modDataOk or not modData then return end

	local shots = SimpleSuppressorsEffects.getDurabilityProgress(part)
	if shots == nil then return end
	local heatWear = vars and vars.HeatAcceleratesWear ~= false
	local heat = heatWear and SimpleSuppressorsEffects.getHeat(part) or 0
	-- At maximum heat, each shot consumes twice the normal lifetime. This keeps
	-- ordinary and cooling use unchanged while making sustained automatic fire
	-- meaningful. Wear begins only once the suppressor reaches the warm range.
	local heatWearFraction = math.max(0, heat - HEAT_WEAR_THRESHOLD) / (100 - HEAT_WEAR_THRESHOLD)
	local nextShots = math.min(shotsToBreak, math.max(0, shots) + 1 + heatWearFraction)
	modData[DURABILITY_SHOTS_KEY] = nextShots

	local nextCondition = nextShots >= shotsToBreak and 0
		or math.ceil((shotsToBreak - nextShots) * 100 / shotsToBreak)
	nextCondition = math.min(condition, nextCondition)
	if nextCondition ~= condition then
		pcall(function() part:setCondition(nextCondition) end)
	end
	-- [moon] no sendItemStats(part) here: it sends nothing for a part mounted on a weapon (no container). The
	-- shot handler sends the whole weapon once heat and wear are both done.
	if nextCondition == 0 then
		Diagnostics.info("Effects", "wear", "suppressor condition reached zero")
	end
end

local muzzleFlashRefused = {} -- [moon] weapon types whose native muzzle flash cannot be hidden
local function updateMuzzleFlash(weapon, suppressed)
	-- B42 resolves the native flash from the firearm model, not from a mounted
	-- Canon part. Hide it while a working Simple Suppressors part is attached;
	-- restore the script-defined model immediately after detachment or breakage.
	if isServer() then return end
	local data = weapon:getModData()
	if suppressed then
		-- [moon] the flag is saved with the weapon, the hidden flash is not: after loading a save (or a weapon sent
		-- again by the server) the flag alone left the flash visible on every suppressed shot
		if data.simpleSuppressorsMuzzleFlashSuppressed and weapon:getMuzzleFlashModelKey() == nil then return end
		-- [moon] a weapon type that refused once is not asked again on every shot (each failed pcall still costs
		-- a stack trace in the game's log)
		local weaponType = weapon:getFullType()
		if muzzleFlashRefused[weaponType] then return end
		local ok = pcall(function() weapon:setMuzzleFlashModelKey(nil) end)
		if ok then
			data.simpleSuppressorsMuzzleFlashSuppressed = true
		else
			muzzleFlashRefused[weaponType] = true
			Diagnostics.warn("Effects", "muzzle-flash", "native muzzle-flash API unavailable for " .. tostring(weaponType))
		end
		return
	end
	if not data.simpleSuppressorsMuzzleFlashSuppressed then return end
	local ok, scriptItem = pcall(function() return weapon:getScriptItem() end)
	if not ok or not scriptItem then
		Diagnostics.warn("Effects", "muzzle-flash", "unable to restore native muzzle flash")
		return
	end
	ok = pcall(function()
		weapon:setMuzzleFlashModelKey(scriptItem:getMuzzleFlashModelKey())
	end)
	if ok then
		data.simpleSuppressorsMuzzleFlashSuppressed = nil
	else
		Diagnostics.warn("Effects", "muzzle-flash", "native muzzle-flash restore failed")
	end
end

-- Never learn a baseline from a suppressed or network-reconstructed weapon.
-- Cache one fresh item per firearm type, outside serialized item modData.
local soundBaselines = {}
-- [moon] by item id: Kahlua has no weak tables, so weapon objects as keys were kept alive for the whole session
local soundModified = {}

local function soundBaseline(fullType)
	local baseline = soundBaselines[fullType]
	if baseline then return baseline end
	local original = instanceItem(fullType)
	if not original then error("Cannot create sound baseline for " .. fullType) end
	baseline = { radius = original:getSoundRadius(), volume = original:getSoundVolume(),
		noise = original:getNoiseFactor(), swing = original:getSwingSound() }
	soundBaselines[fullType] = baseline
	return baseline
end

local function updateWeapon(weapon)
	if not weapon or not instanceof(weapon, "HandWeapon") or not weapon:isRanged() then
		Diagnostics.info("Effects", "update", "skipped non-ranged weapon")
		return
	end
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	local weaponType = weapon:getFullType()
	local data = weapon:getModData()
	local suppressed = isSuppressed(weapon)
	updateMuzzleFlash(weapon, suppressed)
	local currentSound = weapon:getSwingSound()
	local wasSuppressed = soundModified[weapon:getID()] or data.simpleSuppressorsBaseRadius ~= nil
		or (type(currentSound) == "string" and currentSound:find("SimpleSuppressors_Suppressed", 1, true) == 1)
	if not suppressed and not wasSuppressed then return end
	local baseline = soundBaseline(weaponType)
	-- Discard legacy baselines, including values captured after reduction.
	data.simpleSuppressorsBaseRadius = nil
	data.simpleSuppressorsBaseVolume = nil
	data.simpleSuppressorsBaseNoiseFactor = nil
	data.simpleSuppressorsBaseSwingSound = nil
	if suppressed then
		local radiusFactor = setting("MachinedSoundRadiusReduction", "SoundRadiusReduction")
		local volumeFactor = setting("SoundVolumeReduction")
		if oilFilterSuppressed(weapon) then
			if vars and type(vars.OilFilterSoundRadiusReduction) == "number" then
				radiusFactor = setting("OilFilterSoundRadiusReduction")
			else
				-- Preserve the old single-setting behavior for established saves.
				radiusFactor = math.min(1, setting("MachinedSoundRadiusReduction", "SoundRadiusReduction") * 1.5)
			end
			volumeFactor = math.min(1, volumeFactor * 1.4)
		end
		weapon:setSoundRadius(math.max(1, math.floor(baseline.radius * radiusFactor)))
		weapon:setSoundVolume(math.max(1, math.floor(baseline.volume * volumeFactor)))
		weapon:setNoiseFactor(math.max(0, baseline.noise * radiusFactor))
		weapon:setSwingSound(suppressedSound(weapon))
		soundModified[weapon:getID()] = true
	else
		weapon:setSoundRadius(baseline.radius)
		weapon:setSoundVolume(baseline.volume)
		weapon:setNoiseFactor(baseline.noise)
		weapon:setSwingSound(baseline.swing)
		soundModified[weapon:getID()] = nil
	end
	Diagnostics.info("Effects", "update", "weapon=" .. weaponType .. " suppressed=" .. tostring(suppressed) .. " radius=" .. tostring(weapon:getSoundRadius()) .. " volume=" .. tostring(weapon:getSoundVolume()) .. " swing=" .. tostring(weapon:getSwingSound()))
end

-- Hook.Attack's argument order has differed between Build 42 revisions. Find
-- the ranged HandWeapon instead of assuming it is the third argument.
local function attackWeapon(...)
	for index = 1, select("#", ...) do
		local candidate = select(index, ...)
		local ok, ranged = pcall(function()
			return candidate and instanceof(candidate, "HandWeapon") and candidate:isRanged()
		end)
		if ok and ranged then return candidate end
	end
	return nil
end

-- Hook.Attack applies the radius/volume state for the shot. [moon] Only that: heat and wear are counted below, once
-- the round has really been fired.
Hook.Attack.Add(SimpleSuppressorsDiagnostics.guard("SuppressorEffects.Shared", "Hook.Attack", function(...)
	local weapon = attackWeapon(...)
	if not weapon then return end
	SimpleSuppressorsDiagnostics.info("Effects", "attack", "weapon=" .. tostring(weapon:getFullType()))
	updateWeapon(weapon)
end))

-- [moon] One fired round: the game raises OnWeaponSwingHitPoint (character, weapon) when the round leaves the gun,
-- in single player and on the server. A shove with a firearm in hand is not a shot. On the server the weapon is then
-- sent to its owner: the game's own shot handler already sent it, but before this handler had counted the round,
-- so the client always saw the suppressor one shot behind.
if Events and Events.OnWeaponSwingHitPoint then
    Events.OnWeaponSwingHitPoint.Add(SimpleSuppressorsDiagnostics.guard(
        "SuppressorEffects.Shared", "OnWeaponSwingHitPoint", function(character, weapon)
            if not weapon or not instanceof(weapon, "HandWeapon") or not weapon:isRanged() then return end
            if character and instanceof(character, "IsoPlayer") and character:isDoShove() then return end
            if not suppressorPart(weapon) then return end
            trackHeat(weapon)
            wearSuppressor(weapon)
            if isServer() and character and instanceof(character, "IsoPlayer") then
                syncHandWeaponFields(character, weapon)
            end
        end))
end
-- Prepare on every client/server before vanilla consumes getSwingSound() from
-- its attack hook. This also covers a host player in a listen-server session.
if Events and Events.OnWeaponSwing then
	Events.OnWeaponSwing.Add(SimpleSuppressorsDiagnostics.guard("SuppressorEffects.Shared", "OnWeaponSwing", function(_, weapon)
		if weapon then updateWeapon(weapon) end
	end))
end

if not isServer() then
	local function refreshEquippedWeapon(player, weapon)
		if player and player:isLocal() then updateWeapon(weapon) end
	end

	Events.OnEquipPrimary.Add(refreshEquippedWeapon)
	Events.OnEquipSecondary.Add(refreshEquippedWeapon)
	Events.OnGameStart.Add(function()
		for index = 0, getNumActivePlayers() - 1 do
			local player = getSpecificPlayer(index)
			if player and player:isLocal() then
				updateWeapon(player:getPrimaryHandItem())
				updateWeapon(player:getSecondaryHandItem())
			end
		end
	end)

	-- There is no confirmed vanilla Build 42 event fired specifically when a
	-- weapon part (e.g. a suppressor) is attached to or detached from an
	-- already-equipped weapon mid-combat, so Hook.Attack/OnEquipPrimary/
	-- OnEquipSecondary alone leave the tooltip stats stale until the next
	-- shot. Falling back to a throttled OnPlayerUpdate refresh, using the
	-- same counter-based throttle pattern as common-sense's sibling
	-- PersistentPortableLights.lua/PlumbingHighlights.lua (increment a
	-- counter, only do work once it reaches a threshold) rather than the
	-- unthrottled per-tick approach this mod's own audit already flagged and
	-- removed elsewhere. This catches up within about half a second instead
	-- of waiting for the next shot.
	local REFRESH_EVERY_TICKS = 30 -- ~0.5s at 60 ticks/sec
	local refreshCounter = 0
	Events.OnPlayerUpdate.Add(function(player)
		if not player or not player:isLocal() then return end
		refreshCounter = refreshCounter + 1
		if refreshCounter < REFRESH_EVERY_TICKS then return end
		refreshCounter = 0
		updateWeapon(player:getPrimaryHandItem())
		updateWeapon(player:getSecondaryHandItem())
	end)
end
