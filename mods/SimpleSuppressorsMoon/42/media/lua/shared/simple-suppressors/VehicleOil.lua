-- Oil state and service rules are shared; only the server (or solo game) mutates them.
local Oil = {}
local OilFluid = require 'simple-suppressors/OilFluid'
Oil.CAPACITY_LITRES = OilFluid.VEHICLE_CAPACITY_LITRES
function Oil.enabled()
    local vars = SandboxVars and SandboxVars.SimpleSuppressors
    return not vars or vars.EnableVehicleOil ~= false
end
function Oil.setting(key, fallback)
    local vars = SandboxVars and SandboxVars.SimpleSuppressors
    -- Honor legacy per-value configuration, then use the single visible
    -- vehicle-oil severity choice for new saves.
    local legacy = vars and tonumber(vars[key])
    if legacy then return math.max(1, legacy) end
    local severity = vars and math.floor(tonumber(vars.VehicleOilSeverity) or 2) or 2
    local values = {
        OilFilterWearMinutes = { [1] = 2, [2] = 1, [3] = 1 },
        OilFilterEngineDamage = { [1] = 2, [2] = 4, [3] = 6 },
    }
    local configured = values[key] and values[key][severity]
    return math.max(1, configured or fallback)
end
function Oil.state(vehicle)
    local data = vehicle:getModData()
    if not data.simpleSuppressorsOil then
        -- Existing vehicles start serviced; an already missing filter starts low.
        data.simpleSuppressorsOil = {level=data.simpleSuppressorsOilFilterRemoved and 85 or 100, quality=100, wear=0}
    end
    return data.simpleSuppressorsOil
end
function Oil.read(vehicle)
    local data = vehicle:getModData()
    return data.simpleSuppressorsOil or {level=data.simpleSuppressorsOilFilterRemoved and 85 or 100,quality=100}
end
function Oil.canService(player, vehicle)
    local engine = vehicle and vehicle:getPartById('Engine')
    return player ~= nil and not player:isDead() and player:getVehicle() == nil
        and engine ~= nil and not vehicle:isEngineRunning()
        and vehicle:isInArea(engine:getArea(), player)
end
function Oil.canRefill(vehicle)
    return not vehicle:getModData().simpleSuppressorsOilFilterRemoved and Oil.read(vehicle).level < 100
end
function Oil.litres(vehicle)
    return Oil.CAPACITY_LITRES * Oil.read(vehicle).level / 100
end
function Oil.freeLitres(vehicle)
    return math.max(0, Oil.CAPACITY_LITRES - Oil.litres(vehicle))
end
function Oil.availableLitres(player)
    return OilFluid.available(player)
end
function Oil.canRefillFromInventory(player, vehicle)
    return Oil.canRefill(vehicle) and Oil.freeLitres(vehicle) > OilFluid.EPSILON and OilFluid.hasSource(player)
end
function Oil.canDrain(vehicle)
    return Oil.read(vehicle).level > 0
end

function Oil.canCollect(player, vehicle, destination)
    return Oil.canService(player, vehicle) and Oil.canDrain(vehicle) and OilFluid.canReceive(destination)
end

function Oil.collect(player, vehicle, destination)
    if not Oil.enabled() or not Oil.canCollect(player, vehicle, destination) then return false end
    local state = Oil.state(vehicle)
    local collected = OilFluid.fill(destination, Oil.litres(vehicle))
    if collected <= OilFluid.EPSILON then return false end
    state.level = math.max(0, state.level - collected / Oil.CAPACITY_LITRES * 100)
    state.quality = state.level > OilFluid.EPSILON and 100 or 0
    vehicle:transmitModData()
    return true, collected
end
function Oil.refill(player, vehicle)
    if not Oil.enabled() or not Oil.canService(player,vehicle) or not Oil.canRefillFromInventory(player,vehicle) then return false end
    local state = Oil.state(vehicle)
    local added = OilFluid.take(player, Oil.freeLitres(vehicle))
    if added <= OilFluid.EPSILON then return false end
    state.level = math.min(100, state.level + added / Oil.CAPACITY_LITRES * 100)
    -- Oil does not expire simply because time passes.  The system models an
    -- actual leak and an empty sump, not a calendar-driven oil-change chore.
    state.quality = 100
    vehicle:transmitModData()
    return true, added
end
function Oil.drain(player, vehicle)
    if not Oil.enabled() or not Oil.canService(player,vehicle) or not Oil.canDrain(vehicle) then return false end
    local state = Oil.state(vehicle)
    Oil.deposit(vehicle,state.level)
    state.level=0
    state.quality=0
    vehicle:transmitModData()
    return true
end

-- Native floor overlays sit on the road and persist/sync as ordinary world objects.
-- A near-black tint changes the irregular stain into an oil patch, without particles.
local stains = {}
-- [moon] getModData() CREATES an empty table on an object that has none, and the server checks every object of every
-- square it loads (LoadGridsquare): the original left an empty table on every wall, floor and tree of every chunk
-- loaded since the server started. Ask first whether the object has any.
local function isOilSpill(object)
    return object:hasModData() and object:getModData().simpleSuppressorsOilSpill or nil
