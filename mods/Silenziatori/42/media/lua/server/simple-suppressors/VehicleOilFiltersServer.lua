local Oil = require 'simple-suppressors/VehicleOil'
require "simple-suppressors/diagnostics"
if SimpleSuppressorsVehicleOilFiltersServerLoaded then return end
SimpleSuppressorsVehicleOilFiltersServerLoaded = true
SimpleSuppressorsDiagnostics.loaded("VehicleOilFilters.Server")

local ACTION_TICK_MS = 1000 / 30
local INSTALL_TIME_SECONDS = 10
local function actionDurationMs(player, seconds)
	if player and player:isTimedActionInstant() then return math.ceil(ACTION_TICK_MS) end
	return math.ceil(seconds * 1000)
end

local function removeDurationMs(player)
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	local configured = vars and tonumber(vars.OilFilterRemovalSeconds)
	-- Migrate the old 300-second default to the current 10-second default.
	if configured == 300 then configured = 10 end
	local seconds = math.max(1, configured or 10)
	return actionDurationMs(player, seconds)
end
local COMPLETION_GRACE_MS = 15000

-- The action engine can run faster than real time. Accept completion after a
-- bounded fraction of the nominal duration, while still requiring a server
-- reservation and rejecting instant replays.
-- Match the shared QualityOfLife action gate: accepting only after half
-- the nominal duration prevents fast-completion replay while tolerating
-- ordinary client/server timing drift.
local MIN_ACCEPT_FACTOR = 1 / 2

local function getEngineArea(vehicle)
    local engine = vehicle and vehicle:getPartById("Engine")
    return engine and engine:getArea()
end

local function commandVehicle(args)
	if not args or type(args.vehicle) ~= "number" then return nil end
	return getVehicleById(args.vehicle)
end

local function isEligible(player, vehicle)
    if not player or player:isDead() or not vehicle then return false end
    if Oil.enabled() and vehicle:isEngineRunning() then return false end

    local data = vehicle:getModData()
    local area = getEngineArea(vehicle)
    return data and area and not data.simpleSuppressorsOilFilterRemoved and vehicle:isInArea(area, player)
end

local function isAtEngine(player, vehicle)
	if Oil.enabled() and vehicle and vehicle:isEngineRunning() then return false end
	local area = getEngineArea(vehicle)
	return player and vehicle and area and vehicle:isInArea(area, player)
end

local function oilFilterItem(player)
	return player and player:getInventory():getFirstTypeRecurse("SimpleSuppressors.ScavengedOilFilter") or nil
end

-- [moon] This path runs only with the oil model switched off, and has no oil level to scale with: it takes a value
-- set by hand, or its own gentle default. Oil.setting() always answered the oil model's severity values instead
-- (4 condition every game minute), which killed the engine in about 25 game minutes of driving.
local function oilFilterWearSetting(name, fallback)
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	local configured = vars and tonumber(vars[name])
	return configured and math.max(1, configured) or fallback
end

-- [moon] the server never receives OnDisconnect (only clients do): drop the reservations of players who left
local function ownerGone(reservation)
	return isServer() and reservation and reservation.owner ~= nil and not getPlayerByOnlineID(reservation.owner)
end

local function rejectPlayer(player, messageKey)
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Server", "reject", "player=" .. tostring(player and player:getOnlineID()) .. " messageKey=" .. tostring(messageKey))
	if player and messageKey then
		sendServerCommand(player, "SimpleSuppressors", "oilFilterRejected", { messageKey = messageKey })
	end
end
-- a reservation left behind by a client that disconnects mid-action, instead
-- of relying solely on that same client calling cancel/complete later.
local activeRemovals = {}
local activeInstalls = {}

local function clearRemoval(vehicle)
    local data = vehicle and vehicle:getModData()
    if not data then return end
    data.simpleSuppressorsOilFilterRemoval = nil
    data.simpleSuppressorsOilFilterRemoving = nil
    vehicle:transmitModData()
    activeRemovals[vehicle:getId()] = nil
end

local function clearInstall(vehicle)
	local data = vehicle and vehicle:getModData()
	if not data then return end
	data.simpleSuppressorsOilFilterInstall = nil
	vehicle:transmitModData()
	activeInstalls[vehicle:getId()] = nil
end

