local Oil = require 'simple-suppressors/VehicleOil'
local OilFluid = require 'simple-suppressors/OilFluid'
local OilAction = require 'simple-suppressors/VehicleOilAction'
require "simple-suppressors/diagnostics"
require "TimedActions/ISBaseTimedAction"
require "Vehicles/TimedActions/ISPathFindAction"
SimpleSuppressorsDiagnostics.loaded("VehicleOilFilters.Client")
SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Client", "entrypoint", "loaded")
local VehicleOilFilters = {}
local function REMOVE_TIME()
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	local configured = vars and tonumber(vars.OilFilterRemovalSeconds)
	-- 300 was the old default, not a useful deliberate duration. Migrate it
	-- to the new 10-second default while preserving other custom settings.
	if configured == 300 then return 10 end
	return configured or 10
end

local ACTION_TICKS_PER_SECOND = 30
local INSTALL_TIME_SECONDS = 10
local function actionTicks(seconds)
	return math.max(1, math.ceil(seconds * ACTION_TICKS_PER_SECOND))
end

-- Build 42 mirrors client timed actions onto the server and reads isValid()
-- back through LuaCaller.protectedCallBoolean, which only accepts a real
-- boolean.  An `a and b and c` chain that falls through on a nil returns null
-- to the server, which then throws a NullPointerException out of
-- NetTimedAction.perform and cancels the action without telling anyone.
local function valid(value)
	return value and true or false
end

local function reservationActive(reservation)
	if not reservation then return false end
	-- Older clients without the timestamp helper must keep respecting the
	-- reservation; newer B42 clients can also recover from a stale one.
	return not reservation.expiresAt or not getTimestampMs or getTimestampMs() <= reservation.expiresAt
end
-- [moon] the removal flag is saved with the car: a removal past its time is a leftover (the server stopped during it),
-- not work in progress, and must not hide the car's options for good
local function removalActive(data)
	return data.simpleSuppressorsOilFilterRemoving and reservationActive(data.simpleSuppressorsOilFilterRemoval) or false
end
local function reservationOwnedBy(reservation, player)
	if not reservationActive(reservation) then return false end
	local owner = player and player:getOnlineID()
	return owner ~= nil and reservation.owner == owner
end


local ISRemoveVehicleOilFilter = ISBaseTimedAction:derive("ISRemoveVehicleOilFilter")

function ISRemoveVehicleOilFilter:isValid()
	if Oil.enabled() and self.vehicle:isEngineRunning() then return false end
	local data = self.vehicle and self.vehicle:getModData()
	if not data or data.simpleSuppressorsOilFilterRemoved then return false end

	-- If another player's removal is already in flight (synced via modData),
	-- self-cancel now instead of playing out the whole action only to have
	-- the server silently reject the completion at the end.
	if removalActive(data) then
		local removal = data.simpleSuppressorsOilFilterRemoval
		local myOnlineId = self.character and self.character:getOnlineID()
		if removal and removal.owner ~= nil and myOnlineId ~= nil and removal.owner ~= myOnlineId then
			return false
		end
	end

	return self.vehicle:isInArea(self.area, self.character)
end

function ISRemoveVehicleOilFilter:waitToStart()
	self.character:faceThisObject(self.vehicle)
	return self.character:shouldBeTurning()
end

function ISRemoveVehicleOilFilter:update()
	self.character:faceThisObject(self.vehicle)
	self.character:setMetabolicTarget(Metabolics.MediumWork)
end

function ISRemoveVehicleOilFilter:start()
	self:setActionAnim("VehicleWorkOnMid")
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Client", "removeStart", "vehicle=" .. tostring(self.vehicle and self.vehicle:getId()) .. " duration=" .. tostring(self.maxTime))
	if isClient() then
		sendClientCommand(self.character, "SimpleSuppressors", "startOilFilterRemoval", {
			vehicle = self.vehicle:getId(),
		})
	end
end

function ISRemoveVehicleOilFilter:stop()
	local data = self.vehicle and self.vehicle:getModData()
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Client", "removeStop", "vehicle=" .. tostring(self.vehicle and self.vehicle:getId()))
	if data then data.simpleSuppressorsOilFilterRemoving = nil end
	if isClient() and self.vehicle then
		sendClientCommand(self.character, "SimpleSuppressors", "cancelOilFilterRemoval", { vehicle = self.vehicle:getId() })
	end
	ISBaseTimedAction.stop(self)
end

