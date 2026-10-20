-- Build 42 fluid helpers for vehicle oil.  Amounts are expressed in litres,
-- which is also the unit used by FluidContainer.
local OilFluid = {}

OilFluid.VEHICLE_CAPACITY_LITRES = 4.0
OilFluid.EPSILON = 0.0001

function OilFluid.fluid()
    if not Fluid then return nil end
    -- Fluid.Get is the public B42 lookup.  The short-name fallback keeps this
    -- compatible with builds that expose mod fluids through their local name.
    if Fluid.Get then
        local ok, fluid = pcall(Fluid.Get, "SimpleSuppressors.EngineOil")
        if ok and fluid then return fluid end
        ok, fluid = pcall(Fluid.Get, "EngineOil")
        if ok and fluid then return fluid end
    end
    return Fluid.EngineOil
end

function OilFluid.container(item)
    if not item or not item.getFluidContainer then return nil end
    return item:getFluidContainer()
end

function OilFluid.amount(item)
    local container = OilFluid.container(item)
    if not container then return 0 end
    return math.max(0, tonumber(container:getAmount()) or 0)
end

function OilFluid.isEngineOil(item)
    local container, fluid = OilFluid.container(item), OilFluid.fluid()
    return container ~= nil and fluid ~= nil and OilFluid.amount(item) > OilFluid.EPSILON
        and container:isPureFluid(fluid)
end

function OilFluid.freeCapacity(item)
    local container = OilFluid.container(item)
    if not container or not container.getFreeCapacity then return 0 end
    return math.max(0, tonumber(container:getFreeCapacity()) or 0)
end

function OilFluid.canReceive(item)
    local container, fluid = OilFluid.container(item), OilFluid.fluid()
    if not container or not fluid or OilFluid.freeCapacity(item) <= OilFluid.EPSILON
        or not container.canAddFluid or not container:isEmpty() and not container:isPureFluid(fluid) then
        return false
    end
    return container:canAddFluid(fluid)
end

function OilFluid.destinations(player)
    local inventory = player and player:getInventory()
    if not inventory then return nil end
    return inventory:getAllEvalRecurse(OilFluid.canReceive)
end

function OilFluid.find(player, itemId)
    if type(itemId) ~= "number" then return nil end
    local inventory = player and player:getInventory()
    if not inventory then return nil end
    local item = inventory:getItemById(itemId)
    if item then return item end
    local items = inventory:getAllEvalRecurse(function(candidate)
        return candidate:getID() == itemId
    end)
    return items and items:size() > 0 and items:get(0) or nil
end

function OilFluid.fill(item, requested)
    requested = math.max(0, tonumber(requested) or 0)
    if requested <= OilFluid.EPSILON or not OilFluid.canReceive(item) then return 0 end
    local amount = math.min(requested, OilFluid.freeCapacity(item))
    if amount <= OilFluid.EPSILON then return 0 end
    OilFluid.container(item):addFluid(OilFluid.fluid(), amount)
    OilFluid.sync(item)
    return amount
end

local function sources(player)
    local inventory = player and player:getInventory()
    if not inventory then return nil end
    return inventory:getAllEvalRecurse(function(item)
        return OilFluid.isEngineOil(item)
    end)
end

function OilFluid.available(player)
    local items, total = sources(player), 0
    if not items then return total end
    for index = 0, items:size() - 1 do
        total = total + OilFluid.amount(items:get(index))
    end
    return total
end

function OilFluid.hasSource(player)
    return OilFluid.available(player) > OilFluid.EPSILON
end

function OilFluid.format(amount)
    amount = math.max(0, tonumber(amount) or 0)
    if amount < 1 then return tostring(math.floor(amount * 1000 + 0.5)) .. " mL" end
    return string.format("%.2g L", amount)
end

function OilFluid.sync(item)
    if not item then return end
    if item.syncItemFields then item:syncItemFields() end
end

-- Consume oil only after the caller has established that the destination has
-- room.  Each source is revalidated immediately before mutation, so an empty
-- or mixed container cannot create free vehicle oil in multiplayer.
function OilFluid.take(player, requested)
    requested = math.max(0, tonumber(requested) or 0)
    if requested <= OilFluid.EPSILON then return 0 end
    local items, taken = sources(player), 0
    if not items then return taken end
    for index = 0, items:size() - 1 do
        if taken >= requested - OilFluid.EPSILON then break end
        local item = items:get(index)
        if OilFluid.isEngineOil(item) then
            local amount = math.min(OilFluid.amount(item), requested - taken)
            if amount > OilFluid.EPSILON then
                OilFluid.container(item):removeFluid(amount)
                taken = taken + amount
                OilFluid.sync(item)
            end
        end
    end
    return taken
end

return OilFluid
