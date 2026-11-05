-- SilencerMoon: taking the oil filter out of a vehicle. Mechanics 8 and a wrench, standing at the engine, engine off;
-- one filter per vehicle (the server marks the vehicle), and nothing else happens to the vehicle.
--
-- The timed action lives in shared/ and is a global, like the game's vehicle actions (ISTakeEngineParts): in
-- multiplayer the server builds it again by name and runs complete(). It is built from the Engine part, as the game
-- does, and finds the vehicle from it.

require "TimedActions/ISBaseTimedAction"
require "SilencerMoon/Core"
if SilencerMoon.OilFilter then return SilencerMoon.OilFilter end

local OilFilter = {}
SilencerMoon.OilFilter = OilFilter

OilFilter.FLAG = "SilencerMoonOilFilterTaken"
OilFilter.MECHANICS = 8
OilFilter.ITEM = "SilencerMoon.ScavengedOilFilter"
OilFilter.TIME = 300 -- about 10 seconds

local function notBroken(item)
	return not item:isBroken()
end

function OilFilter.taken(vehicle)
	return vehicle:getModData()[OilFilter.FLAG] == true
end

function OilFilter.hasWrench(character)
	return character:getInventory():containsTagEvalRecurse(ItemTag.WRENCH, notBroken) == true
end

-- Can this character take this vehicle's filter? Answers true, or false and the text that says why
-- (nil when the vehicle has no filter to offer at all).
function OilFilter.check(character, vehicle)
	if not vehicle or not vehicle:getPartById("Engine") then return false, nil end
	if OilFilter.taken(vehicle) then return false, "ContextMenu_SilencerMoon_FilterTaken" end
	if vehicle:isEngineRunning() then return false, "ContextMenu_SilencerMoon_EngineRunning" end
	if character:getPerkLevel(Perks.Mechanics) < OilFilter.MECHANICS then
		return false, "ContextMenu_SilencerMoon_NeedMechanics"
	end
	if not OilFilter.hasWrench(character) then return false, "ContextMenu_SilencerMoon_NeedWrench" end
	return true, nil
end

ISSilencerMoonTakeOilFilter = ISBaseTimedAction:derive("ISSilencerMoonTakeOilFilter")

-- No check of the position here, as in the game's own engine actions (ISTakeEngineParts, ISRepairEngine: commented
-- out): the walk to the engine comes first (ISPathFindAction), and on the server, checked every tick, a position a
-- little behind would stop the action by itself.
function ISSilencerMoonTakeOilFilter:isValid()
	-- a real boolean: the server reads it through protectedCallBoolean
	if not self.vehicle or not self.part or self.character:getVehicle() then return false end
	return OilFilter.check(self.character, self.vehicle) == true
end

function ISSilencerMoonTakeOilFilter:waitToStart()
	self.character:faceThisObject(self.vehicle)
	return self.character:shouldBeTurning()
end

function ISSilencerMoonTakeOilFilter:update()
	self.character:faceThisObject(self.vehicle)
	self.character:setMetabolicTarget(Metabolics.MediumWork)
end

function ISSilencerMoonTakeOilFilter:start()
	self:setActionAnim("VehicleWorkOnMid")
end

function ISSilencerMoonTakeOilFilter:stop()
	ISBaseTimedAction.stop(self)
end

function ISSilencerMoonTakeOilFilter:perform()
	ISBaseTimedAction.perform(self)
end

-- Server and single player: the vehicle is marked before the filter is given, so a second action on the same
-- vehicle finds it taken.
function ISSilencerMoonTakeOilFilter:complete()
	local vehicle = self.vehicle
	if not vehicle or OilFilter.taken(vehicle) then return false end
	vehicle:getModData()[OilFilter.FLAG] = true
	vehicle:transmitModData()
	local inventory = self.character:getInventory()
	local item = inventory:AddItem(OilFilter.ITEM)
	if item then sendAddItemToContainer(inventory, item) end
	addXp(self.character, Perks.Mechanics, 5)
	return true
end

function ISSilencerMoonTakeOilFilter:getDuration()
	if self.character:isTimedActionInstant() then return 1 end
	return OilFilter.TIME
end

function ISSilencerMoonTakeOilFilter:new(character, part)
	local o = ISBaseTimedAction.new(self, character)
	o.part = part
	o.vehicle = part and part:getVehicle()
	o.stopOnWalk = true
	o.stopOnRun = true
	o.stopOnAim = true
	o.maxTime = o:getDuration()
	return o
end

return OilFilter
