require "simple-suppressors/diagnostics"
if SimpleSuppressorsCompatibilityLoaded then return end
SimpleSuppressorsCompatibilityLoaded = true

-- Compatibility is decided from the actual firearm and ammo at runtime.
SimpleSuppressorsCompatibility = SimpleSuppressorsCompatibility or {}
local Compatibility = SimpleSuppressorsCompatibility
local Diagnostics = SimpleSuppressorsDiagnostics
Diagnostics.loaded("Compatibility.Shared")

Compatibility.ammoOverrides = Compatibility.ammoOverrides or {}
Compatibility.weaponOverrides = Compatibility.weaponOverrides or {}
Compatibility.caliberDefinitions = Compatibility.caliberDefinitions or {}
-- Profiles let an add-on describe its compatibility data once, rather than
-- scattering individual registrations through gameplay code.  Profiles are
-- intentionally only data: the same runtime caliber checks remain the final
-- authority for every firearm.
Compatibility.profiles = Compatibility.profiles or {}

local CALIBER_OPTIONS = {
	["12Gauge"] = "Enable12GaugeSuppressors",
	["556"] = "Enable556Suppressors",
	["9mm"] = "Enable9mmSuppressors",
	["45ACP"] = "Enable45ACPSuppressors",
	["308"] = "Enable308Suppressors",
	["3030"] = "Enable3030Suppressors",
	["357"] = "Enable357Suppressors",
	["44"] = "Enable44Suppressors",
}

-- New saves use one understandable content choice. The individual options are
-- deliberately retained as read-only legacy overrides so existing servers do
-- not silently gain a caliber their administrator had disabled.
local CONTENT_SCOPES = {
	[1] = { ["12Gauge"] = true, ["556"] = true, ["9mm"] = true, ["45ACP"] = true, ["308"] = true, ["3030"] = true, ["357"] = true, ["44"] = true },
	[2] = { ["556"] = true, ["9mm"] = true, ["45ACP"] = true, ["308"] = true, ["3030"] = true, ["357"] = true, ["44"] = true },
	[3] = { ["9mm"] = true, ["45ACP"] = true, ["357"] = true, ["44"] = true },
}

local PART_CALIBERS = {
	["SimpleSuppressors.Suppressor_12Gauge"] = "12Gauge",
	["SimpleSuppressors.Suppressor_556"] = "556",
	["SimpleSuppressors.Suppressor_9mm"] = "9mm",
	["SimpleSuppressors.Suppressor_45ACP"] = "45ACP",
	["SimpleSuppressors.Suppressor_308"] = "308",
	["SimpleSuppressors.Suppressor_3030"] = "3030",
	["SimpleSuppressors.Suppressor_357"] = "357",
	["SimpleSuppressors.Suppressor_44"] = "44",
	["SimpleSuppressors.Suppressor_OilFilter_12Gauge"] = "12Gauge",
	["SimpleSuppressors.Suppressor_OilFilter_556"] = "556",
	["SimpleSuppressors.Suppressor_OilFilter_9mm"] = "9mm",
	["SimpleSuppressors.Suppressor_OilFilter_45ACP"] = "45ACP",
	["SimpleSuppressors.Suppressor_OilFilter_308"] = "308",
	["SimpleSuppressors.Suppressor_OilFilter_3030"] = "3030",
	["SimpleSuppressors.Suppressor_OilFilter_357"] = "357",
	["SimpleSuppressors.Suppressor_OilFilter_44"] = "44",
}
local PART_ENABLED = {}
-- The core .308 suppressors may also fit 7.62x39 firearms when a loaded
-- compatibility profile enables that cartridge family. The .308 sandbox
-- option still controls whether the part itself is available.
local PART_CALIBER_ALIASES = {
    ["SimpleSuppressors.Suppressor_308"] = { ["762x39"] = true },
    ["SimpleSuppressors.Suppressor_OilFilter_308"] = { ["762x39"] = true },
}