local function startRemoval(player, args)
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Server", "removeStart", "player=" .. tostring(player and player:getOnlineID()) .. " vehicle=" .. tostring(args and args.vehicle))
	local vehicle = commandVehicle(args)
	if not vehicle then return end

	local data = vehicle:getModData()
	if data and data.simpleSuppressorsOilFilterRemoved then
		rejectPlayer(player, "IGUI_SimpleSuppressors_AlreadyRemoved")
		return
	end
	-- [moon] The removal flags are saved with the car. If the server stopped (or the chunk unloaded) during a
	-- removal, they came back with nobody working on it, and every later attempt was refused for good. A removal
	-- this server is not tracking, or one past its time, is a leftover.
	local removal = data and data.simpleSuppressorsOilFilterRemoval
	if data and (removal or data.simpleSuppressorsOilFilterRemoving)
		and (not activeRemovals[vehicle:getId()] or not removal or getTimestampMs() > (tonumber(removal.expiresAt) or 0)) then
		clearRemoval(vehicle)
	end
	if data and (data.simpleSuppressorsOilFilterRemoval or data.simpleSuppressorsOilFilterRemoving) then
		rejectPlayer(player, "IGUI_SimpleSuppressors_WorkInProgress")
		return
	end
	if not isEligible(player, vehicle) then
		rejectPlayer(player, "IGUI_SimpleSuppressors_StayAtEngineRemoval")
		return
	end

	local durationMs = removeDurationMs(player)
	local minAcceptMs = player:isTimedActionInstant() and durationMs or math.ceil(durationMs * MIN_ACCEPT_FACTOR)
    local now = getTimestampMs()
    data.simpleSuppressorsOilFilterRemoving = true
    data.simpleSuppressorsOilFilterRemoval = {
        owner = player:getOnlineID(),
        readyAt = now + minAcceptMs,
        expiresAt = now + durationMs + COMPLETION_GRACE_MS,
    }
    vehicle:transmitModData()
    activeRemovals[vehicle:getId()] = { vehicle = vehicle, expiresAt = data.simpleSuppressorsOilFilterRemoval.expiresAt }
end

local function cancelRemoval(player, args)
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Server", "removeCancel", "player=" .. tostring(player and player:getOnlineID()) .. " vehicle=" .. tostring(args and args.vehicle))
	local vehicle = commandVehicle(args)
    local data = vehicle and vehicle:getModData()
    local removal = data and data.simpleSuppressorsOilFilterRemoval
    if removal and removal.owner == player:getOnlineID() then
        clearRemoval(vehicle)
    end
end

local function completeRemoval(player, args)
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Server", "removeComplete", "player=" .. tostring(player and player:getOnlineID()) .. " vehicle=" .. tostring(args and args.vehicle))
	local vehicle = commandVehicle(args)
	local data = vehicle and vehicle:getModData()
	if not data or data.simpleSuppressorsOilFilterRemoved then return end
	-- A completion without a reservation is never accepted. The reservation
	-- binds this command to a validated timed action and owner.
	local removal = data.simpleSuppressorsOilFilterRemoval
	if not removal then
		rejectPlayer(player, "IGUI_SimpleSuppressors_NotReadyRemoval")
		return
	end
	if removal.owner ~= player:getOnlineID() then
		rejectPlayer(player, "IGUI_SimpleSuppressors_WorkInProgress")
		return
	end
	local now = getTimestampMs()
	if now > removal.expiresAt then
		clearRemoval(vehicle)
		rejectPlayer(player, "IGUI_SimpleSuppressors_RemovalTimedOut")
		return
	end
	if now < removal.readyAt then
		rejectPlayer(player, "IGUI_SimpleSuppressors_NotReadyRemoval")
		return
	end
	if not isEligible(player, vehicle) then
		rejectPlayer(player, "IGUI_SimpleSuppressors_StayAtEngineRemoval")
		return
	end

	local inventory = player:getInventory()
	local filter = inventory and inventory:AddItem("SimpleSuppressors.ScavengedOilFilter")
	if not filter then
		rejectPlayer(player, "IGUI_SimpleSuppressors_InventoryFull")
		return
	end
	sendAddItemToContainer(inventory, filter)
	Oil.filterRemoved(vehicle)
	data.simpleSuppressorsOilFilterRemoved = true
	clearRemoval(vehicle)
	sendServerCommand(player, "SimpleSuppressors", "oilFilterStatus", {
		messageKey = "IGUI_SimpleSuppressors_RemovedOilFilter",
	})
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Server", "removed", "vehicle=" .. tostring(vehicle:getId()))
end

