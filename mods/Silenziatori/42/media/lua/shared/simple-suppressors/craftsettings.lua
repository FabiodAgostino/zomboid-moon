require "simple-suppressors/diagnostics"

if SimpleSuppressorsCraftSettingsLoaded then return end
SimpleSuppressorsCraftSettingsLoaded = true

SimpleSuppressorsCraftSettings = SimpleSuppressorsCraftSettings or {}
local CraftSettings = SimpleSuppressorsCraftSettings
CraftSettings.compatibilityProfiles = CraftSettings.compatibilityProfiles or {}

local MIN_CRAFT_LEVEL = 1
local MAX_CRAFT_LEVEL = 10
local applied = false

-- Keep recipe names module-local. CraftRecipe:Load rewrites the recipe identity
-- to its first argument, which must match LearnedRecipes entries.
CraftSettings.ADAPTER_RECIPES = {
    "MakeAdapterShotgun",
    "MakeAdapter556",
    "MakeAdapter9mm",
    "MakeAdapter45ACP",
    "MakeAdapter44",
    "MakeAdapter308",
    "MakeAdapter3030",
    "MakeAdapter357",
}

-- Oil-filter suppressor recipes (does not include adapters; adapters use ADAPTER_RECIPES).
CraftSettings.OIL_FILTER_RECIPES = {
    "MakeOilFilterSuppressor12Gauge",
    "MakeOilFilterSuppressor556",
    "MakeOilFilterSuppressor9mm",
    "MakeOilFilterSuppressor45ACP",
    "MakeOilFilterSuppressor308",
    "MakeOilFilterSuppressor3030",
    "MakeOilFilterSuppressor357",
    "MakeOilFilterSuppressor44",
}

-- Legacy option keys remain readable so existing servers retain their custom
-- recipe levels after the player-facing sandbox is simplified.
CraftSettings.MACHINED_LEVELS = {
    ["MakeSuppressor12Gauge"] = "Machined12GaugeCraftLevel",
    ["MakeSuppressor556"]     = "Machined556CraftLevel",
    ["MakeSuppressor9mm"]     = "Machined9mmCraftLevel",
    ["MakeSuppressor45ACP"]   = "Machined45ACPCraftLevel",
    ["MakeSuppressor308"]     = "Machined308CraftLevel",
    ["MakeSuppressor357"]     = "Machined357CraftLevel",
    ["MakeSuppressor44"]      = "Machined44CraftLevel",
    ["MakeSuppressor3030"]    = "Machined3030CraftLevel",
}

local BALANCED_CRAFT_LEVELS = {
    AdapterCraftLevel = 2,
    OilFilterCraftLevel = 3,
    Machined12GaugeCraftLevel = 8,
    Machined556CraftLevel = 7,
    Machined9mmCraftLevel = 5,
    Machined45ACPCraftLevel = 5,
    Machined308CraftLevel = 7,
    Machined357CraftLevel = 6,
    Machined44CraftLevel = 5,
    Machined3030CraftLevel = 6,
}

local PROGRESSION_OFFSETS = { [1] = -2, [2] = 0, [3] = 2 }

local function configuredLevel(optionName)
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	local legacy = vars and tonumber(vars[optionName])
	if legacy then return legacy end
	local progression = vars and math.floor(tonumber(vars.CraftingProgression) or 2) or 2
	local offset = PROGRESSION_OFFSETS[progression] or PROGRESSION_OFFSETS[2]
	return (BALANCED_CRAFT_LEVELS[optionName] or MIN_CRAFT_LEVEL) + offset
end

local function report(message)
    if SimpleSuppressorsDiagnostics and SimpleSuppressorsDiagnostics.failure then
        SimpleSuppressorsDiagnostics.failure("CraftSettings", "apply", message)
    else
        print("[Simple Suppressors] CraftSettings: " .. message)
    end
end

function CraftSettings.getAdapterCraftLevel()
    local configured = configuredLevel("AdapterCraftLevel")
    return math.max(MIN_CRAFT_LEVEL, math.min(MAX_CRAFT_LEVEL, math.floor(configured)))
end

function CraftSettings.getOilFilterCraftLevel()
    local configured = configuredLevel("OilFilterCraftLevel")
    return math.max(MIN_CRAFT_LEVEL, math.min(MAX_CRAFT_LEVEL, math.floor(configured)))
end

function CraftSettings.getMachinedLevel(recipeName)
    local optionName = CraftSettings.MACHINED_LEVELS[recipeName]
    if not optionName then return nil end
    local configured = configuredLevel(optionName)
    return math.max(MIN_CRAFT_LEVEL, math.min(MAX_CRAFT_LEVEL, math.floor(configured)))
