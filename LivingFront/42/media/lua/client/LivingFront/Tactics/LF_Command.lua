-- Living Front: tactics - command. The sergeant choosing his stance, standing a unit down to
-- standby when there's nothing to do, and the squad update that runs it all (LF_Tactics holds the
-- shared state; LF_Manoeuvre, LF_Defence and LF_Clearing the drills it calls on).

require "LivingFront/Tactics/LF_Tactics"
require "LivingFront/Tactics/LF_Manoeuvre"
require "LivingFront/Tactics/LF_Defence"
require "LivingFront/Tactics/LF_Clearing"

local I = LF.Tactics.I
local CFG, chooseShift, clearing, enemySuppression, facing, fit = I.CFG, I.chooseShift, I.clearing, I.enemySuppression, I.facing, I.fit
local initTeams, openDoor, otherSideFlanking, passOrders, planFlank, sergeantClear = I.initTeams, I.openDoor, I.otherSideFlanking, I.passOrders, I.planFlank, I.sergeantClear
local setIntent, shouts, squads, stalemate, teams, updateClear = I.setIntent, I.shouts, I.squads, I.stalemate, I.teams, I.updateClear
local updateDefensive = I.updateDefensive

-- ---- the sergeant chooses the stance --------------------------------------------------------
--
-- The enemy's strength is reckoned as the most his squad has known of at once in the last minute.
-- Offensive -> defensive ("Dig in!"), when:
--   outnumbered      - the enemy is 1.5x his fit men or more
--   heavy losses     - a third of the unit is down and the enemy isn't giving (little of him
--                      suppressed)
--   a building       - he is in or next to a building and the enemy is coming toward him
--   attack stalled   - two flanks and two repositions since, and still holding after a minute
-- He digs in where he stands - in the building if there is one (its nearest door is opened).
-- Defensive -> offensive ("Move up!"), when:
--   in the open      - 1.5x the known enemy in fit men, or no enemy seen for ~45 s
--   in a building    - only when no enemy has been seen for ~90 s: men at the windows don't leave
--                      a fight that is still going
-- A reason has to hold for ~3 s, he changes stance at most once a minute, and a stance set from
-- the debug menu stands for a minute too. LF.Tactics.autoStance turns it off.

LF.Tactics.autoStance = true
local stanceMem = {}        -- squad id -> { since, want, wantSince, lastContact, engaged, prevD }

function LF.Tactics.noteStanceSet(squad)
    stanceMem[squad.id] = { since = LF.tick }
end

-- A building within CFG.buildingNear of (x, y): its id and the square, or nil.
local function buildingNear(x, y, z)
    local bx, by = math.floor(x), math.floor(y)
    local id = LF.Building.idAt(bx, by, z)
    if id then return id, bx, by end
    for r = 1, CFG.buildingNear do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    id = LF.Building.idAt(bx + dx, by + dy, z)
                    if id then return id, bx + dx, by + dy end
                end
            end
        end
    end
    return nil
end