-- Ordered from the most distinctive names to the broadest aliases. These are
-- bore families rather than a claim that every cartridge uses the same thread:
-- the crafted adapter represents the caliber-specific mounting hardware.
local AMMO_PATTERNS = {
	{ caliber = "12Gauge", tokens = { "12gauge", "12ga", "12gaugeshells", "shotgunshells" } },
	{ caliber = "556", tokens = { "bullets556", "556bullets", "ammo556", "556x45", "556nato", "556clip", "556box", "556mag", "556round", "223rem", "bullets223", "223clip", "223box" } },
	{ caliber = "9mm", tokens = { "bullets9mm", "ammo9mm", "9x19", "9mmpara", "9mmclip", "9mmbox", "9mmmag", "9mmround" } },
	{ caliber = "45ACP", tokens = { "bullets45", "ammo45", "45acp", "acp45", "45auto", "45clip", "45box" } },
	{ caliber = "3030", tokens = { "bullets3030", "3030win", "3030clip", "3030box", "3030carton", "ammo3030", "3030" } },
	{ caliber = "308", tokens = { "bullets308", "308bullets", "ammo308", "308win", "308clip", "308box", "762x51" } },
	{ caliber = "357", tokens = { "bullets357", "ammo357", "357mag", "357clip", "357box" } },
	{ caliber = "44", tokens = { "bullets44", "ammo44", "44mag", "44magnum", "44clip", "44box" } },
}

local function normalize(value)
	if value == nil then return "" end
	return string.lower(tostring(value)):gsub("[^%w]", "")
end

local function normalizeCaliber(caliber)
	local value = normalize(caliber)
	if value == "12gauge" or value == "12ga" or value == "shotgun" or value == "shotgunshells" then return "12Gauge" end
	if value == "556" or value == "556nato" or value == "223" or value == "bullets556" or value == "bullets223" then return "556" end
	if value == "9mm" or value == "9x19" or value == "bullets9mm" then return "9mm" end
	if value == "45" or value == "45acp" or value == "bullets45" then return "45ACP" end
	if value == "3030" or value == "3030win" or value == "bullets3030" then return "3030" end
	if value == "308" or value == "762" or value == "bullets308" then return "308" end
	if value == "357" or value == "38" or value == "357mag" or value == "bullets357" then return "357" end
	if value == "44" or value == "44mag" or value == "44magnum" or value == "bullets44" then return "44" end
	if Compatibility.caliberDefinitions[value] then return value end
	return nil
end

function Compatibility.isCaliberEnabled(caliber)
	local normalized = normalizeCaliber(caliber)
	local definition = normalized and Compatibility.caliberDefinitions[normalized]
	if definition then
		return definition.enabled == nil or definition.enabled() ~= false
	end
	local option = CALIBER_OPTIONS[normalized]
	if not option then return false end
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	if vars and vars[option] == false then return false end
	local scope = vars and math.floor(tonumber(vars.ContentScope) or 1) or 1
	return (CONTENT_SCOPES[scope] or CONTENT_SCOPES[1])[normalized] == true
end

-- Compatibility modules can add a real cartridge family without pretending it
-- is one of the core calibers.  The family remains opt-in at the add-on level
-- and its parts participate in the same attachment, heat, and sound paths.
function Compatibility.registerCaliber(caliber, definition)
	local key = normalize(caliber)
	if key == "" then return false end
	local existing = Compatibility.caliberDefinitions[key]
	if existing then
		local previousEnabled = existing.enabled
		local nextEnabled = definition and definition.enabled
		-- Several optional packs may supply the same cartridge family. Preserve
		-- their registered oil filters and enable it if any provider is enabled.
		for name, value in pairs(definition or {}) do
			if name ~= "enabled" and name ~= "oilFilterParts" then existing[name] = value end
		end
		if previousEnabled and nextEnabled then
			existing.enabled = function() return previousEnabled() ~= false or nextEnabled() ~= false end
		else
			existing.enabled = nil
		end
	else
		Compatibility.caliberDefinitions[key] = definition or {}
	end
	return true
end

function Compatibility.registerSuppressorPart(partType, caliber, oilFilter, enabled)
	local normalized = normalizeCaliber(caliber)
	if type(partType) ~= "string" or not normalized then return false end
	PART_CALIBERS[partType] = normalized
	PART_ENABLED[partType] = enabled
	if oilFilter then
		Compatibility.caliberDefinitions[normalized] = Compatibility.caliberDefinitions[normalized] or {}
		Compatibility.caliberDefinitions[normalized].oilFilterParts = Compatibility.caliberDefinitions[normalized].oilFilterParts or {}
		Compatibility.caliberDefinitions[normalized].oilFilterParts[partType] = true
	end
	return true
end

