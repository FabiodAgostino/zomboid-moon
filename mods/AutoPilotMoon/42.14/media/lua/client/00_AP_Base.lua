-- AutoPilot (Moon): automations for the Moon server.

AutoPilotMoon = AutoPilotMoon or {};

-- the player the mod acts for: the one running the job, else the one whose menu was opened last, else player 0
-- (Moon has one local player per client; split screen works as long as one job runs at a time)
function AutoPilotMoon:getPlayer()
    local job = AutoPilotMoon.Automation.job;

    if job and job.player
    then
        return job.player;
    end

    local current = AutoPilotMoon.Event.currentPlayer;

    if current and not current:isDead()
    then
        return current;
    end

    return getPlayer();
end
