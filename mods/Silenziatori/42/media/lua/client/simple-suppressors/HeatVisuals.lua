require "simple-suppressors/compatibility"
require "simple-suppressors/suppressoreffects"
if SimpleSuppressorsHeatVisualsLoaded then return end
SimpleSuppressorsHeatVisualsLoaded = true

-- Smoke uses depth-tested drifting particles. Incandescence uses the actual
-- animated weapon-part mesh through a private per-weapon render mapping.
local HeatModels = require "simple-suppressors/HeatModels"
local MountedVisualMetrics = require "simple-suppressors/MountedVisualMetrics"
local active, particles = {}, {}
local smokeTexture
local lastTime

local function enabled()
    return not SandboxVars or not SandboxVars.SimpleSuppressors
        or SandboxVars.SimpleSuppressors.EnableSuppressorHeat ~= false
end

local function anchor(state, fraction)
	local owner, weapon = state.owner, state.weapon
	if owner:isDead() or owner:getPrimaryHandItem() ~= weapon
		or SimpleSuppressorsCompatibility.getAttachedSuppressor(weapon) ~= state.part then return nil end
    if not owner:isAiming() or not state.forward then return nil end
    local direction = owner:getForwardDirection()
    local dx, dy = direction:getX(), direction:getY()
    local distance = state.forward + state.length * fraction
    return owner:getX() + dx * distance, owner:getY() + dy * distance,
        owner:getZ() + state.height, dx, dy
end

local function stageFor(heat)
    return heat < 40 and 0 or math.min(6, 1 + math.floor((heat - 40) / 10))
end

-- A number of firearm systems replace a weapon's private render list while
-- cycling, chambering, or updating animated parts. Recheck from every client
-- phase that can occur around that update so sustained heat remains steady
-- instead of blinking back to the cold mesh between shots.
-- [moon] A weapon type that cannot glow (no render mapping for the mounted suppressor) is left cold for the whole
-- session: one line in the log, no more tries. A single weapon whose render list was changed by something else is
-- left cold only while it stays hot. An unexpected error is tried again every 30 seconds, and after three errors the
-- pair stops trying: each error caught by pcall still costs a whole stack trace in the game's log. The pair's errors
-- are counted here and not on the state, which is made anew every time the suppressor heats up again.
local noGlow = {} -- "weapon type|suppressor type" that cannot glow, for the whole session
local glowErrors = {} -- "weapon type|suppressor type" -> { count, nextAttempt }
local MAX_GLOW_ERRORS = 3
local function applyHeatModel(state, now)
    if state.glowUnavailable then return end
    local key = state.glowKey
    if noGlow[key] then
        -- another weapon of the same pair found out: this one may be glowing, put its cold list back
        HeatModels.restore(state)
        state.glowUnavailable = true
        return
    end
    local errors = glowErrors[key]
    if errors and now < errors.nextAttempt then return end
    local ok, applied, why, onlyThisWeapon = pcall(HeatModels.apply, state, stageFor(state.heat))
    if ok and applied then
        glowErrors[key] = nil
        return
    end
    HeatModels.restore(state)
    if ok then
        state.glowUnavailable = true
        if not onlyThisWeapon then noGlow[key] = true end
        print("[SimpleSuppressors][HeatVisuals] No surface glow on " .. key .. ": " .. tostring(why))
        return
    end
    errors = errors or { count = 0 }
    errors.count, errors.nextAttempt = errors.count + 1, now + 30000
    glowErrors[key] = errors
    if errors.count >= MAX_GLOW_ERRORS then
        noGlow[key], state.glowUnavailable = true, true
        print("[SimpleSuppressors][HeatVisuals] Surface glow off for " .. key .. " after " .. errors.count
            .. " errors: " .. tostring(applied))
    elseif errors.count == 1 then
        print("[SimpleSuppressors][HeatVisuals] Surface glow error on " .. key .. ", trying again in 30 s: "
            .. tostring(applied))
    end
end

local function onShot(owner, weapon)
    if not enabled() or not owner or not weapon or not weapon:isRanged()
        or owner:getPrimaryHandItem() ~= weapon then return end
	local part = SimpleSuppressorsCompatibility.getAttachedSuppressor(weapon)
    if not part or part:getCondition() <= 0 then return end
    local fullType = part:getFullType()
    local caliber = SimpleSuppressorsCompatibility.PART_CALIBERS[fullType]
    if not caliber or not SimpleSuppressorsCompatibility.isCaliberEnabled(caliber) then return end
    local state = active[part]
    if not state then
        local model = ScriptManager.instance:getModelScript(weapon:getStaticModel())
        local socket = model and (model:getAttachmentById("canon") or model:getAttachmentById("suppressor"))
        local offset = socket and socket:getOffset()
		local length = MountedVisualMetrics.lengthFor(weapon, caliber,
			SimpleSuppressorsCompatibility.isOilFilterSuppressor(part))
		if not length then return end
        state = { owner = owner, weapon = weapon, part = part, heat = 0,
            forward = offset and math.abs(offset:y()) + 0.35, height = offset and offset:z() + 0.5,
            length = length, emission = 0,
            glowKey = tostring(weapon:getFullType()) .. "|" .. tostring(fullType) } -- [moon] once, not every frame
        active[part] = state
    end
    -- Heat is persisted by the shared firing hook.  The renderer only reads
    -- it, so the tooltip, smoke, and glowing mesh cannot disagree.
    state.heat = SimpleSuppressorsEffects.getHeat(part)
    -- Apply here as well as on frame updates. This closes the gap between a
    -- firearm's shot callback and its next animation/reconciliation frame.
    applyHeatModel(state, getTimestampMs())
