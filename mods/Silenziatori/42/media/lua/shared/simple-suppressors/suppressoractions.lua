require "TimedActions/ISBaseTimedAction"
require "simple-suppressors/compatibility"

-- These timed actions live in shared/ (loaded on client AND server) and are
-- declared as globals, exactly like vanilla ISUpgradeWeapon/ISRemoveWeaponUpgrade.
-- In multiplayer the client mirrors the action to the server as a NetTimedAction;
-- the server re-instantiates the class by name to validate and perform it
-- authoritatively. If the class only existed on the client the action would fill
-- to 100% and hang forever, which is why this must not live under lua/client/.
if SimpleSuppressorsActionsLoaded then return end
SimpleSuppressorsActionsLoaded = true

--------------------------------------------------------------------- attach
ISAttachSuppressor = ISBaseTimedAction:derive("ISAttachSuppressor")

function ISAttachSuppressor:isValid()
	if not self.weapon or not self.part then return false end
	if not SimpleSuppressorsCompatibility.canAttachDynamic(self.character, self.weapon, self.part) then return false end
	if isClient() then
		return self.character:getInventory():containsID(self.part:getID())
			and self.character:getInventory():containsID(self.weapon:getID())
	end
	return self.character:getInventory():contains(self.part)
end

function ISAttachSuppressor:update()
	self.weapon:setJobDelta(self:getJobDelta())
	self.part:setJobDelta(self:getJobDelta())
	self.character:setMetabolicTarget(Metabolics.LightDomestic)
end

function ISAttachSuppressor:start()
	if isClient() then
		if self.part then self.part = self.character:getInventory():getItemById(self.part:getID()) end
		if self.weapon then self.weapon = self.character:getInventory():getItemById(self.weapon:getID()) end
	end
	self.weapon:setJobType(getText("ContextMenu_SimpleSuppressors_Attaching"))
	self.weapon:setJobDelta(0.0)
	self.part:setJobType(getText("ContextMenu_SimpleSuppressors_Attaching"))
	self.part:setJobDelta(0.0)
end

function ISAttachSuppressor:stop()
	ISBaseTimedAction.stop(self)
	self.weapon:setJobDelta(0.0)
	self.part:setJobDelta(0.0)
end

function ISAttachSuppressor:perform()
	self.weapon:setJobDelta(0.0)
	self.part:setJobDelta(0.0)
	ISBaseTimedAction.perform(self)
end

function ISAttachSuppressor:complete()
	-- Swap only another suppressor. Lasers, lights, chokes, and other vanilla
	-- Canon parts are now independent and remain fitted.
	local existing = SimpleSuppressorsCompatibility.getAttachedSuppressor(self.weapon)
	if existing and existing:getFullType() ~= self.part:getFullType() then
		self.weapon:detachWeaponPart(self.character, existing)
		syncHandWeaponFields(self.character, self.weapon)
		self.character:getInventory():AddItem(existing)
		sendAddItemToContainer(self.character:getInventory(), existing)
	end
	self.weapon:attachWeaponPart(self.character, self.part)
	syncHandWeaponFields(self.character, self.weapon)
	self.character:getInventory():Remove(self.part)
	sendRemoveItemFromContainer(self.character:getInventory(), self.part)
	return true
end

function ISAttachSuppressor:getDuration()
	if self.character:isTimedActionInstant() then return 1 end
	return 50
end

function ISAttachSuppressor:new(character, weapon, part)
	local o = ISBaseTimedAction.new(self, character)
	o.weapon = weapon
	o.part = part
	o.maxTime = o:getDuration()
	return o
end

--------------------------------------------------------------------- remove
-- [moon] any working tool with the screwdriver tag, as the game itself checks (the multitool and the handiknife too:
-- before only the three screwdrivers counted, and with the others the removal was cancelled without a word)
local function notBroken(item)
	return not item:isBroken()
end

local function hasScrewdriver(character)
	local inventory = character and character:getInventory()
	if not inventory then return false end
	if ItemTag and ItemTag.SCREWDRIVER then
		return inventory:containsTagEvalRecurse(ItemTag.SCREWDRIVER, notBroken)
	end
	for _, fullType in ipairs({ "Base.Screwdriver", "Base.Screwdriver_Improvised", "Base.Screwdriver_Old" }) do
		if inventory:getFirstTypeRecurse(fullType) then return true end
	end
	return false
end

ISRemoveSuppressor = ISBaseTimedAction:derive("ISRemoveSuppressor")
ISRemoveSuppressor.hasScrewdriver = hasScrewdriver -- [moon] the menu greys the option out with the same check

function ISRemoveSuppressor:isValid()
	if not self.weapon or not self.partType or not hasScrewdriver(self.character) then return false end
	if isClient() then
		return self.character:getInventory():containsID(self.weapon:getID())
	end
	if not self.character:getInventory():contains(self.weapon) then return false end
	local part = self.weapon:getWeaponPart(self.partType)
	return part ~= nil and SimpleSuppressorsCompatibility.PART_CALIBERS[part:getFullType()] ~= nil
end

function ISRemoveSuppressor:update()
	self.weapon:setJobDelta(self:getJobDelta())
	self.character:setMetabolicTarget(Metabolics.LightDomestic)
end

function ISRemoveSuppressor:start()
	if isClient() and self.weapon then
		self.weapon = self.character:getInventory():getItemById(self.weapon:getID())
	end
	self.weapon:setJobType(getText("ContextMenu_SimpleSuppressors_Removing"))
	self.weapon:setJobDelta(0.0)
end

function ISRemoveSuppressor:stop()
	ISBaseTimedAction.stop(self)
	self.weapon:setJobDelta(0.0)
end

function ISRemoveSuppressor:perform()
	self.weapon:setJobDelta(0.0)
	ISBaseTimedAction.perform(self)
end

function ISRemoveSuppressor:complete()
	local part = self.weapon:getWeaponPart(self.partType)
	if not part then return true end
	self.weapon:detachWeaponPart(self.character, part)
	syncHandWeaponFields(self.character, self.weapon)
	self.character:getInventory():AddItem(part)
	sendAddItemToContainer(self.character:getInventory(), part)
	return true
end

function ISRemoveSuppressor:getDuration()
	if self.character:isTimedActionInstant() then return 1 end
	return 50
end

function ISRemoveSuppressor:new(character, weapon, partType)
	local o = ISBaseTimedAction.new(self, character)
	o.weapon = weapon
	o.partType = partType
	o.maxTime = o:getDuration()
	return o
end
