-- Living Front: what soldiers do while their unit is standing by.
--
-- A resting man (LF_Brain calls LF.Idle.tick while he is standing by on his spot) settles into a
-- rest: 80% of the time he sits down on the ground for 3-6 minutes, otherwise he stands easy for
-- 1-2.5 minutes; then another. Mostly he does nothing. Every 1-2.5 minutes he does something for
-- 20-60 s - sitting: eats, dozes, works on his kit, warms or rubs his hands, goes through his
-- gear; standing: smokes, looks at a photograph from home, checks his rifle, looks around. If it
-- needs his hands, he slings his rifle on his back first and takes it back afterwards.
--
-- Where there is something to sit on - a chair or a couch in the house his unit holds, a bench in
-- a park - he takes it (the game's own sit-on-furniture: he walks to it, sits, and gets up again
-- the same way as the player), within a few tiles of his place; each seat one man.
-- Sitting is the game's own: the "sit on ground" event puts him in the game's sitting state
-- (the whole body, rifle across his lap) and "forceGetUp" stands him up with the game's clip.
-- (Up to 0.26.0 the sitting was a clip of ours played as an action - but actions only drive the
-- upper body, so the men stood with their arms in a sitting pose.) The activities are action
-- clips (AnimSets/player/actions/LF_Sit*.xml, LF_Smoke, LF_Photo...) over the sitting or standing
-- legs.

require "TimedActions/ISBaseTimedAction"
require "LivingFront/Core/LF_Core"
require "LivingFront/Soldier/LF_Aid"

LF.Idle = LF.Idle or {}

local CFG = {
    sitChance = 80,                          -- % of rests spent sitting down
    sitTicks = { 10800, 10800 },             -- sitting: 3 min + up to 3 min more
    standTicks = { 3600, 5400 },             -- standing: 1 min + up to 1.5 min more
    gapTicks = { 3600, 5400 },               -- between activities: 1 min + up to 1.5 min more
    actTicks = { 1200, 2400 },               -- an activity: 20 s + up to 40 s more
    sitFailTicks = 180,                      -- not down after ~3 s: the game wouldn't sit him; stand instead
    seatRange = 5,                           -- a seat this close to his place
    seatFailTicks = 900,                     -- not sitting on it after ~15 s: the ground instead
}
LF.Idle.CFG = CFG

-- anim: the clip; gun: he keeps the rifle in his hands (else he slings it first); ticks: a fixed
-- length instead of CFG.actTicks; look: no clip, he just turns and looks somewhere.
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

-- ---- one activity -------------------------------------------------------------------------------

LF_IdleAction = ISBaseTimedAction:derive("LF_IdleAction")

function LF_IdleAction:isValid() return not self.character:isDead() end
function LF_IdleAction:waitToStart() return false end

function LF_IdleAction:start()
    if not self.kind.gun and LF.Combat then self.slung = LF.Combat.sling(self.character) end
    self:setActionAnim(self.kind.anim)
    if self.kind.bandageType then self:setAnimVariable("BandageType", self.kind.bandageType) end
end

function LF_IdleAction:update()
    if self.keep and LF.tick % 10 == 0 and not self.keep(self.character) then self:forceStop() end
end

local function rearm(self)
    if self.slung and LF.Combat then
        self.slung = nil
        LF.Combat.unsling(self.character)
    end
end

function LF_IdleAction:stop()
    rearm(self)
    ISBaseTimedAction.stop(self)
end

function LF_IdleAction:perform()
    rearm(self)
    ISBaseTimedAction.perform(self)
end

function LF_IdleAction:new(character, kind, ticks, keep)
    local o = ISBaseTimedAction.new(self, character)
    o.kind, o.keep = kind, keep
    o.maxTime = ticks
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.ignoreHandsWounds = true
    return o
end

-- ---- sitting down and getting up -----------------------------------------------------------------

function LF.Idle.onFurniture(body)
    local ok, s = pcall(function() return body:isSittingOnFurniture() end)
    return ok and s or false
end

function LF.Idle.isSitting(body)
    local ok, s = pcall(function() return body:isSitOnGround() end)
    return (ok and s) or LF.Idle.onFurniture(body)
end

-- ---- seats ------------------------------------------------------------------------------------

local seatOf = {}           -- seat object -> body using it (runtime)

local function hasSeat(obj)
    local ok, n = pcall(function() return SeatingManager.getInstance():getTilePositionCount(obj) end)
    return ok and n and n > 0
end

