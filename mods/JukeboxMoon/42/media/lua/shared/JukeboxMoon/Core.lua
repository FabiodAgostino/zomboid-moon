-- JukeboxMoon: constants and the server's options, shared by client and server (docs/jukebox/TECHNICAL_DESIGN.md).
-- Plain ASCII: the texts players read are in Translate/*.json.

JukeboxMoon = JukeboxMoon or {}
if JukeboxMoon.Core then return JukeboxMoon.Core end

local Core = {}
JukeboxMoon.Core = Core

Core.MODULE = "JukeboxMoon"           -- client and server commands
Core.CONTAINER = "jukeboxmoon"        -- the container type of a converted jukebox
Core.ACCEPT = "AcceptItemFunction.JukeboxMoon"
Core.CAPACITY = 50                    -- weight units; the count of CDs is MaxCDsPerJukebox (the game caps at 100)
Core.USE_TILES = 3.5                  -- how close a player must be to use a jukebox
Core.HEAR_TILES = 40                  -- beyond this a client plays nothing for that jukebox
Core.LEAD_MS = 1200                   -- a track starts this long after the command, so every client knows in time
Core.JOIN_MS = 300                    -- a client joining within this much of a piece's start plays that piece
Core.SPAWN_MAX = 20                   -- CDs an admin can make at once
Core.ADMIN_NOTICES = { notadmin = true, badcount = true, noalbum = true, spawned = true }   -- for the admin window

-- The options of sandbox-options.txt, with the defaults of the specification when SandboxVars has none.
Core.DEFAULTS = {
	Enabled = true,
	MaxCDsPerJukebox = 20,
	ShuffleAllowed = true,
	EnableCDLoot = true,
	LootRarity = 1,
	MoodEffectsEnabled = true,
	BenefitRadiusTiles = 10,
	BoredomReductionPerGameHour = 4.0,
	StressReductionPerGameHour = 0.02,
	MoodEvaluationMinutes = 10,
	DeafBenefitMultiplier = 0.0,
	HardOfHearingBenefitMultiplier = 0.5,
	AllowCrossFloorBenefits = false,
	UniqueChance = 1.0,                 -- percent: a runner killed by a player has one of the unique CDs in play
}

local LIMITS = {
	MaxCDsPerJukebox = { 1, 100 },
	LootRarity = { 1, 3 },
	BenefitRadiusTiles = { 1, 30 },
	BoredomReductionPerGameHour = { 0, 100 },
	StressReductionPerGameHour = { 0, 1 },
	MoodEvaluationMinutes = { 1, 60 },
	DeafBenefitMultiplier = { 0, 1 },
	HardOfHearingBenefitMultiplier = { 0, 1 },
	UniqueChance = { 0, 100 },
}

-- One option: the server's value when it has the right type, the default otherwise, numbers kept in their range.
function Core.option(name)
	local default = Core.DEFAULTS[name]
	local vars = SandboxVars and SandboxVars.JukeboxMoon
	local value = vars and vars[name]
	if type(value) ~= type(default) then value = default end
	local limits = LIMITS[name]
	if limits and type(value) == "number" then
		if value < limits[1] then value = limits[1] end
		if value > limits[2] then value = limits[2] end
	end
	return value
end

function Core.maxCDs()
	return math.floor(Core.option("MaxCDsPerJukebox"))
end

-- "x,y,z" of a square: the key of a jukebox everywhere.
function Core.key(x, y, z)
	return string.format("%d,%d,%d", math.floor(x), math.floor(y), math.floor(z))
end

-- Single player runs the server's files too: commands go through the same OnClientCommand.
function Core.isServerSide()
	return not isClient()
end

-- An admin, as the game's own tools and ZomBOT check it: admin powers, or the right to draw non-PvP zones. In single
-- player the world is yours.
function Core.isAdmin(player)
	if not isClient() and not isServer() then return true end
	if not player then return false end
	local ok, admin = pcall(function()
		local role = player:getRole()
		if role == nil then return false end
		return role:hasAdminPower() or role:hasCapability(Capability.CanSetupNonPVPZone)
	end)
	return ok and admin == true
end

Core.debug = false
function Core.log(text)
	if Core.debug then print("[JukeboxMoon] " .. tostring(text)) end
end

-- Always printed: something that should not happen.
function Core.warn(text)
	print("[JukeboxMoon] " .. tostring(text))
end

return Core
