require 'TimedActions/ISBaseTimedAction'
local Oil=require 'simple-suppressors/VehicleOil'
local OilFluid=require 'simple-suppressors/OilFluid'
ISSimpleSuppressorsOilService=ISBaseTimedAction:derive('ISSimpleSuppressorsOilService')

function ISSimpleSuppressorsOilService:destinationItem()
    if not self.destination then return nil end
    self.destination=OilFluid.find(self.character,self.destination:getID())
    return self.destination
end

local function commandArgs(action)
    local destination=action:destinationItem()
    return {
        vehicle=action.vehicle:getId(),
        kind=action.kind,
        destinationId=destination and destination:getID() or nil,
    }
end

local function statusKey(kind)
    if kind=='refill' then return 'IGUI_SimpleSuppressors_OilRefilled' end
    if kind=='collect' then return 'IGUI_SimpleSuppressors_OilCollected' end
    return 'IGUI_SimpleSuppressors_OilDrained'
end

function ISSimpleSuppressorsOilService:new(character,vehicle,kind,destination)
    local action=ISBaseTimedAction.new(self,character)
    action.vehicle=vehicle
    action.kind=kind
    action.destination=destination
    action.maxTime=character:isTimedActionInstant() and 1 or 300
    action.stopOnWalk,action.stopOnRun,action.stopOnAim=true,true,true
    return action
end

function ISSimpleSuppressorsOilService:isValid()
    if not Oil.enabled() or not Oil.canService(self.character,self.vehicle) then return false end
    if self.kind=='drain' then return Oil.canDrain(self.vehicle) end
    if self.kind=='collect' then return Oil.canCollect(self.character,self.vehicle,self:destinationItem()) end
    return self.kind=='refill' and Oil.canRefillFromInventory(self.character,self.vehicle)
end

function ISSimpleSuppressorsOilService:waitToStart()
    self.character:faceThisObject(self.vehicle)
    return self.character:shouldBeTurning()
end

function ISSimpleSuppressorsOilService:start()
    self:setActionAnim('VehicleWorkOnMid')
    if isClient() then
        sendClientCommand(self.character,'SimpleSuppressors','startOilService',commandArgs(self))
    end
end

function ISSimpleSuppressorsOilService:update()
    self.character:faceThisObject(self.vehicle)
    self.character:setMetabolicTarget(Metabolics.MediumWork)
end

function ISSimpleSuppressorsOilService:stop()
    if isClient() then sendClientCommand(self.character,'SimpleSuppressors','cancelOilService',{vehicle=self.vehicle:getId()}) end
    ISBaseTimedAction.stop(self)
end

function ISSimpleSuppressorsOilService:perform()
    if isClient() then
        sendClientCommand(self.character,'SimpleSuppressors','completeOilService',commandArgs(self))
    else
        local service=Oil[self.kind]
        if service and service(self.character,self.vehicle,self:destinationItem()) then
            self.character:Say(getText(statusKey(self.kind)))
        end
    end
    ISBaseTimedAction.perform(self)
end

return ISSimpleSuppressorsOilService
