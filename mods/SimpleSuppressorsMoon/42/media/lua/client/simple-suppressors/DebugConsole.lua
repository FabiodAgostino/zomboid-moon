require "simple-suppressors/diagnostics"
require "simple-suppressors/compatibility"
SimpleSuppressorsDiagnostics.loaded("DebugConsole.Client")

-- Dev/testing console commands. Type these directly into the in-game debug
-- console (Debug mode must be on): SS.help() lists everything below.
--
-- The one thing Lua genuinely cannot see is the CONTENT of a resolved
-- ModelWeaponPart (reading .partType/.modelName/etc. on an individual entry
-- throws "attempted index of non-table" -- it is opaque Java userdata). What
-- Lua CAN do is call size()/get() on the ArrayList that getModelWeaponPart()
-- returns, since that is a plain java.util.List. That count is enough to
-- prove whether a script's ModelWeaponPart entries actually merged onto a
-- given weapon at the engine level, independent of whether the mesh renders.
SimpleSuppressorsDebug = SimpleSuppressorsDebug or {}
-- Deliberately global (not local): the debug console evaluates typed
-- commands in the global environment, not this file's local scope. A local
-- `SS` here is invisible from the console and throws "attempted index of
-- non-table: null" the moment you type SS.anything().
SS = SimpleSuppressorsDebug
SS._commands = SS._commands or {}

local Compat = SimpleSuppressorsCompatibility

local function register(name, help, fn)
	SS._commands[name] = help
	SS[name] = fn
end

local function player()
	return getSpecificPlayer(0) or getPlayer()
end

local function heldWeapon(p)
	p = p or player()
	if not p then return nil end
	local item = p:getPrimaryHandItem()
	if item and instanceof(item, "HandWeapon") then return item end
	return nil
end

local function modelPartCount(weapon)
	local ok, mwp = pcall(function() return weapon:getModelWeaponPart() end)
	if not ok or not mwp then return -1 end
	local ok2, size = pcall(function() return mwp:size() end)
	return ok2 and size or -1
end