end
function Oil.spill(vehicle, x, y)
    if not Oil.enabled() or isClient() then return end
    local square
    if x then square=getCell():getGridSquare(x,y,math.floor(vehicle:getZ()))
    else
        square=vehicle:getSquare()
    end
    if not square or not square:getFloor() then return end
    local objects=square:getObjects()
    for i=0,objects:size()-1 do
        if isOilSpill(objects:get(i)) then return objects:get(i) end
    end
    local variant=(square:getX()+square:getY())%4
    local object=IsoObject.new(square,'overlay_blood_floor_01_'..variant,'Oil spill')
    object:setCustomColor(0.04,0.03,0.02,0.95)
    object:getModData().simpleSuppressorsOilSpill=getGameTime():getWorldAgeHours()+48
    square:AddTileObject(object)
    if isServer() then object:transmitCompleteItemToClients() end
    stains[#stains+1]=object
    -- Bound persistent trail growth even on a long drive or a busy server.
    if #stains>512 then
        local oldest=table.remove(stains,1)
        local oldSquare=oldest:getSquare()
        if oldSquare then oldSquare:transmitRemoveItemFromSquare(oldest) end
    end
    return object
end

-- Accumulate actual oil loss, so a parked car grows one connected puddle.
-- A full sump covers at most four tiles; repeated ticks cannot grow it forever.
local puddleOffsets={{1,0},{0,1},{1,1},{-1,0}}
local PUDDLE_EXPANSION_THRESHOLDS={10,20,30,50}
function Oil.deposit(vehicle, amount)
    if amount<=0 then return end
    local object=Oil.spill(vehicle)
    if not object then return end
    local data=object:getModData()
    local previous=tonumber(data.simpleSuppressorsOilVolume) or 0
    local volume=math.min(100,previous+amount)
    data.simpleSuppressorsOilVolume=volume
    data.simpleSuppressorsOilSpill=getGameTime():getWorldAgeHours()+48
    local square=object:getSquare()
    for index,offset in ipairs(puddleOffsets) do
        if volume>=PUDDLE_EXPANSION_THRESHOLDS[index] then
            Oil.spill(vehicle,square:getX()+offset[1],square:getY()+offset[2])
        end
    end
    if isServer() and math.floor(previous)~=math.floor(volume) then object:transmitModData() end
end
function Oil.cleanSquare(square)
    if isClient() then return end
    local objects=square:getObjects()
    local now=getGameTime():getWorldAgeHours()
    for i=objects:size()-1,0,-1 do
        local object=objects:get(i)
        local expires=isOilSpill(object)
        if expires and (not Oil.enabled() or now>=expires) then square:transmitRemoveItemFromSquare(object) end
    end
end
function Oil.cleanStains()
    for i=#stains,1,-1 do
        local object=stains[i]
        local square=object:getSquare()
        if square then Oil.cleanSquare(square) end
        if not object:getSquare() then table.remove(stains,i) end
    end
end
function Oil.filterRemoved(vehicle)
    if not Oil.enabled() then return end
    local state=Oil.state(vehicle)
    -- Removal makes a noticeable mess, but leaves most oil in the engine;
    -- the subsequent leak is the actual consequence of driving without it.
    local lost=math.min(state.level,15)
    Oil.deposit(vehicle,lost)
    state.level=state.level-lost
    vehicle:transmitModData()
end
function Oil.advance(vehicle, minutes)
    if not Oil.enabled() or minutes<=0 then return end
    local engine=vehicle:getPartById('Engine')
    if not engine then return end
    local running=vehicle:isEngineRunning()
    if not running and not vehicle:getModData().simpleSuppressorsOilFilterRemoved then return end
    local state=Oil.state(vehicle)
    local previousLevel=math.floor(state.level)
    if vehicle:getModData().simpleSuppressorsOilFilterRemoved and state.level>0 then
        -- A missing filter leaks slowly while parked (gravity only) and much
        -- faster once the oil pump is pressurizing a system with nothing to
        -- seal it: a full sump empties in minutes of driving, not hours.
        local lost=math.min(state.level,minutes*(running and 10.0 or 0.3))
        Oil.deposit(vehicle,lost)
        state.level=state.level-lost
    end
    if not running then
        if previousLevel~=math.floor(state.level) then vehicle:transmitModData() end
        return
    end
    if state.level<25 then
        state.wear=(state.wear or 0)+minutes
        local interval=Oil.setting('OilFilterWearMinutes',1)
        if state.wear>=interval then
            local count=math.floor(state.wear/interval)
            state.wear=state.wear-count*interval
            -- Oil carries heat and keeps a pressurized film between bearings.
            -- Once the pickup begins to uncover, that film collapses under
            -- load: low oil wears, critical oil hammers the bearings, and a
            -- dry sump quickly scuffs/seizes them.
            local multiplier = state.level <= 0 and 20
                or state.level <= 10 and 6
                or state.level < 25 and 2
                or 1
            engine:damage(count*Oil.setting('OilFilterEngineDamage',4)*multiplier)
            vehicle:transmitPartCondition(engine)

            local condition
            pcall(function() condition=engine:getCondition() end)
            -- [moon] a repaired engine can seize again: the flag only says this seizure was already handled
            if state.seized and condition and condition > 0 then state.seized=nil end
            if state.level <= 0 and condition and condition <= 0 and not state.seized then
                state.seized=true
                -- A seized bearing stops the crankshaft.  Use the vehicle's
                -- native stall transition so speed and engine audio shut down
                -- cleanly on both solo and multiplayer servers.
                pcall(function() vehicle:engineDoStalling() end)
            end
        end
    else state.wear=0;state.seized=nil end
    if previousLevel~=math.floor(state.level) then
        vehicle:transmitModData()
    end
end
return Oil
