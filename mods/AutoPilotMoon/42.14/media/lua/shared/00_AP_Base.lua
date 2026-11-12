-- AutoPilot (Moon): automations for the Moon server.

-- main init (shared: loaded by clients and by the dedicated server, which runs nothing of this mod)

AutoPilotMoon = AutoPilotMoon or {};

-- messages over the head (client/02_AP_Debug.lua, spec UX-AUTOPILOT.md 4.1): one every 2 s at most, the same text not
-- again within 10 s, at most 3 waiting; the last ones kept for the panel's log
AutoPilotMoon.messageQueue = AutoPilotMoon.messageQueue or {};
AutoPilotMoon.msBetweenMessages = 2000;
AutoPilotMoon.maxQueuedMessages = 3;
AutoPilotMoon.messageRepeatMs = 10000;
AutoPilotMoon.lastMessageAt = 0;
AutoPilotMoon.recentMessages = AutoPilotMoon.recentMessages or {};
AutoPilotMoon.messageLog = AutoPilotMoon.messageLog or {};
AutoPilotMoon.maxLoggedMessages = 20;

AutoPilotMoon.Item = AutoPilotMoon.Item or {};
AutoPilotMoon.Square = AutoPilotMoon.Square or {};
AutoPilotMoon.Grid = AutoPilotMoon.Grid or {};
AutoPilotMoon.Zones = AutoPilotMoon.Zones or {};

AutoPilotMoon.Automation = AutoPilotMoon.Automation or {
    min3x3radius = 1,
    max3x3radius = 3,

    -- filled by Automation:register(), in load order
    definitions = {},
    registered = {},
    byLockVar = {},

    -- the running job (client/50_AP_Automation.lua), nil when idle
    job = nil,
};

AutoPilotMoon.Event = AutoPilotMoon.Event or {
    -- the local player whose context menu was opened last
    currentPlayer = nil,
};