function Compatibility.isPartEnabled(part)
	local fullType = type(part) == "string" and part or part and part:getFullType()
	local caliber = fullType and PART_CALIBERS[fullType]
	local enabled = fullType and PART_ENABLED[fullType]
	return caliber ~= nil and Compatibility.isCaliberEnabled(caliber) and (not enabled or enabled() ~= false)
end

local function partMatchesWeaponCaliber(partType, weaponCaliber)
    if PART_CALIBERS[partType] == weaponCaliber then return true end
    local aliases = PART_CALIBER_ALIASES[partType]
    return aliases ~= nil and aliases[weaponCaliber] == true
        and Compatibility.isCaliberEnabled(weaponCaliber)
end

function Compatibility.getCaliberDefinition(caliber)
	local normalized = normalizeCaliber(caliber)
	return normalized and Compatibility.caliberDefinitions[normalized] or nil
end

-- Caliber-specific recipe tests keep disabled suppressor families out of both
-- the crafting UI and server-side completion, including already-learned recipes.
SimpleSuppressorsRecipeOnTest = SimpleSuppressorsRecipeOnTest or {}
local RecipeOnTest = SimpleSuppressorsRecipeOnTest
local function enabled(caliber)
	return function(_, _, _) return Compatibility.isCaliberEnabled(caliber) end
end
RecipeOnTest.shotgun = RecipeOnTest.shotgun or enabled("12Gauge")
RecipeOnTest.caliber556 = RecipeOnTest.caliber556 or enabled("556")
RecipeOnTest.caliber9mm = RecipeOnTest.caliber9mm or enabled("9mm")
RecipeOnTest.caliber45ACP = RecipeOnTest.caliber45ACP or enabled("45ACP")
RecipeOnTest.caliber308 = RecipeOnTest.caliber308 or enabled("308")
RecipeOnTest.caliber3030 = RecipeOnTest.caliber3030 or enabled("3030")
RecipeOnTest.caliber357 = RecipeOnTest.caliber357 or enabled("357")
RecipeOnTest.caliber44 = RecipeOnTest.caliber44 or enabled("44")


--- Register a cartridge name used by another mod.
--- Example: registerAmmo("SomeMod:ammo_6mm", "556")
function Compatibility.registerAmmo(ammoType, caliber, source)
	local normalizedCaliber = normalizeCaliber(caliber)
	if normalizedCaliber then
		Compatibility.ammoOverrides[normalize(ammoType)] = normalizedCaliber
	end
	Diagnostics.info("Compatibility", "registerAmmo", "ammo=" .. tostring(ammoType) .. " caliber=" .. tostring(normalizedCaliber) .. " source=" .. tostring(source or "manual") .. " accepted=" .. tostring(normalizedCaliber ~= nil))
	return normalizedCaliber ~= nil
end

--- Override the caliber of a particular firearm.
--- Example: registerWeapon("SomeMod.CustomRifle", "308")
function Compatibility.registerWeapon(weaponType, caliber, source)
	local normalizedCaliber = normalizeCaliber(caliber)
	if not normalizedCaliber then
		Diagnostics.info("Compatibility", "registerWeapon", "weapon=" .. tostring(weaponType) .. " rejected caliber=" .. tostring(caliber))
		return false
	end
	Compatibility.weaponOverrides[tostring(weaponType)] = {
		caliber = normalizedCaliber,
		source = source or "manual",
	}
	Diagnostics.info("Compatibility", "registerWeapon", "weapon=" .. tostring(weaponType) .. " caliber=" .. normalizedCaliber .. " source=" .. tostring(source or "manual"))
	return true
end

--- Register a named bundle of static firearm and ammo overrides.
--- A profile is safe to load repeatedly, which matters when a client returns
--- to the main menu and starts another world without restarting the game.
function Compatibility.registerProfile(profile)
	if type(profile) ~= "table" or type(profile.id) ~= "string" or profile.id == "" then
		Diagnostics.failure("Compatibility", "registerProfile", "rejected profile without a non-empty id")
		return false
	end
	local record = Compatibility.profiles[profile.id] or { id = profile.id }
	record.name = profile.name or profile.id
	record.weaponCount, record.ammoCount = 0, 0
	for weaponType, caliber in pairs(profile.weapons or {}) do
		if Compatibility.registerWeapon(weaponType, caliber, profile.id) then
			record.weaponCount = record.weaponCount + 1
		end
	end
	for ammoType, caliber in pairs(profile.ammo or {}) do
		if Compatibility.registerAmmo(ammoType, caliber, profile.id) then
			record.ammoCount = record.ammoCount + 1
		end
	end
	record.loaded = true
	Compatibility.profiles[profile.id] = record
	Diagnostics.info("Compatibility", "registerProfile", "id=" .. profile.id .. " weapons=" .. record.weaponCount .. " ammo=" .. record.ammoCount)
	return true