end

function CraftSettings.registerCompatibilityProfile(profileId, settingsKey, recipes)
    if type(profileId) ~= "string" or type(settingsKey) ~= "string" or type(recipes) ~= "table" then
        return false
    end
    CraftSettings.compatibilityProfiles[profileId] = { settingsKey = settingsKey, recipes = recipes }
    -- Optional compatibility modules may register after the core module loads.
    applied = false
    return true
end

local function compatibilityLevel(settingsKey, optionName, default)
    local vars = SandboxVars and SandboxVars[settingsKey]
    local value = vars and tonumber(vars[optionName]) or default
    return math.max(MIN_CRAFT_LEVEL, math.min(MAX_CRAFT_LEVEL, math.floor(value)))
end

function CraftSettings.apply()
    if applied then return true, 0 end

    local managerOK, scriptManager = pcall(function()
        return type(getScriptManager) == "function" and getScriptManager() or nil
    end)
    if not managerOK or not scriptManager then
        report("script manager unavailable; recipe skill requirements were not changed")
        return false, 0
    end

    local function findRecipe(recipeName)
        local candidates = {
            "SimpleSuppressors." .. recipeName,
            recipeName,
        }
        for _, candidateName in ipairs(candidates) do
            local ok, recipe = pcall(function()
                return scriptManager:getCraftRecipe(candidateName)
            end)
            if ok and recipe then return recipe end
        end

        -- Some Build 42 versions index recipes by module-qualified name while
        -- others expose the bare ID. The complete list is the stable fallback.
        local listOK, recipes = pcall(function()
            return scriptManager:getAllCraftRecipes()
        end)
        if listOK and recipes then
            for index = 0, recipes:size() - 1 do
                local recipe = recipes:get(index)
                local nameOK, loadedName = pcall(function() return recipe:getName() end)
                if nameOK and (loadedName == recipeName or loadedName == "SimpleSuppressors." .. recipeName) then
                    return recipe
                end
            end
        end
        return nil
    end

    local patched = 0
    local expected = 0
    local missing = {}

    local function patch(recipeName, skillLevel)
        expected = expected + 1
        local recipe = findRecipe(recipeName)
        if not recipe then
            missing[#missing + 1] = recipeName
            return
        end
        local ok, err = pcall(function()
            recipe:Load(recipeName, "{ SkillRequired = MetalWelding:" .. tostring(skillLevel) .. ", }")
        end)
        if ok then
            patched = patched + 1
        else
            report("failed to set " .. recipeName .. " to MetalWelding:" .. skillLevel .. ": " .. tostring(err))
        end
    end

    local adapterLevel = CraftSettings.getAdapterCraftLevel()
    for _, recipeName in ipairs(CraftSettings.ADAPTER_RECIPES) do
        patch(recipeName, adapterLevel)
    end

    local oilLevel = CraftSettings.getOilFilterCraftLevel()
    for _, recipeName in ipairs(CraftSettings.OIL_FILTER_RECIPES) do
        patch(recipeName, oilLevel)
    end

    for recipeName in pairs(CraftSettings.MACHINED_LEVELS) do
        patch(recipeName, CraftSettings.getMachinedLevel(recipeName))
    end

    for _, profile in pairs(CraftSettings.compatibilityProfiles) do
        local levels = {
            adapter = compatibilityLevel(profile.settingsKey, "AdapterCraftLevel", 2),
            machined = compatibilityLevel(profile.settingsKey, "MachinedCraftLevel", 5),
            oilFilter = compatibilityLevel(profile.settingsKey, "OilFilterCraftLevel", 3),
        }
        for category, names in pairs(profile.recipes) do
            local skillLevel = levels[category]
            if skillLevel and type(names) == "table" then
                for _, recipeName in ipairs(names) do patch(recipeName, skillLevel) end
            end
        end
    end

    if #missing > 0 then
        report("recipes unavailable after script load: " .. table.concat(missing, ", "))
    elseif patched == expected then
        applied = true
    end
    return patched == expected, patched
end

-- OnGameStart is still too early in B42.20: the Lua environment exists while
-- CraftRecipe objects are not yet exposed by ScriptManager. OnGameTimeLoaded
-- runs after the world and script registries are ready, so patch there and do
-- not emit a false missing-recipe error during boot.
if Events and Events.OnGameTimeLoaded then
    Events.OnGameTimeLoaded.Add(SimpleSuppressorsDiagnostics.guard("CraftSettings.Shared", "OnGameTimeLoaded", function()
        CraftSettings.apply()
    end))
else
    CraftSettings.apply()
end
