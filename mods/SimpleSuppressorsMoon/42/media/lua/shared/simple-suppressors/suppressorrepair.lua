require "simple-suppressors/diagnostics"
if SimpleSuppressorsRepairLoaded then return end
SimpleSuppressorsRepairLoaded = true

SimpleSuppressorsRepair = SimpleSuppressorsRepair or {}
local Repair = SimpleSuppressorsRepair

local function enabled()
    local vars = SandboxVars and SandboxVars.SimpleSuppressors
    return not vars or vars.EnableSuppressorRepairs ~= false
end

function Repair.canRepair(item)
    if not enabled() or not item then return false end
    local ok, condition = pcall(function() return item:getCondition() end)
    return ok and type(condition) == "number" and condition < 100
end

-- Craft recipes consume the worn machined suppressor and create a fresh instance.
-- This hook keeps full-condition parts out of the repair menu.
RecipeCodeOnTest = RecipeCodeOnTest or {}
RecipeCodeOnTest.simpleSuppressorRepair = function(item)
    return Repair.canRepair(item)
end