register("help", "list every SimpleSuppressors debug command", function()
	local names = {}
	for name in pairs(SS._commands) do names[#names + 1] = name end
	table.sort(names)
	print("[SS] --- SimpleSuppressors debug commands ---")
	for _, name in ipairs(names) do
		print(string.format("[SS]  SS.%s  --  %s", name, SS._commands[name]))
	end
end)

register("equipped", "dump caliber + weapon-part + ModelWeaponPart-count info for the weapon in your primary hand", function()
	local weapon = heldWeapon()
	if not weapon then print("[SS] equipped: no HandWeapon in your primary hand"); return end
	print(string.format("[SS] equipped: fullType=%s caliber=%s", weapon:getFullType(), tostring(Compat.inferCaliber(weapon))))
	print(string.format("[SS] equipped: ModelWeaponPart entries on this weapon script = %d", modelPartCount(weapon)))
	local parts = weapon:getAllWeaponParts()
	local count = parts and parts:size() or 0
	print(string.format("[SS] equipped: %d attached weapon part(s)", count))
	for i = 0, count - 1 do
		local part = parts:get(i)
		print(string.format("[SS]   [%d] %s (partType=%s)", i, part:getFullType(), tostring(part:getPartType())))
	end
end)

register("caliber", "SS.caliber([fullType]) - infer caliber for the held weapon, or for a spawned throwaway instance of fullType", function(fullType)
	local weapon = fullType and instanceItem(fullType) or heldWeapon()
	if not weapon then print("[SS] caliber: nothing to inspect (not holding a weapon and no fullType given)"); return end
	print(string.format("[SS] caliber: %s -> %s", weapon:getFullType(), tostring(Compat.inferCaliber(weapon))))
end)

register("give", "SS.give(fullType, count) - spawn count (default 1) of an item straight into your inventory", function(fullType, count)
	local p = player()
	if not p or not fullType then print("[SS] give: usage SS.give(fullType, count)"); return end
	count = count or 1
	local made = 0
	for _ = 1, count do
		if p:getInventory():AddItem(fullType) then made = made + 1 end
	end
	print(string.format("[SS] give: created %d/%d x %s", made, count, fullType))
end)

register("giveOilFilters", "spawn one oil-filter suppressor for every built-in caliber", function()
    local p = player()
    if not p then print("[SS] giveOilFilters: no local player"); return end
    local made = 0
    for _, caliber in ipairs({ "12Gauge", "556", "9mm", "45ACP", "308", "3030", "357", "44" }) do
        if p:getInventory():AddItem("SimpleSuppressors.Suppressor_OilFilter_" .. caliber) then made = made + 1 end
    end
    print(string.format("[SS] giveOilFilters: created %d/8 oil-filter suppressors", made))
end)

register("heat", "print the held suppressor's current 0-100 heat value", function()
    local weapon = heldWeapon()
    local part = weapon and Compat.getAttachedSuppressor(weapon)
    if not part then print("[SS] heat: no working suppressor attached"); return end
    print(string.format("[SS] heat: %s = %.1f/100", part:getFullType(), SimpleSuppressorsEffects.getHeat(part)))
end)

register("attach", "SS.attach(partFullType) - force-attach a weapon part to the held weapon, bypassing CanAttach/tool checks (isolates mount from render)", function(partFullType)
	local weapon = heldWeapon()
	if not weapon then print("[SS] attach: no HandWeapon in your primary hand"); return end
	if not partFullType then print("[SS] attach: usage SS.attach(partFullType)"); return end
	local part = instanceItem(partFullType)
	if not part or not instanceof(part, "WeaponPart") then
		print("[SS] attach: " .. tostring(partFullType) .. " is not a WeaponPart")
		return
	end
	weapon:attachWeaponPart(player(), part)
	local now = weapon:getWeaponPart(part:getPartType())
	print(string.format("[SS] attach: partType=%s now attached=%s", tostring(part:getPartType()), tostring(now and now:getFullType())))
	print(string.format("[SS] attach: ModelWeaponPart entries on weapon script = %d (look at the weapon in-hand for the mesh itself)", modelPartCount(weapon)))
end)

register("detachAll", "clear every weapon part currently attached to the held weapon", function()
	local weapon = heldWeapon()
	if not weapon then print("[SS] detachAll: no HandWeapon in your primary hand"); return end
	weapon:clearAllWeaponParts()
	print("[SS] detachAll: cleared")
end)

register("listParts", "list every SimpleSuppressors weapon-part item type and the caliber it's registered under", function()
	print("[SS] --- PART_CALIBERS ---")
	for partType, caliber in pairs(Compat.PART_CALIBERS or {}) do
		print(string.format("[SS]  %-45s -> %s", partType, caliber))
	end
end)

register("compat", "print loaded compatibility profiles, override counts, and optional Weapon Systems bridge status", function()
	local profiles = Compat.profileReport and Compat.profileReport() or {}
	print(string.format("[SS] --- %d loaded compatibility profile(s) ---", #profiles))
	for _, profile in ipairs(profiles) do
		print(string.format("[SS]  %s (%s): %d weapon override(s), %d ammo override(s)",
			profile.id, tostring(profile.name), profile.weaponCount, profile.ammoCount))
	end
	local bridge = SimpleSuppressorsWeaponSystems
	if bridge then
		print(string.format("[SS] Weapon Systems: available=%s registered=%s (%s)",
			tostring(bridge.available), tostring(bridge.registered), tostring(bridge.detail)))
	else
		print("[SS] Weapon Systems: adapter not loaded")
	end
end)


register("listGuns", "list every ranged firearm type SimpleSuppressors has discovered on this boot", function()
	local guns = Compat.firearmTypes or {}
	print(string.format("[SS] --- %d known firearm types ---", #guns))
	for _, fullType in ipairs(guns) do print("[SS]  " .. fullType) end
end)

register("scanKnownGuns", "for every known firearm, print inferred caliber + ModelWeaponPart count on a throwaway instance -- the fast way to spot a gun that mechanically accepts a suppressor but has no visual mapping", function()
	local guns = Compat.firearmTypes or {}
	print(string.format("[SS] --- scanning %d known firearm types ---", #guns))
	for _, fullType in ipairs(guns) do
		local ok, weapon = pcall(function() return instanceItem(fullType) end)
		if ok and weapon then
			local ok2, line = pcall(function()
				return string.format("[SS]  %-40s caliber=%-8s modelWeaponPartCount=%s",
					fullType, tostring(Compat.inferCaliber(weapon)), tostring(modelPartCount(weapon)))
			end)
			if ok2 then print(line) else print(string.format("[SS]  %-40s FAILED to inspect: %s", fullType, tostring(line))) end
		else
			print(string.format("[SS]  %-40s FAILED to spawn instance", fullType))
		end
	end
end)

register("models", "inspect held item and nearby floor suppressors without changing them", function()
	local p = player()
	if not p then print("[SS] models: no player"); return end
	local function inspect(item, location)
		if not item then return end
		local ok, err = pcall(function()
			print("[SS] models " .. location .. " item=" .. item:getFullType() .. " id=" .. tostring(item:getID()))
			local function model(label, name)
				local script = name and ScriptManager.instance:getModelScript(name)
				print("[SS] " .. label .. "=" .. tostring(name) .. " resolved=" .. tostring(script ~= nil))
				if script then
					print("[SS] mesh=" .. tostring(script:getMeshName()) .. " texture=" .. tostring(script:getTextureName()) .. " shader=" .. tostring(script:getShaderName()))
				end
			end
			model("static", item:getStaticModel())
			model("world", item:getWorldStaticItem())
			print("[SS] condition=" .. tostring(item:getCondition()) .. "/" .. tostring(item:getConditionMax()))
		end)
		if not ok then print("[SS] models inspection error: " .. tostring(err)) end
	end
	inspect(p:getPrimaryHandItem(), "primary")
	inspect(p:getSecondaryHandItem(), "secondary")
	local square = p:getSquare()
	if not square then return end
	local objects = square:getWorldObjects()
	for i = 0, objects:size() - 1 do
		local item = objects:get(i):getItem()
		if item and string.find(item:getFullType(), "SimpleSuppressors.", 1, true) == 1 then inspect(item, "floor") end
	end
end)


register("verbose", "SS.verbose(true/false) - toggle SimpleSuppressors' own [INFO] diagnostic logging at runtime", function(on)
	SimpleSuppressorsDiagnostics.verbose = on == true
	print("[SS] verbose diagnostics = " .. tostring(SimpleSuppressorsDiagnostics.verbose))
end)

SimpleSuppressorsDiagnostics.info("DebugConsole.Client", "ready", "type SS.help() in the debug console")