function ISRemoveVehicleOilFilter:forceCancel()
	local data = self.vehicle and self.vehicle:getModData()
	if data then data.simpleSuppressorsOilFilterRemoving = nil end
	if isClient() and self.vehicle then
		sendClientCommand(self.character, "SimpleSuppressors", "cancelOilFilterRemoval", { vehicle = self.vehicle:getId() })
	end
end

function ISRemoveVehicleOilFilter:perform()
	local data = self.vehicle:getModData()
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Client", "removePerform", "vehicle=" .. tostring(self.vehicle and self.vehicle:getId()) .. " client=" .. tostring(isClient()))
	if data and not data.simpleSuppressorsOilFilterRemoved then
		if isClient() then
			sendClientCommand(self.character, "SimpleSuppressors", "completeOilFilterRemoval", { vehicle = self.vehicle:getId() })
		else
			Oil.filterRemoved(self.vehicle)
			data.simpleSuppressorsOilFilterRemoved = true
			data.simpleSuppressorsOilFilterRemoving = nil
			self.vehicle:transmitModData()
			self.character:getInventory():AddItem("SimpleSuppressors.ScavengedOilFilter")
			self.character:Say(getText("IGUI_SimpleSuppressors_RemovedOilFilter"))
		end
	end
	ISBaseTimedAction.perform(self)
end

local ISInstallVehicleOilFilter = ISBaseTimedAction:derive("ISInstallVehicleOilFilter")

function ISInstallVehicleOilFilter:new(character, vehicle, engine, filter)
	local action = ISBaseTimedAction.new(self, character)
	action.vehicle = vehicle
	action.engine = engine
	action.filter = filter
	action.maxTime = character:isTimedActionInstant() and 1 or actionTicks(INSTALL_TIME_SECONDS)
	action.stopOnWalk, action.stopOnRun, action.stopOnAim = true, true, true
	return action
end

function ISInstallVehicleOilFilter:isValid()
	if Oil.enabled() and self.vehicle:isEngineRunning() then return false end
	local data = self.vehicle and self.vehicle:getModData()
	return valid(data and data.simpleSuppressorsOilFilterRemoved
		and (not reservationActive(data.simpleSuppressorsOilFilterInstall)
			or reservationOwnedBy(data.simpleSuppressorsOilFilterInstall, self.character))
		and self.vehicle:isInArea(self.engine:getArea(), self.character)
		and self.filter and self.filter:getContainer() ~= nil)
end

function ISInstallVehicleOilFilter:start()
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Client", "installStart", "vehicle=" .. tostring(self.vehicle:getId()) .. " duration=" .. tostring(self.maxTime))
	self:setActionAnim("VehicleWorkOnMid")
	if isClient() then
		sendClientCommand(self.character, "SimpleSuppressors", "startOilFilterInstall", { vehicle = self.vehicle:getId() })
	end
end

function ISInstallVehicleOilFilter:stop()
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Client", "installStop", "vehicle=" .. tostring(self.vehicle:getId()))
	if isClient() then
		sendClientCommand(self.character, "SimpleSuppressors", "cancelOilFilterInstall", { vehicle = self.vehicle:getId() })
	end
	ISBaseTimedAction.stop(self)
end

function ISInstallVehicleOilFilter:perform()
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Client", "installPerform", "vehicle=" .. tostring(self.vehicle:getId()) .. " client=" .. tostring(isClient()))
	if isClient() then
		sendClientCommand(self.character, "SimpleSuppressors", "completeOilFilterInstall", { vehicle = self.vehicle:getId() })
	else
		local container = self.filter and self.filter:getContainer()
		if not container then return end
		container:Remove(self.filter)
		self.vehicle:getModData().simpleSuppressorsOilFilterRemoved = nil
		self.vehicle:transmitModData()
		self.character:Say(getText("IGUI_SimpleSuppressors_InstalledOilFilter"))
	end
	ISBaseTimedAction.perform(self)
end

local function installOilFilter(player, vehicle)
	local data = vehicle and vehicle:getModData()
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Client", "installQueue", "vehicle=" .. tostring(vehicle and vehicle:getId()))
	local filter = player and player:getInventory():getFirstTypeRecurse("SimpleSuppressors.ScavengedOilFilter")
	local engine = vehicle and vehicle:getPartById("Engine")
	if not data or not data.simpleSuppressorsOilFilterRemoved
		or reservationActive(data.simpleSuppressorsOilFilterInstall) or not filter or not engine then return end
	ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(player, vehicle, engine:getArea()))
	ISTimedActionQueue.add(ISInstallVehicleOilFilter:new(player, vehicle, engine, filter))
