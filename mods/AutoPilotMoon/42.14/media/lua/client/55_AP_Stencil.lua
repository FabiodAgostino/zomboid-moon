-- AutoPilot (Moon): automations for the Moon server.

-- The stencil of the "one game action per square" automations (11/11/2026, ANALISI-WorkOrders.md 7.3): water, sow,
-- fertilize, harvest, remove stumps... are a few lines each. Stencil:define(name, spec) registers the automation and
-- writes for it everything the engine asks (start<Name>, stop<Name>, check<Name>Queue); its menu entry is data
-- (client/75_AP_JobMenu.lua, JobMenu:define):
-- - at the start: the squares where spec.hasWork is true (after the protected zones);
-- - every step on a square: protected zone -> left out (warning); nothing left to do -> done, and counted in
--   spec.counterKey only if this job acted there (else "already done by others", spec 7.4.3); spec.check may skip it
--   ("skip", warning key) or wait; a missing tool stops the job with "you need <tool>"; not enough endurance (after the
--   auto-rest) stops it with "too tired"; else the square is kept and spec.act queues the game's action, again at the
--   next step until nothing is left (at most spec.maxSteps steps on the same square, then left with a message);
-- - spec.limit: the server's limit of confirmed results per job; reached, the job ends as finished (a chain goes on).
--
-- spec (hasWork and act required):
--   hasWork(square, player, ctx) -> bool          the square has something for this job
--   act(square, player, ctx, tool) -> bool        queue the game's own action (the walk included, as the game's menu
--                                                 does); true when something was queued
--   tool(player, ctx) -> item or nil              the tool the action needs (nil = missing); omit when none
--   toolKey                                       what is missing, as a text key ("IGUI_AutoPilot_T_NeedAxe")
--   check(square, player, ctx) -> nil | "skip", warningKey | "wait"    optional extra check before acting
--   counterKey                                    confirmed results ("IGUI_AutoPilot_P_C_Watered")
--   unitKey                                       what the area tool counts ("IGUI_AutoPilot_S_Unit_Plants")
--   limit() -> number                             the server's limit of results per job (optional)
--   needsEndurance = true                         the game's endurance check before each action
--   maxSteps = 5                                  steps on the same square before it is left
--   activityKey                                   the panel's "Now:" text while acting ("IGUI_AutoPilot_P_Now_...")
--   fifo = true                                   work the squares in the given order instead of nearest first
--   parent, titleKey                              as Automation:register (phase C: the Farmer's jobs under the Farmer)
--   startSkip(square, player, ctx) -> warningKey | nil   a square left out at the start with a warning in the summary
--                                                 ("already fertilized", W-B10), counted once the job has started
--   idle(square, player, ctx) -> nil | "busy" | "wait"   first thing of every step while the character is idle: an
--                                                 automation's own business between two actions (the Gardener notes
--                                                 what its last pick-up brought); an answer is given to the engine as it is
--   toolText(player, ctx) -> text                 what is missing, already translated (instead of toolKey)
-- ctx is what the start got (a chain's ctx, or nil).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Stencil = AutoPilotMoon.Stencil or {};

local Stencil = AutoPilotMoon.Stencil;

Stencil.defaultMaxSteps = 5;
Stencil.specs = Stencil.specs or {};

AutoPilotMoon.Automation:addJobStateField("stencilActed");   -- "x,y,z" -> true: squares this job acted on
AutoPilotMoon.Automation:addJobStateField("stencilPlan");    -- what the square function of this step does
AutoPilotMoon.Automation:addJobStateField("stencilCtx");     -- the start's ctx
AutoPilotMoon.Automation:addJobStateField("stencilResults"); -- confirmed results of this job

local function squareKey(square)
	return square:getX() .. "," .. square:getY() .. "," .. square:getZ();
end

-- one step's decision (the engine's removeCheckFunction)
function AutoPilotMoon.Stencil:check(name, square, player)
	local A = AutoPilotMoon.Automation;
	local spec = Stencil.specs[name];
	local ctx = A.stencilCtx;

	A.stencilPlan = nil;

	if spec.idle
	then
		local answer = spec.idle(square, player, ctx);

		if answer ~= nil or A.job == nil
		then
			return answer or "discard";
		end
	end

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_Protected");

		return "discard";
	end

	if not spec.hasWork(square, player, ctx)
	then
		if A:getJobSet("stencilActed")[squareKey(square)]
		then
			local results = A:addJobCount("stencilResults");

			if spec.counterKey
			then
				AutoPilotMoon.Progress:count(spec.counterKey);
			end

			if spec.limit and results >= spec.limit()
			then
				A:finishDone();

				return "discard";
			end
		else
			AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_ByOthers");
		end

		return true;
	end

	if spec.check
	then
		local answer, warningKey = spec.check(square, player, ctx);

		if answer == "skip"
		then
			if warningKey
			then
				AutoPilotMoon.Progress:warn(warningKey);
			end

			return "discard";
		elseif answer == "wait"
		then
			return "wait";
		end
	end

	local tool = nil;

	if spec.tool
	then
		tool = spec.tool(player, ctx);

		if tool == nil
		then
			if spec.toolText
			then
				A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NeedTool", spec.toolText(player, ctx)));
			elseif spec.toolKey
			then
				A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NeedTool", getText(spec.toolKey)));
			else
				A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NoTools"));
			end

			return "discard";
		end
	end

	if spec.needsEndurance and not player:isEnduranceSufficientForAction()
	then
		A:finishEarly(getText("IGUI_AutoPilot_A_TooTired", A:getTitle(A.definitions[name])));

		return "discard";
	end

	A.stencilPlan = { square = square, tool = tool };

	-- kept until nothing is left to do there
	return false;
