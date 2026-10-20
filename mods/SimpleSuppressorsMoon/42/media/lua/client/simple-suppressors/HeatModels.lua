-- Build private weapon-part render lists through the normal script parser.
-- Never mutate a shared ModelWeaponPart, model material, or inventory part type.
--
-- [moon] A weapon whose script has no render mapping for the mounted suppressor (another firearm mod replaced
-- it, or a vanilla attachment changes the list) used to raise an error here. HeatVisuals caught it with pcall
-- and tried again every second, and every caught error made the game write a whole stack trace in its log,
-- until the error ticker spiked and the game crashed (9mm oil filter and 5.56 reports, October 2026). The
-- builders now answer nil and a reason instead: no glow on that weapon, and no errors at all.
local HeatModels = {}
local variants = {}

local function heatedModel(name, stage)
    local key = name .. "_SSHeat" .. stage
    if variants[key] then return variants[key] end
    local manager = ScriptManager.instance
    local original = manager:getModelScript(name)
    if not original then return nil, "missing suppressor model " .. tostring(name) end
    local bodies = original:getLoadedScriptBodies()
    if not bodies or bodies:size() < 2 then return nil, "missing model source " .. tostring(name) end
    local clone = ModelScript.new()
    clone:setModule(original:getModule())
    local shortName = original:getName() .. "_SSHeat" .. stage
    clone:InitLoadPP(shortName)
    for i = 1, bodies:size() - 1, 2 do
        local body = bodies:get(i)
        -- Last property wins in ModelScript.Load. All mesh/attachment settings
        -- are copied from the installed model, including compatibility profiles.
        body = body:gsub("}%s*$", "\nshader = SS_Heat" .. stage .. ",\n}")
        clone:Load(shortName, body)
    end
    manager:addModelScript(clone)
    local fullName = original:getModule():getName() .. "." .. shortName
    variants[key] = fullName
    return fullName
end

-- The hot render list for this weapon and suppressor, or nil, why it cannot be made, and true when the reason is
-- this one weapon's own list rather than its type.
function HeatModels.build(weapon, partType, stage, originalMappings)
    local source = weapon:getScriptItem()
    local bodies = source:getLoadedScriptBodies()
    local scratch = Item.new()
    scratch:setModule(source:getModule())
    -- This temporary parser object is never registered as a new item type.
    scratch:Load(source:getName(), "item " .. source:getName() .. " { ItemType = base:weapon, }")
    local matched, sourceMappings, failure = false, {}, nil
    local function addMapping(value)
        scratch:DoParam("ModelWeaponPart", value)
        sourceMappings[value] = true
    end
    local function hot(part, model, attachments)
        local heated, why = heatedModel(model, stage)
        if not heated then
            failure = why
            return nil
        end
        matched = true
        return part .. " " .. heated .. attachments
    end
    for i = 1, bodies:size() - 1, 2 do
        local body = bodies:get(i):gsub("/%*.-%*/", ""):gsub("//[^\n]*", "")
        for key, value in body:gmatch("([%w_]+)%s*=%s*([^,}]+)") do
            if key:lower() == "modelweaponpart" then
                local originalValue = value
                local part, model, attachments = value:match("^%s*(%S+)%s+(%S+)(.*)$")
                if part == partType then
                    value = hot(part, model, attachments) or value
                end
                addMapping(value)
                sourceMappings[originalValue] = true
            end
        end
    end
    -- Dedicated patches use authored script mappings. Universal and the
    -- dynamic portions of the dedicated patches register only mounts that
    -- successfully reached the live weapon script at boot.
    local registry = SimpleSuppressorsHeatMappings
    local registered = registry and registry.get and registry.get(weapon:getFullType())
    if registered then
        for _, value in ipairs(registered) do
            local part, model, attachments = value:match("^%s*(%S+)%s+(%S+)(.*)$")
            if part and model and not sourceMappings[value] then
                if part == partType then
                    value = hot(part, model, attachments) or value
                end
                addMapping(value)
            end
        end
    end
    if not matched then
        return nil, failure or ("no installed render mapping for " .. tostring(partType))
    end
    local donor = scratch:InstanceItem(nil, false)
    local mappings = donor and donor:getModelWeaponPart()
    if not (mappings and originalMappings and mappings:size() == originalMappings:size()) then
        return nil, "weapon render mappings changed outside the installed scripts", true
    end
    return mappings
end

-- [moon] true when the list is one of the hot lists made for this weapon: never take it as the cold one
local function isHotList(state, list)
    for _, hot in pairs(state.mappingCache or {}) do
        if hot == list then return true end
    end
    return false
end

-- true: the hot list is installed (or the weapon is cold again); false, why and (true when only this weapon is
-- concerned): this weapon cannot glow.
function HeatModels.apply(state, stage)
    if stage == 0 then
        HeatModels.restore(state)
        return true
    end
    local current = state.weapon:getModelWeaponPart()
    if state.applied and current ~= state.applied then
        -- Reloading/chambering can rebuild this private list. Adopt that list as
        -- the new cold baseline and recreate the hot mapping on the next lines.
        -- [moon] unless it is one of our own hot lists, put back by a firearm mod that saved it while hot: then
        -- the cold baseline is still the one we have
        state.applied, state.stage = nil, 0
        if not isHotList(state, current) then
            state.originalMappings, state.mappingCache = current, {}
        end
    elseif not state.applied and state.originalMappings and current ~= state.originalMappings
        and not isHotList(state, current) then
        -- [moon] cold, but the list changed meanwhile (a firearm mod replaced it): that is the cold list now, and
        -- the hot lists made from the old one would bring the old one back
        state.originalMappings, state.mappingCache = current, {}
    end
    if state.stage == stage then return true end
    state.originalMappings = state.originalMappings or current
    state.mappingCache = state.mappingCache or {}
    local mappings = state.mappingCache[stage]
    if not mappings then
        local why, onlyThisWeapon
        mappings, why, onlyThisWeapon = HeatModels.build(state.weapon, state.part:getFullType(), stage,
            state.originalMappings)
        if not mappings then return false, why, onlyThisWeapon end
        state.mappingCache[stage] = mappings
    end
    state.weapon:setModelWeaponPart(mappings)
    state.applied, state.stage = mappings, stage
    state.owner:resetModelNextFrame()
    return true
end

function HeatModels.restore(state)
    if state.applied and state.weapon:getModelWeaponPart() == state.applied then
        state.weapon:setModelWeaponPart(state.originalMappings)
        state.owner:resetModelNextFrame()
    end
    state.applied, state.stage = nil, 0
end

return HeatModels
