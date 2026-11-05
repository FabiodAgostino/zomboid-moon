-- SilencerMoon: "Take out the oil filter" in the right-click menu next to a vehicle. The option is shown greyed out,
-- with the reason, when something is missing (Mechanics 8, a wrench, the engine off); not at all when the filter is
-- already gone or the vehicle has no engine.

require "SilencerMoon/OilFilter"
require "SilencerMoon/Shot"
require "Vehicles/TimedActions/ISPathFindAction"

local OilFilter = SilencerMoon.OilFilter

-- The vehicle the player points at or stands next to, as the game's vehicle menu finds it.
local function vehicleFor(player)
	if not player or player:getVehicle() then return nil end
	local vehicle
	pcall(function()
		if IsoObjectPicker and IsoObjectPicker.Instance then
			vehicle = IsoObjectPicker.Instance:PickVehicle(getMouseXScaled(), getMouseYScaled())
		end
	end)
	if not vehicle and ISVehicleMenu and ISVehicleMenu.getVehicleToInteractWith then
		pcall(function() vehicle = ISVehicleMenu.getVehicleToInteractWith(player) end)
	end
	return vehicle
end

local function takeFilter(player, vehicle)
	local engine = vehicle and vehicle:getPartById("Engine")
	if not engine then return end
	ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(player, vehicle, engine:getArea()))
	ISTimedActionQueue.add(ISSilencerMoonTakeOilFilter:new(player, engine))
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
	local player = getSpecificPlayer(playerNum)
	local vehicle = vehicleFor(player)
	if not vehicle or not vehicle:getPartById("Engine") or OilFilter.taken(vehicle) then return end
	if test then return true end
	local ok, reason = OilFilter.check(player, vehicle)
	local option = context:addOption(getText("ContextMenu_SilencerMoon_TakeOilFilter"), player, takeFilter, vehicle)
	if not ok then
		option.notAvailable = true
		local tooltip = ISWorldObjectContextMenu.addToolTip()
		tooltip.description = getText(reason or "ContextMenu_SilencerMoon_FilterTaken", tostring(OilFilter.MECHANICS))
		option.toolTip = tooltip
	end
end

if not SilencerMoon.oilFilterMenuAdded then
	SilencerMoon.oilFilterMenuAdded = true
	Events.OnFillWorldObjectContextMenu.Add(SilencerMoon.Shot.guarded("OilFilterMenu", onFillWorldObjectContextMenu))
end