end

-- the square function: carries out the step's plan
function AutoPilotMoon.Stencil:work(name, square, player)
	local A = AutoPilotMoon.Automation;
	local spec = Stencil.specs[name];
	local plan = A.stencilPlan;

	A.stencilPlan = nil;

	if plan == nil or plan.square ~= square or AutoPilotMoon.Zones:isProtected(square, player)
	then
		return;
	end

	if spec.activityKey
	then
		AutoPilotMoon.Progress:setActivity(spec.activityKey);
	end

	if spec.act(square, player, A.stencilCtx, plan.tool)
	then
		A:getJobSet("stencilActed")[squareKey(square)] = true;
	end
end

-- Registers the automation <name> and everything the engine needs; returns the engine's definition.
function AutoPilotMoon.Stencil:define(name, spec)
	local A = AutoPilotMoon.Automation;

	Stencil.specs[name] = spec;

	local definition = A:register(name, {
		squareFilter = function(square, player)
			return spec.hasWork(square, player, nil);
		end,
		unitKey = spec.unitKey,
		limit = spec.limit,
		parent = spec.parent,
		titleKey = spec.titleKey,
	});
	local uc = definition.uc;

	A["start" .. uc] = function(player, squares, startSquare, ctx)
		local skipped = {};
		local skippedOrder = {};
		local started = A:startJob(name, player, squares, startSquare, function(list, who)
			return AutoPilotMoon.Grid:filterSquaresBy(list, function(square)
				if spec.hasWork(square, who, ctx)
				then
					return true;
				end

				local warningKey = spec.startSkip and spec.startSkip(square, who, ctx);

				if warningKey
				then
					if skipped[warningKey] == nil
					then
						skipped[warningKey] = 0;
						table.insert(skippedOrder, warningKey);
					end

					skipped[warningKey] = skipped[warningKey] + 1;
				end

				return false;
			end);
		end, { fifo = spec.fifo == true });

		if started
		then
			-- after the start: the engine resets the per-job state when it accepts the job
			A.stencilCtx = ctx;

			for i, warningKey in ipairs(skippedOrder)
			do
				AutoPilotMoon.Progress:warn(warningKey, skipped[warningKey]);
			end
		end

		return started;
	end

	A["stop" .. uc] = function(self)
		A:stopSquareProcessingQueue(definition.lockVar);
	end

	A["check" .. uc .. "Queue"] = function(self, player)
		A:checkSquareProcessingQueue({
			player = player,
			runLockVariable = definition.lockVar,
			maxStepsPerSquare = spec.maxSteps or Stencil.defaultMaxSteps,
			squareFunction = {
				fn = function(square, who)
					Stencil:work(name, square, who);
				end,
				param1 = player,
			},
			removeCheckFunction = function(square, who)
				return Stencil:check(name, square, who);
			end,
			stopFunction = function()
				A:stopSquareProcessingQueue(definition.lockVar);
			end,
		});
	end

	return definition;
end