end

-- OnWeaponSwingHitPoint belongs to the reload action and can be replaced by
-- firearm-framework mods.  Hook.Attack is the common shot path already used
-- to store heat, so also create the visual state from that hook.  The hit-point
-- listener remains as a harmless fallback; both callbacks only refresh state.
local function attackContext(...)
    local owner, weapon
    for index = 1, select("#", ...) do
        local candidate = select(index, ...)
        local weaponOk, isWeapon = pcall(function()
            return candidate and instanceof(candidate, "HandWeapon") and candidate:isRanged()
        end)
        if weaponOk and isWeapon then
            weapon = candidate
        else
            local playerOk, isPlayer = pcall(function() return candidate and instanceof(candidate, "IsoPlayer") end)
            if playerOk and isPlayer then owner = candidate end
        end
    end
    return owner, weapon
end

if Hook and Hook.Attack then
    Hook.Attack.Add(function(...)
        local owner, weapon = attackContext(...)
        if owner and weapon then onShot(owner, weapon) end
    end)
end

local function tick()
    local now = getTimestampMs()
    local dt = lastTime and math.min(0.1, math.max(0, (now - lastTime) / 1000)) or 0
    lastTime = now
    if not enabled() then
        for _, state in pairs(active) do HeatModels.restore(state) end
        active, particles = {}, {}
        return
    end
    if isGamePaused() then return end
    for part, state in pairs(active) do
        state.heat = SimpleSuppressorsEffects.getHeat(part)
        if state.heat == 0 or state.owner:isDead()
            or state.owner:getPrimaryHandItem() ~= state.weapon
			or SimpleSuppressorsCompatibility.getAttachedSuppressor(state.weapon) ~= part then
            HeatModels.restore(state)
            active[part] = nil
        else
            -- The first surface glow arrives after ten shots. It is then
            -- continuously reconciled while the suppressor stays hot.
            applyHeatModel(state, now)
            state.emission = state.emission + dt
            if state.heat >= 35 and state.emission >= 0.12 then
                state.emission = 0
                local x, y, z, dx, dy = anchor(state, 1)
                if x and #particles < 128 then
                    particles[#particles + 1] = { x = x, y = y, z = z,
                        vx = dx * 0.025 + (ZombRand(101) - 50) * 0.0008,
                        vy = dy * 0.025 + (ZombRand(101) - 50) * 0.0008,
                        age = 0, life = 1.5 + ZombRand(101) * 0.01,
                        strength = state.heat / 100 }
                end
            end
        end
    end
    for i = #particles, 1, -1 do
        local p = particles[i]
        p.age = p.age + dt
        if p.age >= p.life then
            particles[i] = particles[#particles]
            particles[#particles] = nil
        else
            p.x, p.y, p.z = p.x + p.vx * dt, p.y + p.vy * dt, p.z + dt * 0.07
        end
    end
end

local function draw(texture, size, alpha, x, y, z, r, g, b)
    IsoSprite.renderTextureWithDepth(texture, size, size, r, g, b, alpha,
        x, y, z - size * 0.5 / (96 * Core.getTileScale()))
end

local function render()
    if not enabled() then return end
    if not smokeTexture then smokeTexture = getTexture("media/textures/SS_HeatSmoke.png") end
    if not smokeTexture then return end
    for _, p in ipairs(particles) do
        local t = p.age / p.life
        local alpha = math.sin(t * math.pi) * p.strength * 0.28
        draw(smokeTexture, (9 + t * 23) * Core.getTileScale(), alpha, p.x, p.y, p.z, 0.7, 0.72, 0.74)
    end
    -- Keep the next render frame hot if an animated firearm refreshed its list
    -- after OnTick. `HeatModels.apply` is a no-op when the current hot list is
    -- still installed, so this only performs work after a real replacement.
    local now = getTimestampMs()
    for _, state in pairs(active) do
        state.heat = SimpleSuppressorsEffects.getHeat(state.part)
        if state.heat > 0 then applyHeatModel(state, now) end
    end
end

Events.OnWeaponSwingHitPoint.Add(onShot)
Events.OnTick.Add(tick)
Events.OnPlayerUpdate.Add(function(player)
    local now = getTimestampMs()
    for _, state in pairs(active) do
        if state.owner == player then
            state.heat = SimpleSuppressorsEffects.getHeat(state.part)
            if state.heat > 0 then applyHeatModel(state, now) end
        end
    end
end)
Events.OnPostRender.Add(render)
Events.OnGameStart.Add(function()
    for _, state in pairs(active) do HeatModels.restore(state) end
    active, particles, lastTime = {}, {}, nil
end)