local function buildingIdOf(sq)
    local b = sq and sq:getBuilding()
    return b and b:getID() or nil
end

-- The nearest free seat within range of his place (same building, or both out of doors).
local function findSeat(body, range)
    if not SeatingManager then return nil end
    local cell = getCell()
    local bx, by, bz = math.floor(body:getX()), math.floor(body:getY()), math.floor(body:getZ())
    local here = buildingIdOf(body:getCurrentSquare())
    local best, bd = nil, math.huge
    for x = bx - range, bx + range do
        for y = by - range, by + range do
            local sq = cell:getGridSquare(x, y, bz)
            if sq and buildingIdOf(sq) == here then
                local objs = sq:getObjects()
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    local user = seatOf[o]
                    if user and (user:isDead() or not LF.Idle.onFurniture(user) and not user:getModData().LF_seatGoing) then
                        seatOf[o], user = nil, nil
                    end
                    if not user and hasSeat(o) then
                        local free = true
                        pcall(function() free = not o:isFurnitureOccupied(body) end)
                        local d = LF.dist(body:getX(), body:getY(), x + 0.5, y + 0.5)
                        if free and d < bd then best, bd = o, d end
                    end
                end
            end
        end
    end
    return best
end

local function seatPathFound(body, action)
    local seat = action.goalFurnitureObject
    local after = ISRestAction:new(body, seat, true)
    if action:addAfter(after) == nil then ISTimedActionQueue.add(after) end
end

local function seatPathFailed(body, seat)
    body:getModData().LF_seatGoing = nil
    if seatOf[seat] == body then seatOf[seat] = nil end
end

-- Walk to the seat and sit on it. True if he set off.
local function takeSeat(body, seat)
    if not (ISPathFindAction and ISPathFindAction.pathToSitOnFurniture and ISRestAction) then return false end
    local ok = pcall(function()
        local action = ISPathFindAction:pathToSitOnFurniture(body, seat, true)
        action:setOnComplete(seatPathFound, body, action)
        action:setOnFail(seatPathFailed, body, seat)
        ISTimedActionQueue.add(action)
    end)
    if not ok then return false end
    seatOf[seat] = body
    body:getModData().LF_seatGoing = true
    return true
end

local function leaveSeat(body)
    body:getModData().LF_seatGoing = nil
    for o, b in pairs(seatOf) do if b == body then seatOf[o] = nil end end
end

local function sitDown(body)
    if LF.Posture and LF.Posture.crouched(body) then LF.Posture.set(body, false) end
    body:reportEvent("EventSitOnGround")
end

