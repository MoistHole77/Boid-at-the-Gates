-- Living Front: what soldiers do while their unit is standing by.
--
-- Now and then (LF_Brain asks LF.Idle.maybeStart when a resting man is on his spot) a man picks
-- something to pass the time: sit down, sit and eat, smoke, look at a photograph from home, check
-- his rifle, catch his breath, or just look around. It lasts 10-25 s; then a pause before the
-- next. Any change - the unit standing to, an enemy in sight, a new order - stops it at once.
-- The animations are the game's own clips (AnimSets/player/actions/LF_Sit*.xml and friends).

require "TimedActions/ISBaseTimedAction"
require "LivingFront/LF_Core"

LF.Idle = LF.Idle or {}

-- anim: the looping clip; first/firstTicks: a clip played first (sitting down); gun: keep the
-- rifle in his hands (else it is put out of sight while his hands are busy).
local KINDS = {
    sit     = { weight = 30, first = "LF_SitIn", firstTicks = 70, anim = "LF_Sit", gun = true, words = "sitting down" },
    eat     = { weight = 10, first = "LF_SitIn", firstTicks = 70, anim = "LF_SitEat", words = "having something to eat" },
    smoke   = { weight = 15, anim = "LF_Smoke", words = "having a smoke" },
    photo   = { weight = 8, anim = "LF_Photo", words = "looking at a photograph from home" },
    check   = { weight = 15, anim = "LF_Reload", gun = true, ticks = 160, words = "checking his rifle" },
    breathe = { weight = 7, anim = "LF_Breathe", gun = true, ticks = 300, words = "catching his breath" },
    look    = { weight = 15, look = true, ticks = 240, words = "looking around" },
}
LF.Idle.KINDS = KINDS

LF_IdleAction = ISBaseTimedAction:derive("LF_IdleAction")

function LF_IdleAction:isValid() return not self.character:isDead() end
function LF_IdleAction:waitToStart() return false end

function LF_IdleAction:start()
    local k = KINDS[self.kind]
    if k.look then
        local a = ZombRand(360) * math.pi / 180
        self.character:faceLocation(self.character:getX() + math.cos(a) * 5, self.character:getY() + math.sin(a) * 5)
    else
        self:setActionAnim(k.first or k.anim)
        if k.first then self.switchAt = LF.tick + (k.firstTicks or 60) end
    end
    if k.gun and self.gun then
        self:setOverrideHandModels(self.gun, nil)
    else
        self:setOverrideHandModels(nil, nil)
    end
end

function LF_IdleAction:update()
    if self.switchAt and LF.tick >= self.switchAt then
        self.switchAt = nil
        self:setActionAnim(KINDS[self.kind].anim)
    end
    -- Anything else to do: stop at once.
    if self.keep and LF.tick % 10 == 0 and not self.keep(self.character) then self:forceStop() end
end

function LF_IdleAction:stop() ISBaseTimedAction.stop(self) end
function LF_IdleAction:perform() ISBaseTimedAction.perform(self) end

function LF_IdleAction:new(character, kind, ticks, gun, keep)
    local o = ISBaseTimedAction.new(self, character)
    o.kind, o.gun, o.keep = kind, gun, keep
    o.maxTime = ticks
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.ignoreHandsWounds = true
    return o
end

local function pick()
    local total = 0
    for _, k in pairs(KINDS) do total = total + k.weight end
    local r = ZombRand(total)
    for name, k in pairs(KINDS) do
        r = r - k.weight
        if r < 0 then return name, k end
    end
    return "look", KINDS.look
end

-- A resting soldier on his spot: maybe start something. m is his mind (LF_Brain); keep(body) is
-- asked every few ticks and stops the activity when it returns false. Returns the words for
-- what he is doing, or nil.
function LF.Idle.maybeStart(body, m, gun, keep)
    if body:isPerformingAnAction() then return nil end
    if LF.tick < (m.nextIdle or 0) then return nil end
    if not m.nextIdle then
        -- First time: a short random wait so a unit doesn't all sit down at once.
        m.nextIdle = LF.tick + 120 + ZombRand(600)
        return nil
    end
    if LF.Posture and LF.Posture.crouched(body) then LF.Posture.set(body, false) end
    local name, k = pick()
    local ticks = k.ticks or (600 + ZombRand(900))       -- 10-25 s
    ISTimedActionQueue.add(LF_IdleAction:new(body, name, ticks, gun, keep))
    m.nextIdle = LF.tick + ticks + 300 + ZombRand(900)   -- then 5-20 s before the next
    return k.words
end
