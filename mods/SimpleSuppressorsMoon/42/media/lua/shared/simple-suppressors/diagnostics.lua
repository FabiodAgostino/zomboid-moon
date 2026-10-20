if SimpleSuppressorsDiagnosticsLoaded then return end
SimpleSuppressorsDiagnosticsLoaded = true
SimpleSuppressorsDiagnostics = SimpleSuppressorsDiagnostics or {}

local Diagnostics = SimpleSuppressorsDiagnostics
Diagnostics.loadedSystems = Diagnostics.loadedSystems or {}
-- info() stays silent unless verbose diagnostics are enabled (SimpleSuppressors.Debug
-- sandbox option). loaded()/failure()/guard() always report.
Diagnostics.verbose = Diagnostics.verbose or false

local function write(level, system, event, detail)
	print(string.format("[SimpleSuppressors][%s][%s][%s] %s", level, tostring(system), tostring(event), tostring(detail or "")))
end

function Diagnostics.loaded(system)
	if Diagnostics.loadedSystems[system] then return end
	Diagnostics.loadedSystems[system] = true
	write("LOAD", system, "ready", "")
end

function Diagnostics.info(system, event, detail)
	if not Diagnostics.verbose then return end
	write("INFO", system, event, detail)
end

function Diagnostics.failure(system, event, detail)
	write("ERROR", system, event, detail)
end

-- [moon] suppressoreffects.lua calls warn() when the native muzzle flash cannot be hidden or restored, but the
-- function did not exist: the warning itself became an error, on every shot (likely the 5.56 reports). It now
-- writes each distinct warning once per session.
local warned = {}
function Diagnostics.warn(system, event, detail)
	local key = tostring(system) .. "|" .. tostring(event) .. "|" .. tostring(detail)
	if warned[key] then return end
	warned[key] = true
	write("WARN", system, event, detail)
end

-- [moon] The original re-raised every error. On Hook.Attack that could also stop what runs after this handler, and
-- on OnPlayerUpdate it repeated on every frame, each time with a whole stack trace in the game's log. Now an error is written once per distinct message and the handler rests for 10 seconds,
-- so a broken feature turns itself off quietly instead of taking the shot or the frame rate with it.
local PAUSE_MS = 10000
function Diagnostics.guard(system, event, callback)
	local seen, pausedUntil = {}, 0
	return function(...)
		if pausedUntil > 0 and getTimestampMs() < pausedUntil then return end
		local ok, result = pcall(callback, ...)
		if ok then return result end
		pausedUntil = getTimestampMs() + PAUSE_MS
		local message = tostring(result)
		seen[message] = (seen[message] or 0) + 1
		if seen[message] == 1 then
			Diagnostics.failure(system, event, message)
		end
	end
end

-- Sandbox vars are not populated when this shared file first loads, so read the
-- Debug switch defensively now and again once the game/session is ready.
local function refreshVerbose()
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	Diagnostics.verbose = (vars and vars.Debug == true) or false
end
refreshVerbose()
Events.OnGameStart.Add(refreshVerbose)

Diagnostics.loaded("Diagnostics.Shared")
