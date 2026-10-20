if SimpleSuppressorsVehicleOilServerLoaded then return end
SimpleSuppressorsVehicleOilServerLoaded=true
local Oil=require 'simple-suppressors/VehicleOil'
local OilFluid=require 'simple-suppressors/OilFluid'
require 'simple-suppressors/VehicleOilAction'
local reservations={}

local function statusKey(kind)
    if kind=='refill' then return 'IGUI_SimpleSuppressors_OilRefilled' end
    if kind=='collect' then return 'IGUI_SimpleSuppressors_OilCollected' end
    return 'IGUI_SimpleSuppressors_OilDrained'
end

-- [moon] Every refusal now says so and frees the car. Before, a refused start or completion returned in silence: the
-- player saw nothing after the whole animation, the reservation kept the car busy for everyone for 45 s, and a
-- later completion by the same player ran the OLD reservation's kind (oil drained onto the ground when collecting
-- had been asked). A completion must also match what was reserved. The server waits for half the action instead of
-- 5 s: the action lasts about 5-6 s, so an ordinary network delay made the completion arrive "too early".
local SERVICE_KINDS={refill=true,drain=true,collect=true}
local function fail(player)
    sendServerCommand(player,'SimpleSuppressors','oilFilterStatus',{messageKey='IGUI_SimpleSuppressors_OilServiceFailed'})
end

local function handle(module,command,player,args)
    if module~='SimpleSuppressors' or not player or not args then return end
    if command~='startOilService' and command~='completeOilService' and command~='cancelOilService' then return end
    local vehicle=type(args.vehicle)=='number' and getVehicleById(args.vehicle)
    if not vehicle then return end
    local id=vehicle:getId()
    local owner=player:getOnlineID()
    local reservation=reservations[id]
    local now=getTimestampMs()
    if reservation and now>reservation.expires then reservations[id]=nil;reservation=nil end
    if command=='cancelOilService' then
        if reservation and reservation.owner==owner then reservations[id]=nil end
        return
    end
    local serviceable=Oil.enabled() and Oil.canService(player,vehicle)
    if command=='startOilService' then
        if reservation and reservation.owner~=owner then
            sendServerCommand(player,'SimpleSuppressors','oilFilterRejected',{messageKey='IGUI_SimpleSuppressors_WorkInProgress'})
            return
        end
        -- an old reservation of this same player (its cancel got lost) gives way to the new action
        reservations[id]=nil
        if not serviceable or not SERVICE_KINDS[args.kind] then fail(player);return end
        local destinationId
        if args.kind=='refill' and not Oil.canRefillFromInventory(player,vehicle) then fail(player);return end
        if args.kind=='drain' and not Oil.canDrain(vehicle) then fail(player);return end
        if args.kind=='collect' then
            destinationId=type(args.destinationId)=='number' and args.destinationId
            if not destinationId or not Oil.canCollect(player,vehicle,OilFluid.find(player,destinationId)) then fail(player);return end
        end
        reservations[id]={owner=owner,kind=args.kind,destinationId=destinationId,ready=now+(player:isTimedActionInstant() and 0 or 2500),expires=now+45000}
        return
    end
    -- completeOilService
    if not reservation or reservation.owner~=owner then return end
    reservations[id]=nil
    if not serviceable or now<reservation.ready or args.kind~=reservation.kind
        or (reservation.kind=='collect' and args.destinationId~=reservation.destinationId) then
        fail(player)
        return
    end
    local destination=reservation.kind=='collect' and OilFluid.find(player,reservation.destinationId) or nil
    local service=Oil[reservation.kind]
    local success=service and service(player,vehicle,destination)
    sendServerCommand(player,'SimpleSuppressors','oilFilterStatus',{
        messageKey=success and statusKey(reservation.kind) or 'IGUI_SimpleSuppressors_OilServiceFailed'})
end
Events.OnClientCommand.Add(handle)
Events.OnDisconnect.Add(function(player)
    if not player then return end
    for id,reservation in pairs(reservations) do
        if reservation.owner==player:getOnlineID() then reservations[id]=nil end
    end
end)

local lastTick=0
local previous={}
Events.OnTick.Add(function()
    if isClient() then return end
    local now=getTimestampMs()
    if now-lastTick<1000 then return end
    lastTick=now
    if not Oil.enabled() then previous={};return end
    local cell=getCell()
    if not cell then return end
    local time=getGameTime():getWorldAgeHours()*60
    local nextPrevious={}
    local vehicles=cell:getVehicles():iterator()
    while vehicles:hasNext() do
        local vehicle=vehicles:next()
        if vehicle:getPartById('Engine') then
            local id=vehicle:getId()
            local before=previous[id]
            local x,y=vehicle:getX(),vehicle:getY()
            nextPrevious[id]={vehicle=vehicle,time=time,x=x,y=y}
            if before and before.vehicle==vehicle then
                local elapsed=math.min(1,math.max(0,time-before.time))
                if elapsed>0 then
                    if vehicle:getModData().simpleSuppressorsOilFilterRemoved and Oil.read(vehicle).level>0 then
                        local distance=math.max(math.abs(x-before.x),math.abs(y-before.y))
                        local steps=math.min(12,math.floor(distance))
                        for i=1,steps do
                            Oil.spill(vehicle,math.floor(before.x+(x-before.x)*i/steps),math.floor(before.y+(y-before.y)*i/steps))
                        end
                    end
                    Oil.advance(vehicle,elapsed)
                end
            end
        end
    end
    previous=nextPrevious
    for id,reservation in pairs(reservations) do
        -- [moon] the server never receives OnDisconnect (only clients do): a reservation of a player who left
        -- would otherwise keep the car busy until it expires
        if now>reservation.expires or (isServer() and not getPlayerByOnlineID(reservation.owner)) then reservations[id]=nil end
    end
end)
Events.LoadGridsquare.Add(Oil.cleanSquare)
Events.EveryTenMinutes.Add(Oil.cleanStains)