local function startInstall(player, args)
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Server", "installStart", "player=" .. tostring(player and player:getOnlineID()) .. " vehicle=" .. tostring(args and args.vehicle))
	local vehicle = commandVehicle(args)
	local data = vehicle and vehicle:getModData()
	if not vehicle or not data or not data.simpleSuppressorsOilFilterRemoved then return end
	if not isAtEngine(player, vehicle) then
		rejectPlayer(player, "IGUI_SimpleSuppressors_StayAtEngineInstall")
		return
	end
	if not oilFilterItem(player) then
		rejectPlayer(player, "IGUI_SimpleSuppressors_NeedOilFilter")
		return
	end
	if data.simpleSuppressorsOilFilterInstall and getTimestampMs() <= data.simpleSuppressorsOilFilterInstall.expiresAt then
		rejectPlayer(player, "IGUI_SimpleSuppressors_WorkInProgress")
		return
	end
	local durationMs = actionDurationMs(player, INSTALL_TIME_SECONDS)
	local minAcceptMs = player:isTimedActionInstant() and durationMs or math.ceil(durationMs * MIN_ACCEPT_FACTOR)
	local now = getTimestampMs()
	data.simpleSuppressorsOilFilterInstall = {
		owner = player:getOnlineID(),
		readyAt = now + minAcceptMs,
		expiresAt = now + durationMs + COMPLETION_GRACE_MS,
	}
	vehicle:transmitModData()
	activeInstalls[vehicle:getId()] = { vehicle = vehicle, expiresAt = data.simpleSuppressorsOilFilterInstall.expiresAt }
end

local function completeInstall(player, args)
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Server", "installComplete", "player=" .. tostring(player and player:getOnlineID()) .. " vehicle=" .. tostring(args and args.vehicle))
	local vehicle = commandVehicle(args)
	local data = vehicle and vehicle:getModData()
	local install = data and data.simpleSuppressorsOilFilterInstall
	if not vehicle or not install then
		rejectPlayer(player, "IGUI_SimpleSuppressors_NotReadyInstall")
		return
	end
	if install.owner ~= player:getOnlineID() then
		rejectPlayer(player, "IGUI_SimpleSuppressors_WorkInProgress")
		return
	end
	local now = getTimestampMs()
	if now < install.readyAt then
		rejectPlayer(player, "IGUI_SimpleSuppressors_NotReadyInstall")
		return
	end
	if now > install.expiresAt then
		clearInstall(vehicle)
		rejectPlayer(player, "IGUI_SimpleSuppressors_InstallTimedOut")
		return
	end
	if not isAtEngine(player, vehicle) then
		rejectPlayer(player, "IGUI_SimpleSuppressors_StayAtEngineInstall")
		return
	end
	local filter = oilFilterItem(player)
	if not filter then
		clearInstall(vehicle)
		rejectPlayer(player, "IGUI_SimpleSuppressors_NeedOilFilter")
		return
	end
	local container = filter:getContainer() or player:getInventory()
	container:Remove(filter)
	sendRemoveItemFromContainer(container, filter)
	data.simpleSuppressorsOilFilterRemoved = nil
	data.simpleSuppressorsOilFilterDriveMinutes = nil
	activeInstalls[vehicle:getId()] = nil
	data.simpleSuppressorsOilFilterInstall = nil
	vehicle:transmitModData()
	sendServerCommand(player, "SimpleSuppressors", "oilFilterStatus", {
		messageKey = "IGUI_SimpleSuppressors_InstalledOilFilter",
	})
end

local function cancelInstall(player, args)
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Server", "installCancel", "player=" .. tostring(player and player:getOnlineID()) .. " vehicle=" .. tostring(args and args.vehicle))
	local vehicle = commandVehicle(args)
	local data = vehicle and vehicle:getModData()
	local install = data and data.simpleSuppressorsOilFilterInstall
	if install and install.owner == player:getOnlineID() then
		clearInstall(vehicle)
	end
end

local function clearPlayerReservations(player)
	local owner = player and player:getOnlineID()
	if owner == nil then return end
	for vehicleId, entry in pairs(activeRemovals) do
		local vehicle = entry.vehicle
		local data = vehicle and vehicle:getModData()
		local reservation = data and data.simpleSuppressorsOilFilterRemoval
		if reservation and reservation.owner == owner then clearRemoval(vehicle) end
	end
	for vehicleId, entry in pairs(activeInstalls) do
		local vehicle = entry.vehicle
		local data = vehicle and vehicle:getModData()
		local reservation = data and data.simpleSuppressorsOilFilterInstall
		if reservation and reservation.owner == owner then clearInstall(vehicle) end
	end