-- Get up (the game's stand-up clip). True if he was sitting.
function LF.Idle.standUp(body)
    leaveSeat(body)
    if not LF.Idle.isSitting(body) then return false end
    body:setVariable("forceGetUp", true)
    return true
end

-- End his rest: stop any activity, get up, rifle back in his hands.
function LF.Idle.stop(body, m)
    local q = ISTimedActionQueue.getTimedActionQueue(body)
    local a = q and q.queue and q.queue[1]
    if a and (a.Type == "LF_IdleAction" or a.Type == "ISPathFindAction" or a.Type == "ISRestAction") then ISTimedActionQueue.clear(body) end
    LF.Idle.standUp(body)
    if LF.Combat and LF.Combat.slungGun(body) then LF.Combat.unsling(body) end
    if m then m.rest = nil end
end

-- ---- the rest itself --------------------------------------------------------------------------

-- A standing-by soldier on his spot, not moving: carry his rest on. m is his mind (LF_Brain);
-- keep(body) is asked every few ticks during an activity and stops it when it returns false.
-- What he is doing goes into m.detail for the inspect window.
function LF.Idle.tick(body, m, keep)
    local now = LF.tick
    local R = m.rest
    if not R then
        if not m.nextIdle then
            -- First time: a short random wait so a unit doesn't all sit down at once.
            m.nextIdle = now + 120 + ZombRand(600)
            return
        end
        if now < m.nextIdle or body:isPerformingAnAction() then return end
        local seated = ZombRand(100) < CFG.sitChance
        R = { seated = seated, start = now, endAt = now + (seated and rnd(CFG.sitTicks) or rnd(CFG.standTicks)),
              nextAct = now + math.floor(rnd(CFG.gapTicks) / 2) }
        m.rest = R
        if seated then
            -- Something to sit on nearby: that, rather than the floor.
            local seat = LF.guard("find seat", findSeat, body, CFG.seatRange)
            if seat and LF.guard("take seat", takeSeat, body, seat) then
                R.seat = true
                R.nextAct = math.max(R.nextAct, now + 600)
                m.detail = "going to sit down"
                return
            end
            LF.guard("sit down", sitDown, body)
        end
        m.detail = seated and "sitting down" or "standing easy"
        return
    end
    -- A seat he couldn't get to: the ground instead.
    if R.seat and not body:getModData().LF_seatGoing and not LF.Idle.onFurniture(body) and not body:isPerformingAnAction() then
        R.seat = nil
        LF.guard("sit down", sitDown, body)
        R.start = now
    end
    if R.seat and now - R.start > CFG.seatFailTicks and not LF.Idle.onFurniture(body) then
        R.seat = nil
        LF.Idle.stop(body, nil)
        LF.guard("sit down", sitDown, body)
        R.start = now
    end
    -- The game wouldn't sit him down (on stairs, mid-turn...): he stands easy instead.
    if R.seated and not R.seat and now - R.start > CFG.sitFailTicks and not LF.Idle.isSitting(body) then R.seated = false end
    if now >= R.endAt then
        if not body:isPerformingAnAction() then
            LF.Idle.stop(body, m)
            m.nextIdle = now + 120 + ZombRand(240)
        end
        return
    end
    if body:isPerformingAnAction() then return end
    m.detail = R.seated and "sitting down, resting" or "standing easy"
    if now < R.nextAct then return end
    local k = pick(R.seated and SITTING or STANDING)
    local len = k.ticks or rnd(CFG.actTicks)
    if k.look then
        local a = ZombRand(360) * math.pi / 180
        body:faceLocation(body:getX() + math.cos(a) * 5, body:getY() + math.sin(a) * 5)
    else
        ISTimedActionQueue.add(LF_IdleAction:new(body, k, len, keep))
    end
    m.detail = k.words
    R.nextAct = now + len + rnd(CFG.gapTicks)
end

-- ---- the wounded, out of the fight -----------------------------------------------------------
--
-- A wounded man who has got to safety (a hiding spot, or his squad's rear - LF_Brain; a man the
-- medic stabilised - LF_Medic) sits down and tends his wounds: dresses any that still bleed, goes
-- over his worst one again (the game's bandaging clips), holds it, rests with his head down, now
-- and then looks up. Every 5-15 s something, mostly small.

local NURSE = {
    { weight = 35, tend = true, words = "seeing to his wounds" },
    { weight = 20, anim = "LF_SitRub", ticks = 600, words = "nursing his wounds" },
    { weight = 20, anim = "LF_SitDoze", gun = true, ticks = 900, words = "resting, head down" },
    { weight = 10, anim = "LF_SitKit", gun = true, ticks = 600, words = "going through his kit" },
    { weight = 15, look = true, ticks = 300, words = "watching" },
}

function LF.Idle.nurse(body, m)
    if body:isPerformingAnAction() then return end
    local now = LF.tick
    local R = m.rest
    if not R or not R.nurse then
        R = { nurse = true, seated = true, start = now, nextAct = now + 90 }
        m.rest = R
        if not LF.Idle.isSitting(body) then LF.guard("sit down", sitDown, body) end
        m.detail = "sitting down, wounded"
        return
    end
    -- Still bleeding: that first.
    local bleed = LF.Aid and LF.Aid.bleedingPart(body)
    if bleed then
        ISTimedActionQueue.add(LF_AidAction:new(body, bleed))
        m.detail = "dressing a wound"
        return
    end
    if not LF.Idle.isSitting(body) and now - R.start > 180 and not R.sitAgain then
        R.sitAgain = true
        LF.guard("sit down", sitDown, body)
    end
    if now < R.nextAct then return end
    local k = pick(NURSE)
    local len = k.ticks or 240
    if k.tend then
        local part = LF.Aid and LF.Aid.worstPart(body)
        if part then
            ISTimedActionQueue.add(LF_IdleAction:new(body, { anim = "Bandage", bandageType = LF.Aid.bandageTypeOf(part),
                words = k.words }, len))
        end
    elseif k.look then
        local a = ZombRand(360) * math.pi / 180
        body:faceLocation(body:getX() + math.cos(a) * 5, body:getY() + math.sin(a) * 5)
    else
        ISTimedActionQueue.add(LF_IdleAction:new(body, k, len))
    end
    m.detail = k.words
    R.nextAct = now + len + 300 + ZombRand(600)
end
