-- One authoritative source for the visible length of a mounted suppressor.
-- Mesh scale, smoke origin, and every compatibility mount must use the same
-- pistol classification so a later visual adjustment cannot split them apart.
local Metrics = {}

local BASE_LENGTHS = {
    ["12Gauge"] = 0.15875, ["556"] = 0.1626, ["9mm"] = 0.1158,
    ["45ACP"] = 0.2184, ["44"] = 0.144144, ["308"] = 0.1626,
    ["3030"] = 0.1626, ["357"] = 0.2,
}
local OIL_FILTER_LENGTH = 0.0648
local PISTOL_SCALE = { ["9mm"] = 0.8, ["45ACP"] = 0.6 }
local VANILLA_PISTOLS = { ["Base.Pistol"] = true, ["Base.Pistol2"] = true }

function Metrics.isPistol(weapon)
    local attachmentType
    pcall(function() attachmentType = weapon and weapon:getAttachmentType() end)
    if attachmentType == "Holster" then return true end
    local fullType
    pcall(function() fullType = weapon and weapon:getFullType() end)
    return VANILLA_PISTOLS[fullType] == true
end

function Metrics.lengthFor(weapon, caliber, oilFilter)
    local definition = SimpleSuppressorsCompatibility and SimpleSuppressorsCompatibility.getCaliberDefinition
        and SimpleSuppressorsCompatibility.getCaliberDefinition(caliber)
    local length = oilFilter and OIL_FILTER_LENGTH or BASE_LENGTHS[caliber] or (definition and definition.length)
    if not length then return nil end
    local scale = Metrics.isPistol(weapon) and (PISTOL_SCALE[caliber] or (definition and definition.pistolScale))
    return length * (scale or 1)
end

return Metrics
