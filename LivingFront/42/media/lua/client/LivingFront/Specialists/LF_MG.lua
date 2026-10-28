-- Living Front: machine guns - the gun teams of a machine-gun squad.
--
-- A machine-gun squad is a sergeant, two gun teams (Gun 1 in the alpha slot, Gun 2 in the bravo
-- slot) and the squad medic. A gun team is four men:
--   gunner    - fires the gun (MG34 for the Germans, DP-27 for the Soviets) and nothing else
--   assistant - its corporal: down beside the gun, feeds the belts (pans), changes the barrel
--   two men   - security and spare ammunition, with rifles; the next in line to crew the gun
-- With no rifle team, the squad never flanks: it is a base of fire. In a platoon the lieutenant
-- gives it the supporting task - the guns keep the enemy's heads down while a rifle squad goes in.
--
-- The gun:
--   * It can't be fired on the move. Where the gunner stops he sets it up first (~2.5 s); when he
--     moves it is no longer set up.
--   * It fires at its real rate (MG34 900 rounds a minute, DP-27 550) in bursts of about four
--     seconds, then pauses while he relays it. Each round is resolved: an aimed one may hit the
--     man he's firing at, and every round lands somewhere in the beaten zone around the aim
--     point - anyone hostile there may be hit, and everyone near it is suppressed (pinned, as a
--     rule). At a point (where the enemy was last seen) it is area fire - the beaten zone only.
--   * Belts run out (250 rounds; the DP-27's pan holds 47): the assistant feeds a new one. The
--     MG34's barrel needs changing after ~250 rounds of hard firing; the DP-27 has no quick-change
--     barrel, so it has to be rested to cool. Without his assistant the gunner does it himself,
--     slower.
--   * The guns talk: when more than one is in action (the same side, within ~45 tiles), they take
--     turns - one fires while the other relays, feeds or changes its barrel. A gun on its own
--     pauses longer between bursts; one covering for a gun that is being worked on, shorter.
--   * The crew carries on: the gunner down, the assistant takes the gun and a rifleman moves up to
--     feed it; the gun fires until the whole team is out.
-- Moving: the guns go one at a time (leapfrogging) - one is set up and firing while the other
-- moves - and they stop short of the enemy (CFG.standoff), out where the rifles can't reach.
-- In a defence the guns take the front (front-left and front-right in the open; the best windows
-- toward the enemy in a building) and their riflemen the flanks. They don't go into a building that
-- is being cleared: they cover it from outside.
-- The enemy treats a firing gun as the most dangerous thing on the field: he shoots its crew first
-- (LF_Brain), throws grenades at it (LF_Grenade), and his sergeant flanks it (LF_Command).

require "TimedActions/ISBaseTimedAction"
require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/World/LF_Bodies"
require "LivingFront/World/LF_Sense"
require "LivingFront/World/LF_Cover"
require "LivingFront/Soldier/LF_Posture"
require "LivingFront/Soldier/LF_Weapons"
require "LivingFront/Soldier/LF_Suppress"
require "LivingFront/Soldier/LF_ShootAction"
require "LivingFront/Soldier/LF_Combat"
require "LivingFront/Units/LF_Units"
require "LivingFront/Tactics/LF_Command"

LF.MG = LF.MG or {}

local CFG = {
    range = 30,             -- aimed fire at men he can see this close
    areaRange = 34,         -- area fire at a last-known position this close
    burstTicks = 240,       -- ~4 s bursts ...
    burstJitter = 40,       -- ... give or take ~0.7 s (never under 3 s or over 5 s)
    burstMin = 180, burstMax = 300,
    minBurstSecs = 3,       -- a belt / pan with less than 3 s of firing left is changed first
    driftTiles = 1.6,       -- the gun stays set up unless he moves this far from where he set it
    atGun = 1.5,            -- the gunner counts as on the gun's spot this close to it
    settleTicks = 360,      -- en route to the spot this long with the enemy in sight: set up where he is
    windowArc = 0.3,        -- a gun in a window fires only out of it (cosine off the window's facing)
    adjust = 45,            -- after every burst, relaying the gun (~0.75 s at least)
    soloPause = { 90, 180 },-- a gun on its own: ~1.5-3 s between bursts
    coverPause = 50,        -- covering for a gun that is being worked on: shorter
    talkRange = 45,         -- guns this close (same side) take turns
    wantWindow = 90,        -- a gun counts as in action if it wanted to fire this recently
    setupTicks = 150,       -- setting the gun up where he stops
    cool = 0.1,             -- heat (rounds) lost per tick between bursts ...
    coolResting = 0.35,     -- ... and while resting a DP-27 to cool
    coolTo = 60,            -- ... until it's down to this
    gunnerServeMul = 1.6,   -- a gunner feeding / changing the barrel himself takes this much longer
    assistReach = 2.5,      -- the assistant must be this close to the gun to work on it
    zoneEvery = 3,          -- every 3rd round: anyone hostile where it lands may be hit
    zoneRadius = 1.0,
    splashEvery = 4,        -- every 4th round: suppression around the aim point
    splashRadius = 3.5,
    splashAmount = 9,
    suppressMiss = 6, suppressHit = 15,   -- on the man he's firing at, per round
    noiseEvery = 10,        -- rounds between world-noise / gunfire-memory updates
    voices = 4,             -- reports of one gun sounding at once (older ones are stopped)
    standoff = 22,          -- moving up, the guns stop this far short of the enemy
    bound = 10,             -- tiles a gun moves at a time
    settle = 360,           -- a gun fires at least ~6 s from a new spot before it moves again
    moveTimeout = 900,
    arrive = 3,
    repickTicks = 900,      -- no shot from his spot for a while: a new one at most every ~15 s
    blindTicks = 600,
    spotLeash = 5,          -- the gun's spot: within this of where the team was sent
    assistRange = 12,       -- the assistant uses his rifle only on an enemy this close
    gunBonus = 10,          -- (enemy target choice: tiles taken off for a firing gun's crew)
    firingMemory = 600,     -- a gun counts as firing ~10 s after its last burst
}
LF.MG.CFG = CFG

local guns = {}              -- team id -> gun state (runtime only)

Events.OnInitGlobalModData.Add(function() for k in pairs(guns) do guns[k] = nil end end)
function LF.MG.forgetAll() for k in pairs(guns) do guns[k] = nil end end

local function fmt(v) return string.format("%.0f", v) end
local function title(rec) return rec and LF.Units.title(rec) or "?" end
local function fit(rec) return LF.Tactics.I.fit(rec) end

local function profileFor(faction)
    return LF.Weapons.PROFILES[LF.Weapons.MG_OF[faction] or "MG34"]
end

-- ---- the squad -------------------------------------------------------------------------------

-- Make a new squad (LF_Units.createSquad) a machine-gun squad: Alpha and Bravo become Gun 1 and 2.
function LF.MG.outfit(squad)
    squad.mg = true
    squad.name = squad.name:gsub(" squad ", " MG squad ")
    local n = 0
    for _, tid in ipairs(squad.teams) do
        local team = LF.Units.get(tid)
        if team then
            n = n + 1
            team.mg, team.name = true, "Gun " .. n
            for _, rid in ipairs(team.members) do
                local r = LF.Records.get(rid)
                if r and r.slot <= 4 then                  -- (not the medic, Bravo's fifth man)
                    if r.slot == 1 then r.mgRole, r.weapon = "gunner", LF.Weapons.MG_OF[r.faction]
                    elseif r.rank == "CPL" then r.mgRole = "assistant"
                    else r.mgRole = "ammo" end
                end
            end
        end
    end
    LF.log("MG " .. squad.name .. ": " .. n .. " gun teams (" .. (LF.Weapons.MG_OF[squad.faction] or "?") .. ")")
end

function LF.MG.isGunner(rec) return rec ~= nil and rec.mgRole == "gunner" end

local ROLE_NAME = { gunner = "machine gunner", assistant = "assistant gunner", ammo = "ammunition bearer" }
function LF.MG.roleName(rec) return rec and ROLE_NAME[rec.mgRole or ""] end

-- The gun team's men: gunner, assistant, the others (records).
local function crew(team)
    local g, a, rest = nil, nil, {}
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and r.team == team.id and r.alive and not r.medic then   -- (the medic never crews the gun)
            if r.mgRole == "gunner" and not g then g = r
            elseif r.mgRole == "assistant" and not a then a = r
            else rest[#rest + 1] = r end
        end
    end
    return g, a, rest
end

local function gunOf(team)
    local g = guns[team.id]
    if not g then
        local P = profileFor(team.faction)
        g = { team = team.id, squad = team.squad, faction = team.faction, belt = P.clip, heat = 0, heatAt = LF.tick,
              readyAt = 0, soloPause = CFG.soloPause[1] }
        guns[team.id] = g
    end
    return g
end
LF.MG.gunOf = gunOf

local function heatNow(g)
    local rate = (g.service and g.service.kind == "cool") and CFG.coolResting or CFG.cool
    local h = g.heat
    if not g.firing then h = math.max(0, h - (LF.tick - g.heatAt) * rate) end
    g.heat, g.heatAt = h, LF.tick
    return h
end

-- ---- crew drill: the crew carries on ----------------------------------------------------------

local function arm(rec)
    local b = LF.Bodies.get(rec.id)
    if b then LF.guard("mg arm", LF.Combat.arm, b) end
end

local function upkeep(team)
    local g = gunOf(team)
    local gr, ar, rest = crew(team)
    local function takeFrom(list)
        for i, r in ipairs(list) do
            if fit(r) and LF.Bodies.get(r.id) then table.remove(list, i); return r end
        end
        return nil
    end
    if not (gr and fit(gr)) then
        local new = nil
        if ar and fit(ar) and LF.Bodies.get(ar.id) then new, ar = ar, nil else new = takeFrom(rest) end
        if new then
            -- Holding a building: he takes the gun's window (and the man he replaces his old post).
            local squad = LF.Units.get(team.squad)
            local S = squad and LF.Tactics.state(squad)
            if gr and S and S.posts and S.posts[gr.id] then
                S.posts[gr.id], S.posts[new.id] = S.posts[new.id], S.posts[gr.id]
            end
            if gr then gr.mgRole, gr.weapon = "ammo", nil end      -- (if he comes back, with a rifle)
            new.mgRole, new.weapon = "gunner", LF.Weapons.MG_OF[team.faction]
            arm(new)
            g.set, g.gunnerId, g.service, g.firing, g.unsetBy = false, new.id, nil, false, "a new gunner"
            LF.log("MG " .. team.name .. ": " .. title(new) .. " takes the gun" .. (gr and (" from " .. title(gr)) or ""))
            LF.Tactics.shout(new.id, "I've got the gun!")
            gr = new
        end
    end
    if gr and not (ar and fit(ar)) then
        local new = takeFrom(rest)
        if new then
            local squad = LF.Units.get(team.squad)
            local S = squad and LF.Tactics.state(squad)
            if ar and S and S.posts and S.posts[ar.id] and (S.posts[ar.id].kind == "assist") then
                S.posts[ar.id], S.posts[new.id] = S.posts[new.id], S.posts[ar.id]
            end
            if ar then ar.mgRole = "ammo" end
            new.mgRole = "assistant"
            g.aspot = nil
            LF.log("MG " .. team.name .. ": " .. title(new) .. " moves up to feed the gun")
            LF.Tactics.shout(new.id, "On the gun!")
            ar = new
        end
    end
    g.gunnerId = gr and gr.id or nil
    g.assistId = ar and ar.id or nil
end

-- ---- timed actions -----------------------------------------------------------------------------

local function play(body, name) if name and name ~= "" then body:playSound(name) end end

-- Setting the gun up where he has stopped.
LF_MGSetupAction = ISBaseTimedAction:derive("LF_MGSetupAction")
function LF_MGSetupAction:isValid() return not self.character:isDead() end
function LF_MGSetupAction:waitToStart() return false end
function LF_MGSetupAction:start()
    LF.Posture.set(self.character, not self.stand)
    self:setActionAnim(self.stand and "LF_AimRifle" or "LF_AimCrouch")
    if self.gun then self:setOverrideHandModels(self.gun, nil) end
end
function LF_MGSetupAction:update()
    if self.point and LF.due(20, 0) then LF.Combat.readyToFire(self.character, self.point) end
end
function LF_MGSetupAction:stop() ISBaseTimedAction.stop(self) end
function LF_MGSetupAction:perform()
    local g, b = self.g, self.character
    g.set, g.setX, g.setY, g.setAt = true, b:getX(), b:getY(), LF.tick
    g.setups = (g.setups or 0) + 1
    if self.gun then LF.guard("mg rack", play, b, self.gun:getRackSound()) end
    LF.log("MG #" .. tostring(b:getModData().LF_id) .. " sets up the gun at " .. math.floor(b:getX()) .. "," .. math.floor(b:getY())
        .. (self.stand and " (in a window)" or ""))
    ISBaseTimedAction.perform(self)
end
function LF_MGSetupAction:new(character, g, gun, stand, point)
    local o = ISBaseTimedAction.new(self, character)
    o.g, o.gun, o.stand, o.point = g, gun, stand, point
    o.maxTime = CFG.setupTicks
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.ignoreHandsWounds = true
    return o
end

-- Working on the gun: a new belt (pan), or a new barrel. (The gunner's or the assistant's.)
LF_MGServeAction = ISBaseTimedAction:derive("LF_MGServeAction")
function LF_MGServeAction:isValid() return not self.character:isDead() end
function LF_MGServeAction:waitToStart() return false end
function LF_MGServeAction:start()
    if not self.stand then LF.Posture.set(self.character, true) end
    self:setActionAnim("LF_MGFeed")
    if self.gb and self.gun then LF.guard("mg sound", play, self.gb, self.kind == "belt" and self.gun:getEjectAmmoSound() or self.gun:getRackSound()) end
end
function LF_MGServeAction:stop()
    if self.g.service and self.g.service.by == self.id then self.g.service = nil end
    ISBaseTimedAction.stop(self)
end
function LF_MGServeAction:perform()
    local g = self.g
    local P = profileFor(g.faction)
    if self.kind == "belt" then g.belt = P.clip else g.heat, g.heatAt = 0, LF.tick end
    g.service = nil
    g.readyAt = LF.tick + 20
    if self.gb and self.gun then
        LF.guard("mg sound", play, self.gb, self.kind == "belt" and self.gun:getInsertAmmoSound() or nil)
        LF.guard("mg sound", play, self.gb, self.gun:getRackSound())
    end
    LF.log("MG " .. tostring(g.teamName) .. ": " .. (self.kind == "belt" and (P.name == "DP-27" and "new pan on" or "new belt in")
        or "barrel changed") .. " (#" .. tostring(self.id) .. ")")
    ISBaseTimedAction.perform(self)
end
function LF_MGServeAction:new(character, g, kind, ticks, gb, gun, stand)
    local o = ISBaseTimedAction.new(self, character)
    o.g, o.kind, o.gb, o.gun, o.stand = g, kind, gb, gun, stand
    o.id = character:getModData().LF_id
    o.maxTime = math.floor(ticks)
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.ignoreHandsWounds = true
    return o
end

-- ---- the burst ---------------------------------------------------------------------------------

local zoneCtx = {}
local function zoneOne(e, _dsq, ctx)
    if e.body == ctx.target or e.body:isDead() or not LF.isHostile(ctx.faction, e.rec.faction) then return end
    if LF.Medic and LF.Medic.isCritical(e.id or e.rec.id) then return end     -- (down, calling for the medic)
    local mod = LF.Combat.targetModifier and (LF.guard("cover modifier", LF.Combat.targetModifier, ctx.shooter, e.body) or 1) or 1
    if ZombRand(1000) < ctx.P.zoneHit * 10 * mod then
        LF.Combat.applyHit(ctx.shooter, e.body, ctx.P, ctx.dist)
        ctx.burst.zoneHits = ctx.burst.zoneHits + 1
        if LF.Service then LF.guard("service shot", LF.Service.shot, ctx.sid, e.rec.id, true) end
    end
end

-- One round of a burst.
local function round(self)
    local s, g, P, t = self.character, self.g, self.profile, self.target
    g.belt = g.belt - 1
    g.heat, g.heatAt = g.heat + 1, LF.tick
    self.fired = self.fired + 1
    -- At 900 rounds a minute the reports overlap: each gun keeps only its last few sounding, so a
    -- burst doesn't take every sound voice the game has (and cut off other sounds - a grenade's
    -- bang - in the middle of a fire fight).
    local ok, h = pcall(function() return s:playSound(P.sound) end)
    if ok and h then
        self.voices = self.voices or {}
        local v = self.voices
        v[#v + 1] = h
        if #v > CFG.voices then
            local old = table.remove(v, 1)
            pcall(function() s:getEmitter():stopSoundDelayRelease(old) end)
        end
    end
    if self.fired % CFG.noiseEvery == 1 then LF.Combat.noteShot(s) end
    local tx, ty = t:getX(), t:getY()
    local dx, dy = tx - s:getX(), ty - s:getY()
    local dist = math.max(0.5, math.sqrt(dx * dx + dy * dy))
    local ux, uy = dx / dist, dy / dist
    if not self.area then
        local chance = LF.Combat.hitChance(s, t, dist, P)
        if ZombRand(1000) < chance * 10 then
            LF.Combat.applyHit(s, t, P, dist)
            self.hits = self.hits + 1
            LF.Suppress.add(t, CFG.suppressHit * P.suppress, s)
            if LF.Service then LF.guard("service shot", LF.Service.shot, self.sid, t:getModData().LF_id, true) end
        else
            LF.Suppress.add(t, CFG.suppressMiss * P.suppress, s)
        end
    end
    -- Where it lands: the beaten zone, long along the line of fire, narrow across it.
    if self.fired % CFG.zoneEvery == 0 then
        local L, W = 2 + dist * 0.12, 0.8 + dist * 0.03
        local along = (ZombRand(1000) / 1000 - 0.4) * L
        local side = (ZombRand(1000) / 1000 - 0.5) * W
        local ix, iy = tx + ux * along - uy * side, ty + uy * along + ux * side
        zoneCtx.target, zoneCtx.faction, zoneCtx.shooter, zoneCtx.P, zoneCtx.dist = (not self.area) and t or nil, self.faction, s, P, dist
        zoneCtx.burst, zoneCtx.sid = self, self.sid
        LF.Sense.near(ix, iy, CFG.zoneRadius, zoneOne, zoneCtx)
    end
    if self.fired % CFG.splashEvery == 0 then
        local n = LF.Combat.splash(s, tx, ty, CFG.splashRadius, CFG.splashAmount * P.suppress, nil) or 0
        if n > self.supp then self.supp = n end
    end
end

LF_MGBurstAction = ISBaseTimedAction:derive("LF_MGBurstAction")
function LF_MGBurstAction:isValid() return self.target ~= nil and not self.character:isDead() end
function LF_MGBurstAction:waitToStart() return false end
function LF_MGBurstAction:start()
    self.character:setMaxTwist(0)
    self:setActionAnim(self.stand and "LF_AimRifle" or "LF_AimCrouch")
    if self.gun then self:setOverrideHandModels(self.gun, nil) end
    self.interval = 3600 / self.profile.rpm
    self.nextRound = LF.tick
    local len = CFG.burstTicks + ZombRand(2 * CFG.burstJitter + 1) - CFG.burstJitter
    self.endAt = LF.tick + math.max(CFG.burstMin, math.min(CFG.burstMax, len))
    self.g.firing = true
end
function LF_MGBurstAction:update()
    local t = self.target
    if not self.area and t:isDead() then
        -- He's down: the gunner keeps on at where he was (the rest of the burst is area fire).
        self.target = LF.Tactics.point(t:getX(), t:getY(), t:getZ())
        self.area = true
    end
    if LF_ShootAction.track(self.character, self.target) > 100 then self:forceStop(); return end
    local now = LF.tick
    while self.nextRound <= now and now < self.endAt and self.g.belt > 0 do
        LF.guard("mg round", round, self)
        self.nextRound = self.nextRound + self.interval
    end
    if now >= self.endAt or self.g.belt <= 0 then self:forceComplete() end
end
local function finish(self)
    if self.finished then return end
    self.finished = true
    local g = self.g
    g.firing = false
    g.lastEnd = LF.tick
    LF.MG.bursts = (LF.MG.bursts or 0) + 1
    LF.MG.rounds = (LF.MG.rounds or 0) + self.fired
    g.readyAt = LF.tick + CFG.adjust + ZombRand(30)
    g.soloPause = CFG.soloPause[1] + ZombRand(CFG.soloPause[2] - CFG.soloPause[1] + 1)
    local t = self.target
    LF.log("MG #" .. tostring(self.sid) .. " " .. self.profile.name .. " (" .. tostring(g.teamName) .. "): burst of " .. self.fired
        .. " at " .. (self.area and ("area " .. math.floor(t:getX()) .. "," .. math.floor(t:getY()))
            or ("#" .. tostring(t:getModData().LF_id)))
        .. " - " .. self.hits .. " hit(s) on target, " .. self.zoneHits .. " in the beaten zone, up to " .. self.supp
        .. " suppressed; belt " .. g.belt .. ", heat " .. fmt(heatNow(g)))
end
function LF_MGBurstAction:stop() finish(self); ISBaseTimedAction.stop(self) end
function LF_MGBurstAction:perform() finish(self); ISBaseTimedAction.perform(self) end
function LF_MGBurstAction:new(character, g, target, gun, profile, area, stand)
    local o = ISBaseTimedAction.new(self, character)
    o.g, o.target, o.gun, o.profile, o.area, o.stand = g, target, gun, profile, area, stand
    o.sid = character:getModData().LF_id
    o.faction = g.faction
    o.fired, o.hits, o.zoneHits, o.supp = 0, 0, 0, 0
    o.maxTime = -1
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.ignoreHandsWounds = true
    return o
end

-- ---- the guns talk -----------------------------------------------------------------------------

-- May this gun open fire now? One gun of a side fires at a time, within talkRange; the one that
-- has waited longest goes next. A gun on its own pauses between bursts (shorter while the other
-- gun is being worked on).
local function mayFire(g)
    local now = LF.tick
    local others, worked = 0, nil
    for _, o in pairs(guns) do
        if o ~= g and o.faction == g.faction and o.gunnerId and o.x and now - (o.wantAt or -100000) <= CFG.wantWindow
            and LF.distSq(o.x, o.y, g.x, g.y) <= CFG.talkRange * CFG.talkRange then
            if o.firing then return false end
            if o.service then
                worked = o
            elseif o.set then
                others = others + 1
                -- The other gun is ready, on target, and has been waiting longer: it goes first.
                if now >= (o.readyAt or 0) and now - (o.aimedAt or -100000) <= 30
                    and (o.lastEnd or -100000) < (g.lastEnd or -100000) then
                    return false
                end
            end
        end
    end
    if others == 0 then
        local pause = worked and CFG.coverPause or g.soloPause
        if now - (g.lastEnd or -100000) < pause then return false end
        if worked and g.coveringFor ~= worked.service then
            g.coveringFor = worked.service
            if g.gunnerId then LF.Tactics.shout(g.gunnerId, "Covering!") end
            LF.log("MG " .. tostring(g.teamName) .. " covers while " .. tostring(worked.teamName) .. " is "
                .. (worked.service.kind == "barrel" and "changing its barrel" or (worked.service.kind == "cool" and "cooling" or "reloading")))
        end
    end
    return true
end

-- ---- working the gun -----------------------------------------------------------------------

local function busyOther(b)
    local q = ISTimedActionQueue.getTimedActionQueue(b)
    local a = q and q.queue and q.queue[1]
    return a ~= nil and a.Type == "LF_MGServeAction"
end

local SERVE_WORDS = { belt = { GER = "Belt!", SOV = "Pan!" }, barrel = { GER = "Barrel!", SOV = "Barrel!" } }

local function startService(g, kind, gb, gr, team, stand)
    local P = profileFor(g.faction)
    if kind == "cool" then
        g.service = { kind = "cool", by = gr.id, since = LF.tick }
        LF.Tactics.shout(gr.id, "She's hot - let her cool!")
        LF.log("MG " .. team.name .. ": the " .. P.name .. " is too hot, resting it to cool (heat " .. fmt(g.heat) .. ")")
        return
    end
    local ticks = kind == "belt" and P.reload or P.barrel
    local who, wb = gr, gb
    local _, ar = crew(team)
    local ab = ar and LF.Bodies.get(ar.id)
    local why = nil
    if not ar then why = "no assistant left"
    elseif not ab then why = "assistant not here"
    elseif not fit(ar) then why = "assistant hurt"
    elseif LF.dist(ab:getX(), ab:getY(), gb:getX(), gb:getY()) > CFG.assistReach then
        why = "assistant " .. string.format("%.1f", LF.dist(ab:getX(), ab:getY(), gb:getX(), gb:getY())) .. " tiles away"
    elseif busyOther(ab) then why = "assistant busy" end
    if not why then who, wb = ar, ab else ticks = ticks * CFG.gunnerServeMul end
    if wb:isPerformingAnAction() then ISTimedActionQueue.clear(wb) end   -- (the assistant drops his rifle shot)
    g.service = { kind = kind, by = who.id, since = LF.tick, ticks = ticks }
    ISTimedActionQueue.add(LF_MGServeAction:new(wb, g, kind, ticks, gb, gb:getPrimaryHandItem(), who == gr and stand))
    LF.Tactics.shout(who.id, (SERVE_WORDS[kind] or {})[g.faction] or "Reloading!")
    LF.log("MG " .. team.name .. ": " .. title(who) .. (kind == "belt" and (P.name == "DP-27" and " fits a new pan" or " feeds a new belt")
        or " changes the barrel") .. (who == gr and (" himself (" .. tostring(why) .. ")") or "") .. ", heat " .. fmt(g.heat))
end

-- Something waiting in his action queue (not yet started).
local function queued(body)
    local q = ISTimedActionQueue.getTimedActionQueue(body)
    return q ~= nil and q.queue ~= nil and #q.queue > 0
end

-- One fire step for a gunner (from the brain, every tick while he's fighting): target is a body
-- (aimed fire) or a point (area fire).
function LF.MG.fire(body, rec, m, target, area)
    local team = rec.team and LF.Units.get(rec.team)
    if not (team and team.mg) then
        if area then return LF.Combat.engageArea(body, target, m.combat) end
        return LF.Combat.engage(body, target, m.combat, m.combatOpts)
    end
    local g = gunOf(team)
    g.teamName, g.gunnerId = team.name, rec.id
    g.wantAt = LF.tick
    g.x, g.y, g.z = body:getX(), body:getY(), body:getZ()
    -- (Anything queued counts, not only an action under way: up to 0.73.2 a set-up queued but not
    -- yet started let the next tick queue another, and the gun spent half a minute setting up.)
    if body:isPerformingAnAction() or queued(body) then return end
    local stand = m.cover ~= nil and m.cover.stand == true          -- (at a window or over low cover: standing to it)
    -- (Not the exact square: a man jostled half a tile by the man beside him hasn't moved the
    -- gun - up to 0.43 that set it up again and again without ever firing.)
    if not g.set or LF.dist(body:getX(), body:getY(), g.setX or -1000, g.setY or -1000) > CFG.driftTiles then
        -- (0.73.2, diagnosis: the guns set up again and again and hardly fire - say why.)
        if g.setX and (g.setups or 0) >= 1 and LF.tick - (g.whyAt or -100000) > 120 then
            g.whyAt = LF.tick
            LF.log(string.format("MG #%s sets up again: set %s, %.1f tiles from where he set it up %.1f s ago, by %s",
                tostring(rec.id), tostring(g.set), LF.dist(body:getX(), body:getY(), g.setX, g.setY),
                (LF.tick - (g.setAt or LF.tick)) / 60, tostring(g.unsetBy)))
        end
        g.set, g.unsetBy = false, nil
        ISTimedActionQueue.add(LF_MGSetupAction:new(body, g, LF.Combat.arm(body), stand, target))
        return
    end
    local P = profileFor(g.faction)
    g.block = nil
    if g.service then
        g.block = "service " .. tostring(g.service.kind)
        if g.service.kind == "cool" and heatNow(g) <= CFG.coolTo then
            g.service = nil
            LF.log("MG " .. team.name .. ": cooled, back in action")
        else
            LF.Combat.readyToFire(body, target)
            return
        end
    end
    -- Less than ~3 s of firing left in the belt (a DP-27's pan, after one burst): change it now
    -- rather than fire a short stub of a burst.
    if g.belt <= 0 or g.belt < P.rpm / 60 * CFG.minBurstSecs then startService(g, "belt", body, rec, team, stand); return end
    local h = heatNow(g)
    if P.barrelAt and h >= P.barrelAt then startService(g, "barrel", body, rec, team, stand); return end
    if P.coolAt and h >= P.coolAt then startService(g, "cool", body, rec, team, stand); return end
    local ready = LF.Combat.readyToFire(body, target)
    if ready then g.aimedAt = LF.tick end
    if LF.tick < (g.readyAt or 0) then g.block = "adjusting after a burst"; return end
    if not ready then
        -- (Kept on the gun: the brain's combat memory is reset under him, and up to 0.73.2 the
        -- 3 s "fire anyway" never came.)
        g.turnStart = g.turnStart or LF.tick
        if LF.tick - g.turnStart < 180 then g.block = "turning onto the target"; return end
    end
    g.turnStart = nil
    if not mayFire(g) then g.block = "waiting its turn (the other gun / pause)"; return end
    g.firing = true
    ISTimedActionQueue.add(LF_MGBurstAction:new(body, g, target, LF.Combat.arm(body), P, area, stand))
end

-- Out of the fight: the belt topped up (a part-used belt swapped for a full one).
function LF.MG.topUp(body, rec)
    local team = rec.team and LF.Units.get(rec.team)
    if not (team and team.mg) or body:isPerformingAnAction() then return false end
    local g = gunOf(team)
    g.teamName = team.name
    local P = profileFor(g.faction)
    if g.service or g.belt >= P.clip then return false end
    startService(g, "belt", body, rec, team, false)
    return true
end

-- ---- where the crew goes (from LF_Tactics.place) ----------------------------------------------

-- The gun's spot near (ax, ay): a firing position with a view of the threat (preferring low cover
-- to rest it on), kept until the team is sent elsewhere or there's been no shot from it for a while.
local function gunSpot(g, rec, ax, ay, z, threat, watching)
    local now = LF.tick
    local need = not g.spot or not g.anchor or LF.dist(g.anchor.x, g.anchor.y, ax, ay) > 2.5 or g.repick
    if not need and not watching and threat and now - (g.pickedAt or 0) > CFG.repickTicks then
        local m = LF.Brain and LF.Brain.mindOf and LF.Brain.mindOf(rec.id)
        if m and m.gunSince and now - math.max(m.lastSight or -100000, m.gunSince) > CFG.blindTicks then
            need = true
            LF.log("MG " .. tostring(g.teamName) .. ": no shot from here - moving the gun")
        end
    end
    -- (0.74.2) A gun set up in the open with the enemy known: every 5 s, is there a covered square
    -- with a view close by? Then it moves there.
    if not need and not watching and threat and g.spot and now - (g.pickedAt or 0) > 300 and now - (g.openCheck or -100000) > 300
        and not (g.spot.z and getCell():getGridSquare(g.spot.x, g.spot.y, g.spot.z) and getCell():getGridSquare(g.spot.x, g.spot.y, g.spot.z):getBuilding())
        and LF.Cover.quality(g.spot.x, g.spot.y, g.spot.z or 0, threat:getX(), threat:getY()) == LF.Cover.NONE then
        g.openCheck = now
        local body = LF.Bodies.get(rec.id)
        if body and rec.squad and LF.SquadBrain and LF.SquadBrain.enabled and LF.Units.get(rec.squad) then
            local sx, sy, sz = LF.SquadBrain.spotFor(rec.id, body, rec, threat, CFG.areaRange, ax, ay, CFG.spotLeash + 3)
            if sx and not (sx == g.spot.x and sy == g.spot.y) then
                LF.log("MG " .. tostring(g.teamName) .. ": in the open - moving the gun to cover at " .. sx .. "," .. sy)
                g.spot = { x = sx, y = sy, z = sz }
                g.aspot, g.pickedAt, g.set, g.unsetBy = nil, now, false, "the gun moving to cover"
            end
        end
    end
    if need then
        g.repick, g.pickedAt = nil, now
        g.anchor = g.anchor or {}
        g.anchor.x, g.anchor.y = ax, ay
        local body = LF.Bodies.get(rec.id)
        local sx, sy, sz = nil, nil, nil
        if body and threat then
            -- (A squad's gun: from its squad's placement - LF_SquadBrain - 5 tiles from where the
            -- team was sent, else 8 (0.74.2: guns set up in the open with cover 1-5 tiles off).)
            if rec.squad and LF.SquadBrain and LF.SquadBrain.enabled and LF.Units.get(rec.squad) then
                sx, sy, sz = LF.SquadBrain.spotFor(rec.id, body, rec, threat, CFG.areaRange, ax, ay, CFG.spotLeash)
                if not sx then sx, sy, sz = LF.SquadBrain.spotFor(rec.id, body, rec, threat, CFG.areaRange, ax, ay, CFG.spotLeash + 3) end
            else
                sx, sy, sz = LF.Cover.findFiringPosition(rec.id, body, threat, CFG.areaRange, ax, ay, CFG.spotLeash)
            end
        end
        -- No proper firing position: a square near the anchor that can at least see the enemy -
        -- else stay where the gun is rather than set it up blind (0.68.3: a gun in the middle of
        -- a room, firing at walls).
        if not sx and threat then
            sx, sy, sz = LF.Cover.viewPointNear(ax, ay, math.floor(z or 0), math.floor(threat:getX()), math.floor(threat:getY()), 5)
        end
        if not sx and g.spot then sx, sy, sz = g.spot.x, g.spot.y, g.spot.z end
        if not sx then sx, sy, sz = math.floor(ax), math.floor(ay), math.floor(z or 0) end
        g.spot = { x = sx, y = sy, z = sz }
        g.aspot = nil
    end
    return g.spot
end

-- The assistant's square: beside the gun (to the side, a little back), never in front of it.
local function assistSpot(g, threat)
    local s = g.spot
    if g.aspot and g.aspotFor == s then return g.aspot end
    local ux, uy = 1, 0
    if threat then
        local dx, dy = threat:getX() - (s.x + 0.5), threat:getY() - (s.y + 0.5)
        local d = math.sqrt(dx * dx + dy * dy)
        if d > 0.5 then ux, uy = dx / d, dy / d end
    end
    local cell = getCell()
    local gsq = cell:getGridSquare(s.x, s.y, s.z)
    local inBuilding = gsq and gsq:getBuilding() ~= nil
    local offs = inBuilding and { { -ux, -uy }, { -uy - ux, ux - uy }, { uy - ux, -ux - uy }, { -uy, ux }, { uy, -ux } }
        or { { -uy, ux }, { uy, -ux }, { -uy - ux * 0.7, ux - uy * 0.7 }, { uy - ux * 0.7, -ux - uy * 0.7 }, { -ux, -uy } }
    for _, o in ipairs(offs) do
        local x, y = math.floor(s.x + 0.5 + o[1]), math.floor(s.y + 0.5 + o[2])
        if not (x == s.x and y == s.y) then
            local sq = cell:getGridSquare(x, y, s.z)
            if sq and sq:isFree(false) and (not inBuilding or sq:getBuilding() ~= nil)
                and not (LF.Brain and LF.Brain.hardClaimed and LF.Brain.hardClaimed(x, y, s.z, g.assistId)) then
                g.aspot, g.aspotFor = { x = x, y = y, z = s.z }, s
                return g.aspot
            end
        end
    end
    g.aspot, g.aspotFor = nil, s
    return nil
end

-- One of the squad's rifle teams clearing a building: the guns keep firing on it, but not where
-- their own men are going in - on the opening furthest from the door being cleared (the way out
-- the enemy would take). nil if nobody is clearing.
local function clearingPoint(squad)
    for _, tid in ipairs(squad.teams) do
        local t = LF.Tactics.I.teams[tid]
        local C = t and t.clear
        if C and C.L and C.door then
            if not C.mgPoint then
                local best, bd = nil, -1
                for _, o in ipairs(C.L.openings or {}) do
                    local d = LF.dist(o.x, o.y, C.door.x, C.door.y)
                    if d > bd then best, bd = o, d end
                end
                local x, y = best and (best.x + 0.5 + (best.dx or 0) * 2) or C.L.cx, best and (best.y + 0.5 + (best.dy or 0) * 2) or C.L.cy
                C.mgPoint = LF.Tactics.point(x, y, C.L.z)
                LF.log("MG " .. squad.name .. ": " .. LF.Units.get(tid).name .. " is clearing - the guns shift their fire to "
                    .. math.floor(x) .. "," .. math.floor(y))
            end
            return C.mgPoint
        end
    end
    return nil
end

-- A gunner posted at a window: the way the window faces (unit vector), or nil.
local function windowDir(rec)
    local squad = rec.squad and LF.Units.get(rec.squad)
    local S = squad and LF.Tactics.state(squad)
    local p = S and S.posts and S.posts[rec.id]
    if not (p and p.kind == "window" and p.wall) then return nil end
    local d = LF.Building.WALL_DIR[p.wall]
    return d[1], d[2], p
end

-- May the gun fire at (x, y)? From a window, only out of it - never back across the room he's
-- in (up to 0.43 a gun at an east window could be given an enemy to the south-west and fired
-- through the house). Anywhere else, anything.
function LF.MG.gunCovers(rec, x, y)
    local dx, dy, p = windowDir(rec)
    if not dx then return true end
    local vx, vy = x - (p.x + 0.5), y - (p.y + 0.5)
    local d = math.sqrt(vx * vx + vy * vy)
    if d <= 4 then return true end
    return (vx * dx + vy * dy) / d >= CFG.windowArc
end

-- The gunner has been held up on the way to the gun's spot with the enemy in front of him: the gun
-- goes where he is.
function LF.MG.settleHere(rec, body)
    local team = rec.team and LF.Units.get(rec.team)
    if not (team and team.mg) then return end
    local g = gunOf(team)
    g.spot = { x = math.floor(body:getX()), y = math.floor(body:getY()), z = math.floor(body:getZ()) }
    g.pickedAt, g.aspot = LF.tick, nil
    LF.log("MG " .. team.name .. ": held up on the way - setting the gun up where he is")
end

-- Called with a crewman's normal placement; returns his placement on the gun: "gun" (the gunner,
-- on the gun's spot) or "assist" (beside it). Everyone else, and anything that isn't a fighting
-- position (moving, marching, clearing), passes straight through.
function LF.MG.place(rec, role, x, y, z, point, watching, coverPoint, stand, win, shove)
    if not role or role == "file" or role == "move" or role == "command"
        or (rec.mgRole ~= "gunner" and rec.mgRole ~= "assistant") then
        return role, x, y, z, point, watching, coverPoint, stand, win, shove
    end
    local team = rec.team and LF.Units.get(rec.team)
    if not (team and team.mg) then return role, x, y, z, point, watching, coverPoint, stand, win, shove end
    local g = gunOf(team)
    g.teamName = team.name
    local squad = LF.Units.get(rec.squad)
    if point and not watching and squad then point = clearingPoint(squad) or point end
    local threat = (not watching and point) or coverPoint or point
    if rec.mgRole == "gunner" then
        g.gunnerId = rec.id
        if role == "post" then
            -- In a building: the window he was given (LF.MG.dealPosts). Only what's out of it:
            -- anything else, he watches out of it.
            g.spot = g.spot or {}
            g.spot.x, g.spot.y, g.spot.z = math.floor(x), math.floor(y), math.floor(z)
            g.stand = stand
            local dx, dy = windowDir(rec)
            if dx and point and not watching and not LF.MG.gunCovers(rec, point.x, point.y) then
                g.watchPt = g.watchPt or LF.Tactics.point(0, 0, 0)
                g.watchPt.x, g.watchPt.y, g.watchPt.z = x + dx * 15, y + dy * 15, z
                point, watching = g.watchPt, true
            end
            return "gun", x, y, z, point, watching, coverPoint, stand, win, shove
        end
        g.stand = false
        local s = gunSpot(g, rec, x, y, z, threat, watching)
        return "gun", s.x + 0.5, s.y + 0.5, s.z, point, watching, coverPoint, false
    end
    g.assistId = rec.id
    if role == "post" then return "assist", x, y, z, point, watching, coverPoint, false end
    local gb = g.gunnerId and LF.Bodies.get(g.gunnerId)
    if not (gb and g.spot) then return role, x, y, z, point, watching, coverPoint, stand, win, shove end
    local a = assistSpot(g, threat)
    if not a then return role, x, y, z, point, watching, coverPoint, stand, win, shove end
    return "assist", a.x + 0.5, a.y + 0.5, a.z, point, watching, coverPoint, false
end

-- The gunner couldn't get to the gun's spot: pick another next time.
function LF.MG.unreachable(rec)
    local team = rec.team and LF.Units.get(rec.team)
    if team and team.mg then gunOf(team).repick = true end
end

-- Does the gun need its assistant right now (being worked on)?
function LF.MG.needsAssistant(rec)
    local team = rec.team and LF.Units.get(rec.team)
    local g = team and team.mg and guns[team.id]
    return g ~= nil and g.service ~= nil and g.service.by == rec.id
end

-- Where the assistant looks: what the gun is firing at.
function LF.MG.aimOf(rec)
    local team = rec.team and LF.Units.get(rec.team)
    local g = team and guns[team.id]
    if g and g.aimX then return g.aimX, g.aimY end
    return nil
end

-- ---- moving: one gun at a time ------------------------------------------------------------------

local function arrived(team, t)
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and r.team == team.id and fit(r) then
            local b = LF.Bodies.get(rid)
            local p = t.pos[r.element]
            if b and p and LF.dist(b:getX(), b:getY(), p.x, p.y) > CFG.arrive
                and not (LF.Brain and LF.Brain.isStuck and LF.Brain.isStuck(rid, p.x, p.y)) then
                return false
            end
        end
    end
    return true
end

-- A gun team's drill under the squad's orders (instead of the rifle teams' bounding): hold where
-- it is; advancing or falling back, the guns leapfrog - a gun moves only while the other is in
-- action, after firing from its spot for a while, and an advance stops CFG.standoff short.
function LF.MG.driveTeam(team, t, squad, sq)
    local I = LF.Tactics.I
    local order = t.heard
    if order == "MANEUVER" then order = "HOLD" end
    if t.order ~= order then
        if order == "HOLD" and t.shifting then
            for _, el in ipairs({ "A", "B" }) do
                local x, y = I.elementCentre(team, el)
                if x then t.pos[el].x, t.pos[el].y = x, y end
            end
            t.shifting = nil
        end
        t.order = order
    end
    if t.shifting then
        if arrived(team, t) or LF.tick - (t.phaseStart or 0) > CFG.moveTimeout then
            t.shifting, t.settledAt = nil, LF.tick
            LF.log("MG " .. team.name .. " of " .. squad.name .. " in its new position")
        end
        return
    end
    local c = sq.contact
    if not c or (order ~= "ADVANCE" and order ~= "FALLBACK") then return end
    if LF.tick - (t.settledAt or -100000) < CFG.settle then return end
    for _, tid in ipairs(squad.teams) do
        local o, ot = LF.Units.get(tid), I.teams[tid]
        if tid ~= team.id and o and o.mg and ot and ot.shifting then return end    -- the other gun is moving
    end
    local p = t.pos.A
    local dx, dy = c.x - p.x, c.y - p.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 0.5 then return end
    dx, dy = dx / d, dy / d
    local len, words
    if order == "ADVANCE" then
        if d <= CFG.standoff + 3 then return end
        len, words = math.min(CFG.bound, d - CFG.standoff), " moving up!"
    else
        if d >= LF.Tactics.CFG.fallbackClear + 6 then return end
        len, words = -CFG.bound, " pulling back!"
    end
    -- (Where it moves to must give it a line of fire on the enemy - not a room with no window, not
    -- behind a wall. Off-screen, with no ground to test, it goes as planned.)
    local nx, ny = p.x + dx * len, p.y + dy * len
    local z = math.floor(c.z or 0)
    local cell = getCell()
    if cell and cell:getGridSquare(math.floor(nx), math.floor(ny), z) then
        local vx, vy = nil, nil
        for _, k in ipairs({ 1, 0.6, 0.3 }) do
            vx, vy = LF.Cover.viewPointNear(p.x + dx * len * k, p.y + dy * len * k, z, math.floor(c.x), math.floor(c.y), 3)
            if vx then break end
        end
        if not vx then return end           -- (nowhere better to fire from: it stays)
        nx, ny = vx + 0.5, vy + 0.5
        len = LF.dist(p.x, p.y, nx, ny) * (order == "ADVANCE" and 1 or -1)
    end
    p.x, p.y = nx, ny
    t.pos.B.x, t.pos.B.y = p.x - dx * 2.5, p.y - dy * 2.5      -- security just behind the gun
    t.shifting, t.phaseStart = true, LF.tick
    local g = guns[team.id]
    if g then g.set, g.unsetBy = false, "the gun moving" end
    if team.leader then LF.Tactics.shout(team.leader, team.name .. words .. " Keep firing!") end
    LF.log("MG " .. team.name .. " of " .. squad.name .. (order == "ADVANCE" and " moves up " or " pulls back ")
        .. math.floor(math.abs(len)) .. " tiles while the other gun covers")
end

-- ---- in a defence ---------------------------------------------------------------------------------

-- Holding a building: the gunners take the best windows - Gun 1 on the wall facing the enemy,
-- Gun 2 on a wall beside it (or the front) - and each assistant the square just inside, next to
-- him. Whoever had those posts takes the gun crew's old ones. (Called by LF_Defence once the
-- posts are dealt.)
function LF.MG.dealPosts(squad, sq, L, walls, posts, wallPosts)
    if not squad.mg then return end
    local WALL_DIR = LF.Building.WALL_DIR
    local cell = getCell()
    local function holderOf(x, y)
        for rid, p in pairs(posts) do if p.x == x and p.y == y then return rid end end
        return nil
    end
    local function swap(rid, p)
        local h = holderOf(p.x, p.y)
        if h == rid then return end
        if h then posts[h] = posts[rid] end
        posts[rid] = p
    end
    -- How much road a window looks out on: road squares out to ~24 tiles in a fan out of it that
    -- can be seen from it.
    local RAYS = { -40, -20, 0, 20, 40 }
    local function roadView(p)
        local d = WALL_DIR[p.wall]
        local n = 0
        for _, deg in ipairs(RAYS) do
            local a = math.rad(deg)
            local rx, ry = d[1] * math.cos(a) - d[2] * math.sin(a), d[1] * math.sin(a) + d[2] * math.cos(a)
            for r = 3, 24, 3 do
                local x, y = math.floor(p.x + 0.5 + rx * r), math.floor(p.y + 0.5 + ry * r)
                local q = cell:getGridSquare(x, y, L.z)
                if q and LF.March.isRoad(q) and LF.Cover.canSeeFrom(p.x, p.y, L.z, LF.Tactics.point(x + 0.5, y + 0.5, L.z)) then
                    n = n + 1
                end
            end
        end
        return n
    end
    -- Every window, scored: facing the enemy first (the front wall, then the walls either side),
    -- then the most road in view.
    local WALL_SCORE = { [walls[1]] = 6, [walls[2]] = 3, [walls[4]] = 3, [walls[3]] = 0 }
    local cands = {}
    for w = 1, 4 do
        for _, p in ipairs(wallPosts(L, w)) do
            if p.kind == "window" then
                local rv = LF.guard("road view", roadView, p) or 0
                cands[#cands + 1] = { p = p, road = rv, score = (WALL_SCORE[w] or 0) + math.min(rv, 12) }
            end
        end
    end
    table.sort(cands, function(a, b) return a.score > b.score end)
    local taken = {}
    local k = 0
    for _, tid in ipairs(squad.teams) do
        local team = LF.Units.get(tid)
        if team and team.mg then
            k = k + 1
            local gr, ar = crew(team)
            -- The best window left - the second gun not right beside the first, and on another
            -- wall if one is as good.
            local pick, best = nil, -math.huge
            for _, c in ipairs(cands) do
                local ok = true
                for _, t in ipairs(taken) do
                    if LF.dist(c.p.x, c.p.y, t.p.x, t.p.y) < 3 then ok = false end
                end
                if ok then
                    local sc = c.score
                    for _, t in ipairs(taken) do if t.p.wall ~= c.p.wall then sc = sc + 2 end end
                    if sc > best then pick, best = c, sc end
                end
            end
            if gr and pick then
                taken[#taken + 1] = pick
                local win = pick.p
                swap(gr.id, win)
                if ar then
                    local d = WALL_DIR[win.wall]
                    local ix, iy = win.x - d[1], win.y - d[2]
                    if LF.Building.isInside(L, ix, iy) then
                        swap(ar.id, { x = ix, y = iy, wall = win.wall, stand = false, kind = "assist", any = true })
                    end
                end
                LF.log("MG " .. team.name .. " of " .. squad.name .. " takes the window at " .. win.x .. "," .. win.y
                    .. " (" .. LF.Building.WALL_NAME[win.wall] .. " wall, " .. pick.road .. " road squares in view)")
            elseif gr then
                LF.log("MG " .. team.name .. " of " .. squad.name .. ": no window left for the gun")
            end
        end
    end
end

-- ---- the enemy's view ---------------------------------------------------------------------------

-- Is this man the crew of a gun that is firing (or fired in the last ~10 s)?
function LF.MG.isFiring(id)
    for _, g in pairs(guns) do
        if (g.gunnerId == id or g.assistId == id) and (g.firing or LF.tick - (g.lastEnd or -100000) < CFG.firingMemory) then
            return true
        end
    end
    return false
end

-- The nearest firing gun hostile to `faction` within range of (x, y): its state (x, y, z), or nil.
function LF.MG.enemyGunNear(faction, x, y, range)
    local best, bd = nil, range * range
    for _, g in pairs(guns) do
        if g.x and LF.isHostile(faction, g.faction) and (g.firing or LF.tick - (g.lastEnd or -100000) < CFG.firingMemory) then
            local d = LF.distSq(g.x, g.y, x, y)
            if d < bd then best, bd = g, d end
        end
    end
    return best
end

-- An MG squad with nothing in sight backs up a friendly unit fighting close by: that unit's
-- contact (so it sets up and fires on the same enemy - the base of fire for the other's attack).
function LF.MG.supportContact(squad, cmd)
    if not squad.mg then return nil end
    local best, bd = nil, 50 * 50
    for _, u in pairs(LF.Units.all()) do
        if u.kind == "squad" and u.id ~= squad.id and u.faction == squad.faction then
            local s = LF.Tactics.state(u)
            local cid = LF.Units.commander(u)
            local cb = cid and LF.Bodies.get(cid)
            if s and s.intent and s.contact and cb then
                local d = LF.distSq(cb:getX(), cb:getY(), cmd:getX(), cmd:getY())
                if d < bd then best, bd = { u = u, c = s.contact }, d end
            end
        end
    end
    if not best then squad.supporting = nil; return nil end
    if squad.supporting ~= best.u.id then
        squad.supporting = best.u.id
        LF.log("MG " .. squad.name .. " supports " .. best.u.name .. ": firing on its contact at " .. math.floor(best.c.x) .. "," .. math.floor(best.c.y))
        LF.Tactics.shout(LF.Units.commander(squad), "Guns, support " .. best.u.name .. "!")
    end
    return best.c
end

-- ---- upkeep --------------------------------------------------------------------------------------

local function onTick()
    if not LF.due(30, 0) then return end
    for tid, g in pairs(guns) do
        local team = LF.Units.get(tid)
        if not team then
            guns[tid] = nil
        else
            g.teamName = team.name
            LF.guard("mg upkeep", upkeep, team)
            -- (0.73.2, diagnosis: set up, wanted, and not firing for 5 s - say what's holding it.)
            if g.set and not g.firing and LF.tick - (g.wantAt or -100000) < 60
                and LF.tick - math.max(g.lastEnd or -100000, g.setAt or -100000) > 300
                and LF.tick - (g.blockAt or -100000) > 300 then
                g.blockAt = LF.tick
                local gb = g.gunnerId and LF.Bodies.get(g.gunnerId)
                local q = gb and ISTimedActionQueue.getTimedActionQueue(gb)
                local a = q and q.queue and q.queue[1]
                LF.log("MG " .. team.name .. ": set up but not firing for 5 s - " .. tostring(g.block or "no fire step reached")
                    .. ", gunner's action " .. tostring(a and a.Type or "none"))
            end
            -- A job on the gun that never finished (he was knocked over, say): call it off.
            local s = g.service
            if s and s.kind ~= "cool" and LF.tick - s.since > (s.ticks or 300) * 2 + 120 then g.service = nil end
            if g.firing then
                local gb = g.gunnerId and LF.Bodies.get(g.gunnerId)
                local q = gb and ISTimedActionQueue.getTimedActionQueue(gb)
                local a = q and q.queue and q.queue[1]
                if not (a and a.Type == "LF_MGBurstAction") then g.firing = false end
            end
        end
    end
end
LF.on("OnTick", "MG", function() LF.guard("mg tick", onTick) end)

-- Every gun team's state, to the log (debug).
function LF.MG.report()
    local n = 0
    for tid, g in pairs(guns) do
        local team = LF.Units.get(tid)
        if team then
            n = n + 1
            local gr = g.gunnerId and LF.Records.get(g.gunnerId)
            local ar = g.assistId and LF.Records.get(g.assistId)
            LF.log("MG " .. team.name .. " (#" .. tid .. ", " .. g.faction .. "): gunner " .. title(gr) .. ", assistant " .. title(ar)
                .. ", set " .. tostring(g.set) .. ", firing " .. tostring(g.firing) .. ", belt " .. g.belt .. ", heat " .. fmt(heatNow(g))
                .. ", service " .. tostring(g.service and g.service.kind) .. ", spot " .. (g.spot and (g.spot.x .. "," .. g.spot.y) or "none"))
        end
    end
    LF.say(n .. " machine guns; report written to log")
end
