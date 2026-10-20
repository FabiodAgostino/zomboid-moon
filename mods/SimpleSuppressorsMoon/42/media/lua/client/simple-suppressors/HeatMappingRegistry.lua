-- Keep the exact successful runtime mounts here so HeatModels can create a
-- shader variant without guessing a socket or relying on script-body mutation.
if SimpleSuppressorsHeatMappingRegistryLoaded then return SimpleSuppressorsHeatMappings end
SimpleSuppressorsHeatMappingRegistryLoaded = true

local HeatMappings = { byWeapon = {}, seen = {} }

function HeatMappings.register(weaponType, value)
    if type(weaponType) ~= "string" or type(value) ~= "string" then return false end
    local part, model, child, parent = value:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*$")
    if not part or not model or not child or not parent then return false end
    local key = weaponType .. "\n" .. value
    if HeatMappings.seen[key] then return true end
    HeatMappings.seen[key] = true
    local list = HeatMappings.byWeapon[weaponType]
    if not list then
        list = {}
        HeatMappings.byWeapon[weaponType] = list
    end
    list[#list + 1] = value
    return true
end

function HeatMappings.get(weaponType)
    return type(weaponType) == "string" and HeatMappings.byWeapon[weaponType] or nil
end

SimpleSuppressorsHeatMappings = HeatMappings
return HeatMappings