end

function ISRemoveVehicleOilFilter:new(character, vehicle, area)
	local action = ISBaseTimedAction.new(self, character)
	action.vehicle = vehicle
	action.area = area
	action.maxTime = character:isTimedActionInstant() and 1 or actionTicks(REMOVE_TIME())
	action.stopOnWalk = true
	action.stopOnRun = true
	action.stopOnAim = true
	return action
end

VehicleOilFilters.removeOilFilter = function(player, vehicle)
	if not player or not vehicle then return end
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Client", "removeQueue", "vehicle=" .. tostring(vehicle:getId()))
	local data = vehicle:getModData()
	local engine = vehicle:getPartById("Engine")
	if not data or data.simpleSuppressorsOilFilterRemoved or removalActive(data) or not engine then return end

	local area = engine:getArea()
	if not area then return end

	-- The server owns the removal reservation.  Do not write transient vehicle
	-- state into the client's modData copy, where a failed path could leave it
	-- permanently stale.
	local path = ISPathFindAction:pathToVehicleArea(player, vehicle, area)
	ISTimedActionQueue.add(path)
	ISTimedActionQueue.add(ISRemoveVehicleOilFilter:new(player, vehicle, area))
end

-- Resolve the vehicle the player is pointing at / standing beside, the same way
-- vanilla ISVehicleMenu does: mouse-pick first, then the useable/near vehicle.
-- Scanning worldobjects does NOT work — a BaseVehicle is not in that list, which
-- is why the menu never appeared.
local function resolveContextVehicle(player)
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
	if not vehicle and player.getNearVehicle then
		pcall(function() vehicle = player:getNearVehicle() end)
	end
	return vehicle
end

local function serviceOil(player, vehicle, kind, destination)
    local engine = vehicle:getPartById("Engine")
    if not engine then return end
    ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(player, vehicle, engine:getArea()))
    ISTimedActionQueue.add(OilAction:new(player, vehicle, kind, destination))
end

local function destinationName(player, item)
    local name = item.getName and item:getName(player)
    if name and name ~= "" then return name end
    return item.getDisplayName and item:getDisplayName() or item:getFullType()
end

local function addOilCollectionOptions(menu, player, vehicle)
    if not Oil.canDrain(vehicle) then return end
    local destinations = OilFluid.destinations(player)
    if not destinations then return end
    for index = 0, destinations:size() - 1 do
        local item = destinations:get(index)
        local option = menu:addOption(
            getText("ContextMenu_SimpleSuppressors_CollectOil", destinationName(player, item), OilFluid.format(OilFluid.freeCapacity(item))),
            player, serviceOil, vehicle, "collect", item)
        option.notAvailable = not Oil.canCollect(player, vehicle, item)
    end
end

local function addOilMenu(context, player, vehicle)
    if not Oil.enabled() then return end
    local state = Oil.read(vehicle)
    local label = getText("ContextMenu_SimpleSuppressors_EngineOil", OilFluid.format(Oil.litres(vehicle)), OilFluid.format(Oil.CAPACITY_LITRES), tostring(math.floor(state.level)))
    local root = context:addOption(label, nil, nil)
    local sub = context:getNew(context)
    context:addSubMenu(root, sub)
    if vehicle:isEngineRunning() then
        sub:addOption(getText("ContextMenu_SimpleSuppressors_StopEngine"), nil, nil).notAvailable = true
        return
    end
    local fill = sub:addOption(getText("ContextMenu_SimpleSuppressors_TopUpOil", OilFluid.format(Oil.availableLitres(player))), player, serviceOil, vehicle, "refill")
    fill.notAvailable = not Oil.canRefillFromInventory(player, vehicle)
    addOilCollectionOptions(sub, player, vehicle)
    local drain = sub:addOption(getText("ContextMenu_SimpleSuppressors_DrainOil"), player, serviceOil, vehicle, "drain")
    drain.notAvailable = not Oil.canDrain(vehicle)
    if vehicle:getModData().simpleSuppressorsOilFilterRemoved then
        sub:addOption(getText("ContextMenu_SimpleSuppressors_FitFilterFirst"), nil, nil).notAvailable = true
    end
end

