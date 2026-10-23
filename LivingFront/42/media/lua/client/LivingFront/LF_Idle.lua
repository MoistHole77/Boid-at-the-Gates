-- Living Front: what soldiers do while their unit is standing by.
--
-- A resting man (LF_Brain asks LF.Idle.maybeStart when he is on his spot) settles into a rest
-- session: 80% of the time he sits down on the ground (3-6 minutes), otherwise he stands
-- (1-2.5 minutes). Mostly he does nothing. Every 1-2.5 minutes he does something for 20-60 s
-- - sitting: eats, dozes, works on his kit, warms or rubs his hands, goes through his gear;
-- standing: smokes, looks at a photograph from home, checks his rifle, looks around - then goes
-- back to doing nothing. When the session ends, or he is wanted (the unit stands to, an enemy
-- shows, an order comes), a sitting man gets up (the game's stand-up clip, ~1 s) first.
--
-- The clips are the game's own (AnimSets/player/actions/LF_Sit*.xml and friends). The sitting
-- nodes switch off the engine's root-motion extraction (an empty DeferredBoneName, as the
-- game's own sit nodes do): without that the drop of the hips is taken out of the pose as if it
-- were walking, and the man never gets down - which is why sitting did nothing in 0.25.0.

require "TimedActions/ISBaseTimedAction"
require "LivingFront/LF_Core"

LF.Idle = LF.Idle or {}

local CFG = {
    sitChance = 80,                          -- % of rest sessions spent sitting down
    sitTicks = { 10800, 10800 },             -- sitting: 3 min + up to 3 min more
    standTicks = { 3600, 5400 },             -- standing: 1 min + up to 1.5 min more
    gapTicks = { 3600, 5400 },               -- between activities: 1 min + up to 1.5 min more
    actTicks = { 1200, 2400 },               -- an activity: 20 s + up to 40 s more
    sitDownTicks = 70,                       -- the sit-down clip
    getUpTicks = 55,                         -- the stand-up clip
}
LF.Idle.CFG = CFG

-- What he does now and then. anim: the clip; gun: rifle stays in his hands (else it's put away
-- while his hands are busy); ticks: a fixed length instead of CFG.actTicks.
local SITTING = {
    { weight = 20, anim = "LF_SitEat", words = "having something to eat" },
    { weight = 20, anim = "LF_SitDoze", gun = true, words = "dozing" },
    { weight = 20, anim = "LF_SitWork", words = "working on his kit" },
    { weight = 15, anim = "LF_SitKit", gun = true, words = "going through his gear" },
    { weight = 15, anim = "LF_SitWarm", words = "warming his hands" },
    { weight = 10, anim = "LF_SitRub", words = "rubbing his hands" },
}
local STANDING = {
    { weight = 30, anim = "LF_Smoke", words = "having a smoke" },
    { weight = 15, anim = "LF_Photo", words = "looking at a photograph from home" },
    { weight = 25, anim = "LF_Reload", gun = true, ticks = 180, words = "checking his rifle" },
    { weight = 10, anim = "LF_Breathe", gun = true, ticks = 400, words = "catching his breath" },
    { weight = 20, look = true, ticks = 480, words = "looking around" },
}

local function rnd(r) return r[1] + ZombRand(r[2]) end

local function pick(list)
    local total = 0
    for _, k in ipairs(list) do total = total + k.weight end
    local r = ZombRand(total)
    for _, k in ipairs(list) do
        r = r - k.weight
        if r < 0 then return k end
    end
    return list[1]
end

LF_IdleAction = ISBaseTimedAction:derive("LF_IdleAction")

function LF_IdleAction:isValid() return not self.character:isDead() end
function LF_IdleAction:waitToStart() return false end

function LF_IdleAction:hands(gun)
    if gun and self.gun then self:setOverrideHandModels(self.gun, nil) else self:setOverrideHandModels(nil, nil) end
end

function LF_IdleAction:say(words)
    if self.onWords then self.onWords(words) end
end

-- Back to doing nothing (sitting or standing).
function LF_IdleAction:rest()
    self.act = nil
    if self.seated then self:setActionAnim("LF_Sit") else self:setActionAnim("LF_StandEasy") end
    self:hands(true)
    self:say(self.seated and "sitting down, resting" or "standing easy")
    self.nextAct = LF.tick + rnd(CFG.gapTicks)
end

function LF_IdleAction:start()
    local now = LF.tick
    self.endAt = now + self.length
    if self.seated then
        self:setActionAnim("LF_SitIn")
        self:hands(true)
        self.sitAt = now + CFG.sitDownTicks
        self:say("sitting down")
    else
        self:rest()
    end
    -- The first activity comes a little sooner than the rest.
    self.nextAct = now + math.floor(rnd(CFG.gapTicks) / 2)
end

function LF_IdleAction:getUp()
    if self.leaveAt then return end
    if self.seated then
        self:setActionAnim("LF_SitOut")
        self:hands(true)
        self.leaveAt = LF.tick + CFG.getUpTicks
    else
        self.leaveAt = LF.tick
    end
end

function LF_IdleAction:update()
    local now = LF.tick
    if self.leaveAt then
        if now >= self.leaveAt then self:forceStop() end
        return
    end
    -- Wanted (or the session is over): get up and go.
    if now >= self.endAt or (self.keep and now % 10 == 0 and not self.keep(self.character)) then
        self:getUp()
        return
    end
    if self.sitAt then
        if now >= self.sitAt then self.sitAt = nil; self:rest() end
        return
    end
    if self.act then
        if now >= self.actEnd then self:rest() end
        return
    end
    if now >= self.nextAct then
        local k = pick(self.seated and SITTING or STANDING)
        self.act, self.actEnd = k, now + (k.ticks or rnd(CFG.actTicks))
        if k.look then
            local a = ZombRand(360) * math.pi / 180
            local c = self.character
            c:faceLocation(c:getX() + math.cos(a) * 5, c:getY() + math.sin(a) * 5)
        else
            self:setActionAnim(k.anim)
            self:hands(k.gun)
        end
        self:say(k.words)
    end
end

function LF_IdleAction:stop() ISBaseTimedAction.stop(self) end
function LF_IdleAction:perform() ISBaseTimedAction.perform(self) end

function LF_IdleAction:new(character, seated, length, gun, keep, onWords)
    local o = ISBaseTimedAction.new(self, character)
    o.seated, o.length, o.gun, o.keep, o.onWords = seated, length, gun, keep, onWords
    o.maxTime = length + CFG.getUpTicks + 600      -- (it ends itself; this is only a backstop)
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.ignoreHandsWounds = true
    return o
end

-- A resting soldier on his spot: maybe start a rest session. m is his mind (LF_Brain); keep(body)
-- is asked every few ticks and ends the session (he gets up) when it returns false. What he is
-- doing goes into m.detail for the inspect window.
function LF.Idle.maybeStart(body, m, gun, keep)
    if body:isPerformingAnAction() then return nil end
    if not m.nextIdle then
        -- First time: a short random wait so a unit doesn't all sit down at once.
        m.nextIdle = LF.tick + 120 + ZombRand(600)
        return nil
    end
    if LF.tick < m.nextIdle then return nil end
    if LF.Posture and LF.Posture.crouched(body) then LF.Posture.set(body, false) end
    local seated = ZombRand(100) < CFG.sitChance
    local length = seated and rnd(CFG.sitTicks) or rnd(CFG.standTicks)
    ISTimedActionQueue.add(LF_IdleAction:new(body, seated, length, gun, keep, function(words) m.detail = words end))
    m.nextIdle = LF.tick + 120 + ZombRand(240)     -- after it: a few seconds, then the next
    return seated and "sitting down" or "standing easy"
end