end

function Compatibility.profileReport()
	local report = {}
	for id, profile in pairs(Compatibility.profiles) do
		report[#report + 1] = {
			id = id,
			name = profile.name,
			weaponCount = profile.weaponCount or 0,
			ammoCount = profile.ammoCount or 0,
		}
	end
	table.sort(report, function(a, b) return a.id < b.id end)
	return report
end

local function getAmmoIdentity(weapon)
	if not weapon then return "" end
	local values = {}
	local function push(value)
		if value ~= nil and value ~= "" then values[#values + 1] = tostring(value) end
	end
	-- Only the accessors vanilla itself uses on HandWeapon are called here:
	-- getAmmoType() (object with getItemKey, or nil), getMagazineType() (string
	-- or nil). Calling anything else on these objects throws a Java exception
	-- that Kahlua logs even when caught, so it is avoided entirely.
	local ammoType = weapon:getAmmoType()
	if ammoType ~= nil then
		if type(ammoType) == "string" then
			push(ammoType)
		else
			local ok, key = pcall(function() return ammoType:getItemKey() end)
			push((ok and key) or ammoType)
		end
	end
	push(weapon:getMagazineType())
	return normalize(table.concat(values, " "))
end

local function inferCaliber(weapon)
	if not weapon then return nil end

	local weaponOverride = Compatibility.weaponOverrides[weapon:getFullType()]
	if weaponOverride then return weaponOverride.caliber end
	-- Also check unprefixed name (e.g. "PistolGlock") for compat-layer
	-- registrations that store bare class names instead of full module paths.
	local dot = string.find(weapon:getFullType(), ".", 1, true)
	if dot then
		local bareName = string.sub(weapon:getFullType(), dot + 1)
		local bareOverride = Compatibility.weaponOverrides[bareName]
		if bareOverride then return bareOverride.caliber end
	end

	local ammoIdentity = getAmmoIdentity(weapon)
	local exactOverride = Compatibility.ammoOverrides[ammoIdentity]
	if exactOverride then return exactOverride end
	local directCaliber = normalizeCaliber(ammoIdentity)
	if directCaliber then return directCaliber end
	-- Also allow an override registered against only the item key, even though
	-- ammoIdentity contains both the key and translated display name.
	local ammo = weapon:getAmmoType()
	if ammo then
		local ok, itemKey = pcall(function() return ammo:getItemKey() end)
		if ok and itemKey then
			local keyOverride = Compatibility.ammoOverrides[normalize(itemKey)]
			if keyOverride then return keyOverride end
		end
	end

	for _, profile in ipairs(AMMO_PATTERNS) do
		for _, token in ipairs(profile.tokens) do
			if string.find(ammoIdentity, token, 1, true) then return profile.caliber end
		end
	end
	return nil
end

local function populatePartMountOn(part)
	if not part or not instanceof(part, "WeaponPart") then return false, 0 end
	local mountOn
	local ok = pcall(function() mountOn = part:getMountOn() end)
	if not ok or not mountOn then return false, 0 end
	local added = 0
	local populated = pcall(function()
		for _, gun in ipairs(Compatibility.firearmTypes or {}) do
			local present = false
			for index = 0, mountOn:size() - 1 do
				if tostring(mountOn:get(index)) == gun then
					present = true
					break
				end
			end
			if not present then
				mountOn:add(gun)
				added = added + 1
			end
		end
	end)
	return populated, added
end

-- Item scripts invoke this with the newly created WeaponPart.
function Compatibility.onCreate(part)
	local partType = "<nil>"
	pcall(function() if part then partType = part:getFullType() end end)
	local ok, added = populatePartMountOn(part)
	Diagnostics.info("Compatibility", "onCreate", "part=" .. tostring(partType) .. " firearms=" .. tostring(added) .. " populated=" .. tostring(ok))
end

-- Build 42 craftRecipe callbacks receive CraftRecipeData, not an item. Keep
-- this separate from item OnCreate so crafting never calls WeaponPart APIs on
-- CraftRecipeData.
function Compatibility.onCraftCreate(craftRecipeData, _)
	if not craftRecipeData then return end
	local created = craftRecipeData:getAllCreatedItems()
	if not created then return end
	local parts, added = 0, 0
	for index = 0, created:size() - 1 do
		local populated, count = populatePartMountOn(created:get(index))
		if populated then
			parts = parts + 1
			added = added + count
		end
	end
	Diagnostics.info("Compatibility", "onCraftCreate", "parts=" .. tostring(parts) .. " firearms=" .. tostring(added))
end

local UNSUPPORTED_WEAPONS = {
	["base.revolver_long"] = "Magnum has no suppressor support",
	["base.shotgunsawnoff"] = "Sawed-off JS-2000 has no suppressor support",
	["base.doublebarrelshotgun"] = "Double-barrel shotguns have no suppressor support",
	["base.doublebarrelshotgunsawnoff"] = "Sawed-off double-barrel shotguns have no suppressor support",
	["base.side_by_side"] = "Side-by-side double-barrel shotguns have no suppressor support",
	["base.mp5sd_smg"] = "MP5SD already has an integrated suppressor",
	["base.mac10foldedsuppressed"] = "MAC-10 already has a suppressor",
}
local guns93SawedOff = ResourceLocation and ResourceLocation.of("guns93:SawedOff")
local guns93NoSilence = ResourceLocation and ResourceLocation.of("guns93:NoSilence")

local function blockedWeaponType(weapon)
	local fullType = ""
	local reloadType = ""
	pcall(function() fullType = string.lower(tostring(weapon:getFullType())) end)
	pcall(function() reloadType = normalize(weapon:getWeaponReloadType()) end)
	if UNSUPPORTED_WEAPONS[fullType] then return UNSUPPORTED_WEAPONS[fullType] end
	local sawedOffTag = ItemTag and guns93SawedOff and ItemTag.get(guns93SawedOff)
	if sawedOffTag and weapon:hasTag(sawedOffTag) then return "sawn-off firearms have no suppressor support" end
	local noSilenceTag = ItemTag and guns93NoSilence and ItemTag.get(guns93NoSilence)
	if noSilenceTag and weapon:hasTag(noSilenceTag) then return "firearm mod excludes suppressors" end
	if string.find(fullType, "mp5sd", 1, true) then
		return "MP5SD already has an integrated suppressor"
	end
	if string.find(fullType, "doublebarrel", 1, true) or string.find(reloadType, "doublebarrel", 1, true) then
		return "double-barrel shotguns have no suppressor support"
	end
	if string.find(fullType, "sawnoff", 1, true) or string.find(reloadType, "sawnoff", 1, true) then
		return "sawn-off firearms have no suppressor support"
	end
	-- Revolvers remain blocked because their cylinder gap defeats a
	-- conventional suppressor. The Magnum is also explicitly disabled above
	-- because this compatibility set does not support it.
	if string.find(reloadType, "revolver", 1, true) or string.find(fullType, "revolver", 1, true) then
		return "revolvers are not suppressible"
	end
	return nil
end

function Compatibility.supportsWeapon(weapon)
	if not weapon or not instanceof(weapon, "HandWeapon") then return false, "not a HandWeapon" end
	if not weapon:isRanged() then return false, "not ranged" end
	local reason = blockedWeaponType(weapon)
	return reason == nil, reason
end

function Compatibility.canAttach(character, weapon, part)
	local weaponType = "<nil>"
	local partType = "<nil>"
	pcall(function() if weapon then weaponType = weapon:getFullType() end end)
	pcall(function() if part then partType = part:getFullType() end end)
	local ok, accepted, reason = pcall(function()
		if not part then return false, "nil part" end
		local supported, blockedReason = Compatibility.supportsWeapon(weapon)
		if not supported then return false, blockedReason end
		local weaponCaliber = inferCaliber(weapon)
		local suppressorCaliber = PART_CALIBERS[partType]
		if not Compatibility.isPartEnabled(partType) then
			return false, "suppressor disabled"
		end
		if weaponCaliber == nil then
			return false, "unknown caliber; register the weapon or ammo override"
		end
		if not partMatchesWeaponCaliber(partType, weaponCaliber) then
			return false, "caliber mismatch weapon=" .. tostring(weaponCaliber) .. " suppressor=" .. tostring(suppressorCaliber)
		end
		return true, "matched caliber=" .. weaponCaliber
	end)
	if not ok then
		Diagnostics.failure("Compatibility", "canAttach", "weapon=" .. tostring(weaponType) .. " part=" .. tostring(partType) .. " error=" .. tostring(accepted))
		return false
	end
	Diagnostics.info("Compatibility", "canAttach", "weapon=" .. tostring(weaponType) .. " part=" .. tostring(partType) .. " accepted=" .. tostring(accepted) .. " reason=" .. tostring(reason))
	return accepted == true
end

-- Dynamic fallback for the custom attachment menu. Vanilla checks MountOn
-- before CanAttach, which makes its menu unusable for some mod firearms, so
-- the menu calls this directly. It still requires a known caliber that matches
-- the suppressor, so only compatible suppressors are offered; guns whose
-- caliber cannot be resolved must be registered via registerWeapon/registerAmmo.
function Compatibility.canAttachDynamic(character, weapon, part)
	local ok, accepted, reason = pcall(function()
		if not weapon or not part then return false, "nil weapon or part" end
		local supported, blocked = Compatibility.supportsWeapon(weapon)
		if not supported then return false, blocked end
		local existing = Compatibility.getAttachedSuppressor(weapon)
		if existing and existing:getFullType() == part:getFullType() then
			return false, "already attached"
		end
		local weaponCaliber = inferCaliber(weapon)
		local suppressorCaliber = PART_CALIBERS[part:getFullType()]
		if not Compatibility.isPartEnabled(part) then
			return false, "suppressor disabled"
		end
		if weaponCaliber == nil then
			return false, "unknown caliber; register the weapon or ammo override"
		end
		if not partMatchesWeaponCaliber(part:getFullType(), weaponCaliber) then
			return false, "caliber mismatch weapon=" .. tostring(weaponCaliber) .. " suppressor=" .. tostring(suppressorCaliber)
		end
		return true, "ok caliber=" .. weaponCaliber
	end)
	if not ok then
		Diagnostics.failure("Compatibility", "canAttachDynamic", "error=" .. tostring(accepted))
		return false
	end
	Diagnostics.info("Compatibility", "canAttachDynamic", "accepted=" .. tostring(accepted) .. " reason=" .. tostring(reason))
	return accepted == true
end

-- A compact, player-facing explanation for tooltips and custom menus. This
-- uses the same gates as attachment, without needing to create a temporary
-- suppressor item just to explain an unsupported firearm.
function Compatibility.weaponStatus(weapon)
	local ok, state, caliber = pcall(function()
		if not weapon or not instanceof(weapon, "HandWeapon") or not weapon:isRanged() then
			return "not-firearm"
		end
		if blockedWeaponType(weapon) then return "unsupported" end
		local resolved = inferCaliber(weapon)
		if not resolved then return "unknown" end
		if not Compatibility.isCaliberEnabled(resolved) then return "disabled", resolved end
		return "supported", resolved
	end)
	if not ok then
		Diagnostics.failure("Compatibility", "weaponStatus", tostring(state))
		return "unknown"
	end
	return state, caliber
end

-- Exposed for other mods and for automated tests.
Compatibility.inferCaliber = inferCaliber
Compatibility.normalizeCaliber = normalizeCaliber
Compatibility.getAmmoIdentity = getAmmoIdentity
Compatibility.PART_CALIBERS = PART_CALIBERS
Compatibility.UNSUPPORTED_WEAPONS = UNSUPPORTED_WEAPONS
Compatibility.PART_TYPE = "Suppressor"

function Compatibility.getPartCaliber(part)
	local ok, fullType = pcall(function() return part and part:getFullType() end)
	return ok and PART_CALIBERS[fullType] or nil
end

function Compatibility.isOilFilterSuppressor(part)
	local ok, fullType = pcall(function() return part and part:getFullType() end)
	if not ok or type(fullType) ~= "string" then return false end
	if string.find(fullType, ".Suppressor_OilFilter_", 1, true) then return true end
	local caliber = PART_CALIBERS[fullType]
	local definition = caliber and Compatibility.caliberDefinitions[caliber]
	return definition and definition.oilFilterParts and definition.oilFilterParts[fullType] == true or false
end

function Compatibility.isSuppressor(part)
	local ok, fullType = pcall(function() return part and part:getFullType() end)
	return ok and PART_CALIBERS[fullType] ~= nil
end

-- New suppressors occupy their own logical weapon-part slot. The Canon lookup
-- keeps old save data readable until migration moves it to that slot.
function Compatibility.getAttachedSuppressor(weapon)
	if not weapon then return nil end
	local part = weapon:getWeaponPart(Compatibility.PART_TYPE)
	if Compatibility.isSuppressor(part) then return part end
	part = weapon:getWeaponPart("Canon")
	if Compatibility.isSuppressor(part) then return part end
	local parts = weapon:getAllWeaponParts()
	if not parts then return nil end
	for index = 0, parts:size() - 1 do
		part = parts:get(index)
		if Compatibility.isSuppressor(part) then return part end
	end
	return nil
end
-- registerWeapon for firearms whose ammo names are not inferable.
Compatibility.registerProfile({
	id = "vanilla-b42",
	name = "Vanilla Build 42",
	weapons = {
		["Base.Pistol"] = "9mm", ["Base.Pistol2"] = "45ACP", ["Base.Pistol3"] = "44",
		["Base.AssaultRifle"] = "556", ["Base.VarmintRifle"] = "556", ["Base.JS14_Rifle"] = "556",
		["Base.AssaultRifle2"] = "308", ["Base.HuntingRifle"] = "308", ["Base.MSR7T_Rifle"] = "308",
		["Base.L94_Rifle"] = "3030", ["Base.L92_Carbine"] = "357", ["Base.TrapperCarbine"] = "45ACP",
		["Base.Shotgun"] = "12Gauge", ["Base.JS3T_Shotgun"] = "12Gauge",
	},
})


local function populateMountOn()
	local sm = getScriptManager()
	if not sm then Diagnostics.failure("Compatibility", "populateMountOn", "skipped: script manager unavailable"); return end
	local guns, scanned = {}, 0
	local ok, all = pcall(function() return sm:getAllItems() end)
	if not ok or not all then
		Diagnostics.failure("Compatibility", "populateMountOn", "getAllItems failed: " .. tostring(all))
		return
	end
	for i = 0, all:size() - 1 do
		local script = all:get(i)
		pcall(function()
			scanned = scanned + 1
			local isWeapon
			if script.isItemType and ItemType and ItemType.WEAPON then isWeapon = script:isItemType(ItemType.WEAPON) end
			if isWeapon == nil and script.getItemType then
				local itemType = tostring(script:getItemType())
				isWeapon = itemType == "base:weapon" or itemType == "Weapon"
			end
			if isWeapon == nil and script.getTypeString then isWeapon = tostring(script:getTypeString()) == "Weapon" end
			local ranged = false
			if script.isRanged then
				local okRanged, value = pcall(function() return script:isRanged() end)
				ranged = okRanged and value == true
			end
			if isWeapon and ranged then
				local fullType
				if script.getFullName then fullType = script:getFullName() end
				if not fullType and script.getModuleName and script.getName then
					fullType = tostring(script:getModuleName()) .. "." .. tostring(script:getName())
				end
				if fullType then
					guns[#guns + 1] = fullType
					Diagnostics.info("Compatibility", "mountCandidate", fullType)
				end
			end
		end)
	end
	Diagnostics.info("Compatibility", "populateMountOn", "scanned=" .. scanned .. " firearms=" .. #guns)
	Compatibility.firearmTypes = guns
end

local function populateExistingSuppressorParts()
	for playerIndex = 0, (getNumActivePlayers and getNumActivePlayers() or 0) - 1 do
		local player = getSpecificPlayer(playerIndex)
		local inventory = player and player:getInventory()
		local parts = inventory and inventory:getAllEvalRecurse(function(item)
			return PART_CALIBERS[item:getFullType()] ~= nil
		end)
		if parts then
			for index = 0, parts:size() - 1 do populatePartMountOn(parts:get(index)) end
		end
	end
end


Events.OnGameBoot.Add(SimpleSuppressorsDiagnostics.guard("Compatibility.Shared", "OnGameBoot", populateMountOn))
Events.OnGameStart.Add(SimpleSuppressorsDiagnostics.guard("Compatibility.Shared", "OnGameStart", populateMountOn))
Events.OnGameStart.Add(SimpleSuppressorsDiagnostics.guard("Compatibility.Shared", "OnGameStart.ExistingParts", populateExistingSuppressorParts))