VehicleOilFilters.onFillWorldObjectContextMenu = function(playerNum, context, worldobjects, test)
	local player = getSpecificPlayer(playerNum)
	if not player then return end

	-- Only offer when standing outside a vehicle.
	if player:getVehicle() then return end

	local vehicle = resolveContextVehicle(player)
	if not vehicle then return end
	local data = vehicle:getModData()
	if not data or removalActive(data) or reservationActive(data.simpleSuppressorsOilFilterInstall) then return end
	if not vehicle:getPartById("Engine") then return end

	if test then return true end
	addOilMenu(context, player, vehicle)
	if Oil.enabled() and vehicle:isEngineRunning() then return end

	if data.simpleSuppressorsOilFilterRemoved then
		local status = context:addOption(getText("ContextMenu_SimpleSuppressors_OilFilterMissing"), nil, nil)
		status.notAvailable = true
		local install = context:addOption(getText("ContextMenu_SimpleSuppressors_InstallOilFilter"), player, installOilFilter, vehicle)
		if not player:getInventory():getFirstTypeRecurse("SimpleSuppressors.ScavengedOilFilter") then install.notAvailable = true end
	else
		context:addOption(getText("ContextMenu_SimpleSuppressors_RemoveOilFilter"), player, VehicleOilFilters.removeOilFilter, vehicle)
	end
end

if not SimpleSuppressorsVehicleOilFiltersEventsRegistered then
	Events.OnFillWorldObjectContextMenu.Add(VehicleOilFilters.onFillWorldObjectContextMenu)

	-- Gives the losing side of a two-player race (or an already-removed vehicle)
	-- an audible reason their action didn't grant an item, instead of silence.
	Events.OnServerCommand.Add(function(module, command, args)
		if module ~= "SimpleSuppressors" then return end
		local player = getPlayer()
		if command == "oilFilterRejected" or command == "oilFilterStatus" then
			local messageKey = args and args.messageKey
			SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Client", "status", tostring(messageKey))
			if player and messageKey then player:Say(getText(messageKey)) end
		end
	end)

	-- Inject remove/install oil filter into the standing-near-a-car radial
	-- (V by default). Vanilla builds this via showRadialMenuOutside and resolves
	-- the eligible vehicle with getVehicleToInteractWith; mirror that exactly.
	local function oilFilterIcon()
		local ok, tex = pcall(function()
			local item = getScriptManager() and getScriptManager():getItem("SimpleSuppressors.ScavengedOilFilter")
			return item and item:getNormalTexture()
		end)
		if ok and tex then return tex end
		return getTexture("media/ui/vehicles/vehicle_repair.png")
	end

	local vanillaShowRadialMenuOutside = ISVehicleMenu.showRadialMenuOutside
	ISVehicleMenu.showRadialMenuOutside = function(player)
		vanillaShowRadialMenuOutside(player)
		if not player or player:getVehicle() then return end
		local vehicle = ISVehicleMenu.getVehicleToInteractWith(player)
		if not vehicle then return end
		local data = vehicle:getModData()
		if not data or removalActive(data) then return end
		if reservationActive(data.simpleSuppressorsOilFilterInstall) then return end
		if not vehicle:getPartById("Engine") then return end
		-- NOTE: do not gate on menu:isReallyVisible() here. Right after vanilla
		-- builds the radial the menu is not yet flagged visible, so that check
		-- silently dropped our slice — which is exactly why remove/install never
		-- appeared while crowbar pry (which does not check) did. Mirror crowbar.
		local menu = getPlayerRadialMenu(player:getPlayerNum())
		if not menu then return end
		local icon = oilFilterIcon()
        if Oil.enabled() then
            if vehicle:isEngineRunning() then return end
            if Oil.canRefillFromInventory(player, vehicle) then
                menu:addSlice(getText("ContextMenu_SimpleSuppressors_TopUpOil", OilFluid.format(Oil.availableLitres(player))), getTexture("Item_Petrol"), serviceOil, player, vehicle, "refill")
            end
        end
		if data.simpleSuppressorsOilFilterRemoved then
			local hasFilter = player:getInventory():getFirstTypeRecurse("SimpleSuppressors.ScavengedOilFilter") ~= nil
			if hasFilter then
				menu:addSlice(getText("ContextMenu_SimpleSuppressors_InstallOilFilter"), icon, installOilFilter, player, vehicle)
			end
		else
			menu:addSlice(getText("ContextMenu_SimpleSuppressors_RemoveOilFilter"), icon, VehicleOilFilters.removeOilFilter, player, vehicle)
		end
	end

SimpleSuppressorsVehicleOilFiltersEventsRegistered = true
end

return VehicleOilFilters