end

Events.OnDisconnect.Add(SimpleSuppressorsDiagnostics.guard("VehicleOilFilters.Server", "OnDisconnect", clearPlayerReservations))

-- Fix for a client disconnecting mid-removal: without this sweep, nothing
-- ever clears simpleSuppressorsOilFilterRemoving if the owning player never
-- sends cancel/complete again, permanently locking that vehicle's option for
-- everyone. EveryOneMinute matches the low-frequency periodic pattern this
-- codebase's sibling mod (common-sense's TraitProgression.lua) already uses
-- for server-side sweeps.
Events.EveryOneMinute.Add(SimpleSuppressorsDiagnostics.guard("VehicleOilFilters.Server", "EveryOneMinute", function()
    local now = getTimestampMs()
	for vehicleId, entry in pairs(activeRemovals) do
        local entryData = entry.vehicle and entry.vehicle:getModData()
        if now > entry.expiresAt or ownerGone(entryData and entryData.simpleSuppressorsOilFilterRemoval) then
            local vehicle = entry.vehicle
            if vehicle then
                clearRemoval(vehicle)
            else
                activeRemovals[vehicleId] = nil
            end
        end
    end
	-- Vanilla has no oil-pressure part, so model the missing filter as gradual
	-- engine wear only while somebody is actively driving the running vehicle.
	-- The former fixed 3 condition per game-minute rate destroyed an engine in
	-- one short trip; this is persisted per vehicle and configurable instead.
	local function damageDrivenVehicle(player)
		if Oil.enabled() then return end
		local vehicle = player and player:getVehicle()
		local data = vehicle and vehicle:getModData()
		if not vehicle or not data or not data.simpleSuppressorsOilFilterRemoved
			or not vehicle:isDriver(player) or not vehicle:isEngineRunning() then return end
		local engine = vehicle:getPartById("Engine")
		if engine and engine:getCondition() > 0 then
			local interval = oilFilterWearSetting("OilFilterWearMinutes", 10)
			data.simpleSuppressorsOilFilterDriveMinutes = (tonumber(data.simpleSuppressorsOilFilterDriveMinutes) or 0) + 1
			if data.simpleSuppressorsOilFilterDriveMinutes < interval then
				vehicle:transmitModData()
				return
			end
			data.simpleSuppressorsOilFilterDriveMinutes = 0
			engine:damage(oilFilterWearSetting("OilFilterEngineDamage", 1))
			vehicle:transmitPartCondition(engine)
			vehicle:transmitModData()
		end
	end
	for vehicleId, entry in pairs(activeInstalls) do
		local entryData = entry.vehicle and entry.vehicle:getModData()
		if now > entry.expiresAt or ownerGone(entryData and entryData.simpleSuppressorsOilFilterInstall) then
			local vehicle = entry.vehicle
			if vehicle then
				clearInstall(vehicle)
			else
				activeInstalls[vehicleId] = nil
			end
		end
	end
	if isServer() then
		local players = getOnlinePlayers()
		for index = 0, players:size() - 1 do damageDrivenVehicle(players:get(index)) end
	elseif not isClient() then
		-- [moon] single player only: a multiplayer client loads this server folder too, and used to damage the
		-- engine on its own copy and push its whole (maybe stale) car data to the server every game minute
		damageDrivenVehicle(getPlayer())
	end
end))

Events.OnClientCommand.Add(SimpleSuppressorsDiagnostics.guard("VehicleOilFilters.Server", "OnClientCommand", function(module, command, player, args)
	SimpleSuppressorsDiagnostics.info("VehicleOilFilters.Server", "command", "player=" .. tostring(player and player:getOnlineID()) .. " command=" .. tostring(command) .. " vehicle=" .. tostring(args and args.vehicle))
    if module ~= "SimpleSuppressors" or not player then return end
    if command == "startOilFilterRemoval" then
        startRemoval(player, args)
    elseif command == "cancelOilFilterRemoval" then
        cancelRemoval(player, args)
    elseif command == "completeOilFilterRemoval" then
        completeRemoval(player, args)
	elseif command == "startOilFilterInstall" then
		startInstall(player, args)
	elseif command == "completeOilFilterInstall" then
		completeInstall(player, args)
	elseif command == "cancelOilFilterInstall" then
		cancelInstall(player, args)
    end
end))
