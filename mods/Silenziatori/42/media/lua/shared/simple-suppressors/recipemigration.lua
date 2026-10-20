require "simple-suppressors/diagnostics"

-- Version 1.2.0's manual did not teach the .30-30 adapter or suppressor
-- recipes. Literature items and learned recipes are persisted in saves, so
-- updating the script alone cannot repair a survivor who read that manual.
if SimpleSuppressorsRecipeMigrationLoaded then return end
SimpleSuppressorsRecipeMigrationLoaded = true

local LEGACY_MANUAL_RECIPES = {
	"MakeAdapter308",
	"MakeSuppressor308",
	"MakeOilFilterSuppressor308",
}

local MISSING_3030_RECIPES = {
	"MakeAdapter3030",
	"MakeSuppressor3030",
	"MakeOilFilterSuppressor3030",
}

local function learnedLegacyManual(player)
	for _, recipeName in ipairs(LEGACY_MANUAL_RECIPES) do
		if player:isRecipeKnown(recipeName) then return true end
	end
	return false
end

-- [moon] players already looked at in this session: the original asked isRecipeKnown three times on every player
-- update, for the whole session, for everyone who never read the old manual
local checked = {}

local function migrateRecipes(player)
	if isClient() or not player then return end
	local key = tostring(player:getUsername())
	if checked[key] then return end
	checked[key] = true
	local data = player:getModData()
	if data.simpleSuppressorsRecipe3030Migration then return end
	if not learnedLegacyManual(player) then return end

	for _, recipeName in ipairs(MISSING_3030_RECIPES) do
		if not player:isRecipeKnown(recipeName) then
			player:learnRecipe(recipeName)
		end
	end
	data.simpleSuppressorsRecipe3030Migration = true
	-- [moon] learnRecipe() changes only the server's copy: send the known recipes to the player, as reading a book
	-- does, or they appeared only after reconnecting
	if isServer() then sendSyncPlayerFields(player, 0x00000007) end
	SimpleSuppressorsDiagnostics.info("RecipeMigration", "grant3030", "player=" .. tostring(player:getUsername()))
end

if not SimpleSuppressorsRecipeMigrationRegistered then
	Events.OnPlayerUpdate.Add(SimpleSuppressorsDiagnostics.guard(
		"RecipeMigration.Shared", "OnPlayerUpdate", migrateRecipes
	))
	SimpleSuppressorsRecipeMigrationRegistered = true
end