local function considerStance(squad, sq, cid, cmd)
    if not LF.Tactics.autoStance then return false end
    if LF.Objective and LF.Objective.busy(squad) then return false end   -- the task decides
    local mem = stanceMem[squad.id]
    if not mem then mem = { since = -100000 }; stanceMem[squad.id] = mem end
    local st = LF.Stance.get(squad)
    local contacts = LF.Squad.contactPoints(squad.id, CFG.contactMemory, 40)
    -- How many enemy he reckons there are: the most his squad has known of at once over the last
    -- minute (so a few men dropping out of sight don't make him think the enemy has gone).
    local seen = #contacts
    if seen > 0 then mem.lastContact, mem.engaged = LF.tick, true end
    if seen >= (mem.peak or 0) or LF.tick - (mem.peakAt or 0) > 3600 then mem.peak, mem.peakAt = seen, LF.tick end
    local enemies = mem.peak
    local total, fitN = 0, 0
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r then
            total = total + 1
            if fit(r) then fitN = fitN + 1 end
        end
    end
    if fitN == 0 then return false end
    local x, y, z = cmd:getX(), cmd:getY(), math.floor(cmd:getZ())
    local want, why = nil, nil
    if st.name ~= "defensive" then
        -- Nearest known enemy, and is he getting closer?
        local d = nil
        for _, c in ipairs(contacts) do
            local dd = LF.dist(x, y, c.x, c.y)
            if not d or dd < d then d = dd end
        end
        local coming = d and mem.prevD and d < mem.prevD - 1
        mem.prevD = d
        if enemies >= CFG.digInOdds * fitN then
            want, why = "defensive", "outnumbered: " .. enemies .. " enemy known against " .. fitN .. " fit"
        elseif seen > 0 and (total - fitN) / total >= CFG.lossShare and (sq.supShare or 0) < CFG.flankSuperiority then
            want, why = "defensive", "heavy losses: " .. fitN .. "/" .. total .. " fit, and the enemy isn't giving"
        elseif coming and buildingNear(x, y, z) then
            want, why = "defensive", "a building to hold and the enemy coming on"
        elseif seen > 0 and (sq.flankCount or 0) >= 2 and (sq.shiftsSinceFlank or 0) >= 2 and sq.intent == "HOLD"
            and LF.tick - (sq.holdSince or LF.tick) >= 3600 then
            want, why = "defensive", "the attack has stalled"
        end
    else
        local quiet = mem.engaged and (LF.tick - (mem.lastContact or LF.tick)) or 0
        if sq.perim and sq.perim.layout then
            if quiet >= CFG.quietBuilding then
                want, why = "offensive", "no enemy seen for " .. math.floor(quiet / 60) .. " s - the fight is over here"
            end
        elseif quiet >= CFG.quietOpen then
            want, why = "offensive", "no enemy seen for " .. math.floor(quiet / 60) .. " s - move up and find them"
        elseif enemies > 0 and fitN >= CFG.attackOdds * enemies then
            want, why = "offensive", "we have the numbers: " .. fitN .. " fit against " .. enemies .. " known"
        end
    end
    if want ~= mem.want then mem.want, mem.wantSince = want, LF.tick end
    if not want or LF.tick - mem.wantSince < CFG.stanceConfirm or LF.tick - mem.since < CFG.stanceCooldown then
        return false
    end
    -- Change stance. Digging in next to a building: into it, through its nearest door.
    local hold = nil
    if want == "defensive" then
        local id, hx, hy = buildingNear(x, y, z)
        if id then
            hold = { x = hx, y = hy, z = z }
            local L = LF.Building.at(hx, hy, z)
            if L then
                local best, bd = nil, math.huge
                for _, o in ipairs(L.openings) do
                    if o.kind == "door" then
                        local dd = LF.dist(x, y, o.x + 0.5, o.y + 0.5)
                        if dd < bd then best, bd = o, dd end
                    end
                end
                if best then
                    local cell = getCell()
                    local a = cell:getGridSquare(best.x, best.y, z)
                    local b = cell:getGridSquare(best.x + best.dx, best.y + best.dy, z)
                    local door = a and b and a:getDoorTo(b)
                    if door then LF.guard("open door", openDoor, door, cmd) end
                end
            end
        end
    end
    LF.log("STANCE " .. squad.name .. ": the " .. (squad.leader and "sergeant" or "corporal") .. " goes " .. want
        .. " (" .. why .. ")" .. (hold and " - into the building" or ""))
    LF.Tactics.setStance(squad, want, hold)
    stanceMem[squad.id] = { since = LF.tick }
    LF.Tactics.shout(cid, want == "offensive" and "On your feet - move up!"
        or (hold and "Into the building! Take the windows!" or "Dig in! All-round defence!"))
    return true
end

-- ---- standing by ------------------------------------------------------------------------------
--
-- A unit with nothing in particular to do stands by (LF_Stance "standby"): the men rest round
-- the leader. On contact it stands to (offensive). Any other unit stands down to it once it has
-- had no task, no march, no fight and no enemy in mind for CFG.standDownTicks; a team that walked
-- back after joining another unit stands by the moment it is back.
local function standDown(squad, sq, cid, cmd)
    local M = LF.March.get(squad.id)
    if squad.returning and M and M.arrived then
        local r = squad.returning
        squad.returning = nil
        if r.fx then squad.facingX, squad.facingY = r.fx, r.fy end
        LF.Tactics.setStance(squad, "standby")
        LF.Tactics.shout(cid, "Back in position. Stand easy.")
        LF.log("STANDBY " .. squad.name .. ": back where it was, standing by")
        return true
    end
    local busy = squad.objTask ~= nil or squad.platoonTask ~= nil or (M ~= nil and not M.arrived) or clearing(squad)
        or LF.Stance.get(squad).name == "defensive" or sq.intent ~= nil
        or LF.Squad.bestContact(squad.id, cmd:getX(), cmd:getY(), CFG.contactMemory, 60) ~= nil
    if busy then sq.busyAt = LF.tick; return false end
    sq.busyAt = sq.busyAt or LF.tick
    if LF.tick - sq.busyAt < CFG.standDownTicks then return false end
    LF.log("STANDBY " .. squad.name .. ": nothing to do - standing by")
    LF.Tactics.setStance(squad, "standby")
    LF.Tactics.shout(cid, "All quiet - stand easy. Stay sharp.")
    return true
end

local function updateSquad(squad)
    local cid = LF.Units.commander(squad)
    local cmd = cid and LF.Bodies.get(cid)
    local sq = squads[squad.id]
    if not sq then sq = {}; squads[squad.id] = sq end
    for _, tid in ipairs(squad.teams) do
        local t, team = teams[tid], LF.Units.get(tid)
        if t and t.clear and team then LF.guard("clear", updateClear, team, t, squad) end
        if t and t.inside and team then LF.guard("hold inside", LF.Tactics.updateInside, team, t, squad) end
    end
    -- Teams that joined this unit for a task go back once it's over.
    if squad.attached and LF.Join and LF.Join.taskOver(squad) then
        LF.guard("join release", LF.Join.release, squad, LF.Stance.get(squad).name == "standby" and "task over" or "objective taken")
        return
    end
    if squad.joined then return end                -- (its team is away with another unit)
    if cmd and not cmd:isDead() then
        if LF.Stance.get(squad).idle then
            -- Standing by: stand to on contact; otherwise nothing to order.
            local c0 = LF.Squad.bestContact(squad.id, cmd:getX(), cmd:getY(), CFG.contactMemory, CFG.contactRange)
            if c0 then
                LF.log("STANDBY " .. squad.name .. ": contact - stand to")
                LF.Tactics.setStance(squad, "offensive")
                LF.Tactics.shout(cid, "Stand to! Contact!")
            end
            return
        end
        if standDown(squad, sq, cid, cmd) then return end
    end
    if cmd and not cmd:isDead() and considerStance(squad, sq, cid, cmd) then return end
    if not cmd or cmd:isDead() then
        -- No commander here: each corporal runs his own team (offensive stance only - a defence
        -- just holds where it is). On the march the march goes on without him (LF_March, off-screen).
        if LF.March.get(squad.id) then return end
        if LF.Stance.get(squad).maneuvers then
            initTeams(squad)
            passOrders(squad, sq, nil)
        end
        return
    end
    if not LF.Stance.get(squad).maneuvers then return updateDefensive(squad, sq, cid, cmd) end
    -- On the march: the column moves on until it meets the enemy (or arrives).
    if LF.March.get(squad.id) then
        local c0 = LF.Squad.bestContact(squad.id, cmd:getX(), cmd:getY(), CFG.contactMemory, CFG.contactRange)
        if c0 or sq.intent then sq.quietSince = LF.tick end
        if LF.March.update(squad, cid, cmd, c0, LF.tick - (sq.quietSince or 0)) then return end
    end

    local c = LF.Squad.bestContact(squad.id, cmd:getX(), cmd:getY(), CFG.contactMemory, CFG.contactRange)
    -- Assaulting an objective with nobody in sight: the objective's windows are the target.
    if not c and LF.Objective then c = LF.Objective.fallbackContact(squad) end
    -- Supporting a platoon attack by fire with nobody in sight: the objective's windows.
    if not c and squad.sbf and LF.Platoon then c = LF.Platoon.supportContact(squad) end
    -- A machine-gun squad with nothing of its own backs up a friendly unit's fight close by.
    if not c and squad.mg and LF.MG then c = LF.MG.supportContact(squad, cmd) end
    if not c then
        if sq.intent then
            setIntent(squad, sq, cid, nil, "no contact")
            for _, tid in ipairs(squad.teams) do
                if not (teams[tid] and teams[tid].clear) then teams[tid] = nil end
            end
        end
        sq.fightStart = nil
        return
    end
    -- A fight has just broken out: no orders until the men have got their bearings.
    if not sq.intent then
        if not sq.fightStart then
            sq.fightStart = LF.tick
            LF.log("CONTACT " .. squad.name .. ": fight breaks out, every man returns fire and takes cover")
        end
        -- (A planned assault on an objective needs no bearings: the orders are already given.)
        local planned = LF.Objective and LF.Objective.planned(squad)
        if not planned and LF.tick - sq.fightStart < CFG.bearingsTicks then return end
    end
    if not sq.contact then sq.contact = LF.Tactics.point(c.x, c.y, c.z)
    else sq.contact.x, sq.contact.y, sq.contact.z = c.x, c.y, c.z end
    -- The squad's front is toward the enemy: advances, flanks and formations go that way (not
    -- along whatever road the patrol last walked). Turned only when it is ~25 degrees off.
    do
        local dx, dy = c.x - cmd:getX(), c.y - cmd:getY()
        local d = math.sqrt(dx * dx + dy * dy)
        if d > 4 then
            dx, dy = dx / d, dy / d
            local fx, fy = facing(squad)
            if dx * fx + dy * fy < 0.9 then squad.facingX, squad.facingY = dx, dy end
        end
    end

    initTeams(squad)

    -- How the unit stands.
    local total, fitN, pinnedN = 0, 0, 0
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r then
            total = total + 1
            if fit(r) then
                fitN = fitN + 1
                local b = LF.Bodies.get(rid)
                if b and LF.Suppress.isPinned(b) then pinnedN = pinnedN + 1 end
            end
        end
    end
    -- (Only teams with a fit man left count: a team whose men are all down in the building it was
    -- clearing isn't the squad's front - up to 0.43 the squad, measuring from them, fell back and
    -- back, and its last teams bounded away across the map.)
    local front = math.huge
    for _, tid in ipairs(squad.teams) do
        local t = teams[tid]
        local team = LF.Units.get(tid)
        local anyFit = false
        for _, rid in ipairs(team and team.members or {}) do
            local r = LF.Records.get(rid)
            if r and r.team == tid and fit(r) and LF.Bodies.get(rid) then anyFit = true; break end
        end
        if t and anyFit then
            for _, p in pairs(t.pos) do
                local d = LF.dist(p.x, p.y, c.x, c.y)
                if d < front then front = d end
            end
        end
    end

    -- Fire superiority: how much of the enemy near the contact this squad has suppressed
    -- (kept, so enemy squads can compare in a stalemate).
    local supp, enemies = enemySuppression(squad, c)
    sq.supShare = enemies > 0 and supp / enemies or 0

    local intent = sq.intent
    local why
    -- (A squad in good heart hangs on longer before it falls back; a shaken one goes sooner.)
    local fallbackFit = LF.Morale and LF.Morale.fallbackShare(squad, CFG.fallbackFit) or CFG.fallbackFit
    if total > 0 and fitN / total < fallbackFit then
        if not sq.broken and LF.Service then LF.guard("service broke", LF.Service.unitBroke, squad) end
        sq.broken = true
        -- Once out of range, he only falls back again if the enemy comes on (6 tiles closer) -
        -- not back and forth every second on the edge of range.
        local clearDist = CFG.fallbackClear - (intent == "HOLD" and 6 or 0)
        if front < clearDist then intent, why = "FALLBACK", fitN .. "/" .. total .. " fit"
        else intent, why = "HOLD", "fallen back out of range" end
    elseif intent ~= "HOLD" and intent ~= "FLANK" and fitN > 0 and pinnedN / fitN >= CFG.pinnedHold then
        -- Too many men pinned to keep advancing. (A squad already holding still goes on to the
        -- flank checks below, and a flank under way carries on.)
        intent, why = "HOLD", pinnedN .. "/" .. fitN .. " pinned"
    elseif intent == "FLANK" then
        -- Carry on until every flanking team is in position (or it takes too long).
        local done = true
        for _, tid in ipairs(sq.flank and sq.flank.teams or {}) do
            local t = teams[tid]
            local team = LF.Units.get(tid)
            local cpl = team and team.leader and LF.Bodies.get(team.leader)
            if t and cpl and not cpl:isDead() and not t.maneuverDone then done = false end
        end
        if done then intent, why = "HOLD", "flankers in position"
        elseif sq.flank and LF.tick - sq.flank.started > CFG.flankTimeout then intent, why = "HOLD", "flank took too long" end
    elseif intent == "HOLD" and squad.leader and not squad.supportOnly and front <= CFG.advanceResume and not clearing(squad)
        and LF.tick - (sq.holdSince or LF.tick) >= CFG.flankMinHold
        and LF.tick - (sq.lastFlank or -100000) >= CFG.flankCooldown
        and total > 0 and fitN / total >= CFG.flankFit
        and not otherSideFlanking(squad.faction) then
        local reason = nil
        local steady = fitN == 0 or pinnedN / fitN < CFG.flankPinned
        local t = squad.objTask
        -- An enemy machine gun firing on us: the alpha teams go round and take it.
        local gun = LF.MG and LF.MG.enemyGunNear(squad.faction, cmd:getX(), cmd:getY(), CFG.stalemateRadius)
        local flankAt = c
        if gun and pinnedN > 0 and LF.tick - (sq.lastGunFlank or -100000) >= CFG.flankCooldown then
            reason = "an enemy machine gun has us pinned (" .. pinnedN .. " men) - flank it"
            flankAt = LF.Tactics.point(gun.x, gun.y, gun.z or 0)
            sq.lastGunFlank = LF.tick
        elseif t and t.kind == "take" and t.phase == "assault" and not sq.objFlank then
            sq.objFlank = true
            reason = "assaulting the objective: alpha teams round the flank, bravo teams the base of fire"
        elseif steady and enemies > 0 and sq.supShare >= CFG.flankSuperiority then
            reason = "fire superiority: " .. supp .. "/" .. enemies .. " enemy suppressed"
        else
            local ok, enemyBest = stalemate(squad, sq, cmd:getX(), cmd:getY())
            if ok then
                reason = string.format("stalemate: our fire superiority %.0f%% vs theirs %.0f%%",
                    sq.supShare * 100, enemyBest * 100)
            end
        end
        if reason then
            local plan = planFlank(squad, flankAt, sq)
            if plan then
                plan.gun = flankAt ~= c or nil
                sq.flank = plan
                sq.flankStartTick = LF.tick
                sq.shiftsSinceFlank = 0
                intent, why = "FLANK", reason
            else
                sq.lastFlank = LF.tick
            end
        end
    elseif intent == "ADVANCE" and front <= CFG.advanceStop then
        intent, why = "HOLD", "in range (" .. math.floor(front) .. " tiles)"
    elseif intent ~= "ADVANCE" and front > CFG.advanceResume and not sq.broken
        and not (fitN > 0 and pinnedN / fitN >= CFG.pinnedHold) then
        intent, why = "ADVANCE", "enemy at " .. math.floor(front) .. " tiles"
    elseif not intent then
        intent, why = "HOLD", "contact at " .. math.floor(front) .. " tiles"
    end
    -- A platoon's support squad holds its fire position: it doesn't advance or flank (LF_Platoon).
    if squad.supportOnly and (intent == "ADVANCE" or intent == "FLANK") then
        intent, why = "HOLD", "supporting by fire from here"
    end
    -- Ordered to withdraw: back by bounds until out of range (then the platoon marches it off).
    if squad.withdrawTo then
        if front < CFG.fallbackClear + 4 then intent, why = "FALLBACK", "withdrawing on the lieutenant's order"
        else intent, why = "HOLD", "out of range - withdrawing" end
    end
    setIntent(squad, sq, cid, intent, why or "")

    -- A building with only a few of the enemy left in it: send Alpha in.
    if intent == "HOLD" and not squad.supportOnly and not squad.withdrawTo and fitN > 0 and pinnedN / fitN < CFG.pinnedHold then sergeantClear(squad, sq, cid) end
    -- Pass it on (corporals out of earshot act on their own), then the drills.
    passOrders(squad, sq, cmd)
    chooseShift(squad, sq)
    -- A grenade, if it could decide the fight (LF_Grenade).
    if LF.Grenade then LF.guard("grenade", LF.Grenade.consider, squad, sq) end
end

local function onTick()
    if LF.tick % CFG.updateTicks ~= 0 then return end
    for _, u in pairs(LF.Units.all()) do
        if u.kind == "squad" then LF.guard("tactics", updateSquad, u) end
    end
end

Events.OnTick.Add(onTick)

function LF.Tactics.forgetAll()
    for _, t in ipairs({ squads, teams, shouts }) do
        for k in pairs(t) do t[k] = nil end
    end
end
Events.OnInitGlobalModData.Add(function() LF.Tactics.forgetAll() end)

-- ---- shared with the other tactics files ----------------------------------------------------
I.buildingNear = buildingNear
