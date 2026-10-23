-- Living Front: standing-by fire teams join a unit that is given a task.
--
-- When a unit gets an assignment (a patrol, an objective to take, a building to hold), any fire
-- team of the same side
-- that is standing by within CFG.radius of its leader joins it: the team becomes one more team of
-- that unit (in a free formation slot - Bravo 1 first, so a lone team that gains a second has a
-- base of fire) and goes wherever it goes, under its leader. When the task is over - the unit
-- stands down, or it has taken its objective and is holding it (a defence keeps its helpers
-- until it stands down) - the joined teams leave again, walk back to where they were, and stand
-- by there.
--
-- Only lone fire teams join (a full squad has no free slots and is too big to tag along), and a
-- unit takes at most four teams in all.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Units"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_Stance"

LF.Join = LF.Join or {}

local CFG = {
    radius = 20,            -- a standing-by team this close to the unit's leader joins it
    slotOrder = { 3, 2, 4, 1 },
}
LF.Join.CFG = CFG

local function commanderBody(squad)
    local cid = LF.Units.commander(squad)
    return cid and LF.Bodies.get(cid), cid
end

local function forgetTactics(squad)
    if LF.Tactics and LF.Tactics.forgetUnit then LF.Tactics.forgetUnit(squad) end
end

local function canJoin(u, lead)
    if u.id == lead.id or u.kind ~= "squad" or u.faction ~= lead.faction then return false end
    if not u.teamOnly or u.joined or u.attached or #u.teams ~= 1 then return false end
    if LF.Stance.get(u).name ~= "standby" or u.objTask then return false end
    if LF.March and LF.March.get(u.id) then return false end
    return true
end

local function merge(lead, u, slot, home)
    local T = LF.Units.get(u.teams[1])
    if not T then return false end
    local S = LF.Units.TEAM_SLOTS[slot]
    u.joined, u.joinTeam = lead.id, T.id
    u.joinHome = home
    u.joinWas = { slot = T.slot, element = T.element, name = T.name }
    T.squad, T.slot, T.element, T.name = lead.id, slot, S.element, S.name
    lead.teams[#lead.teams + 1] = T.id
    if lead.teamOnly then
        lead.teamOnly, lead.wasTeamOnly, lead.cmdFromTeam = nil, true, true
    end
    u.teams = {}
    for _, rid in ipairs(T.members) do
        local r = LF.Records.get(rid)
        if r then r.squad = lead.id end
    end
    lead.attached = lead.attached or {}
    lead.attached[#lead.attached + 1] = u.id
    LF.Units.dirty(lead.id)
    LF.Units.dirty(u.id)
    forgetTactics(lead)
    forgetTactics(u)
    return true
end

-- A unit is about to be given a task: standing-by teams nearby join it first.
-- purpose: "patrol", "take" or "defend" (a defence keeps its helpers until it stands down).
function LF.Join.gather(lead, purpose)
    if not lead or lead.kind ~= "squad" or lead.joined then return 0 end
    local lb = commanderBody(lead)
    if not lb then return 0 end
    local used = {}
    for _, tid in ipairs(lead.teams) do
        local t = LF.Units.get(tid)
        if t then used[lead.teamOnly and 1 or t.slot] = true end
    end
    local cands = {}
    for _, u in pairs(LF.Units.all()) do
        if canJoin(u, lead) then
            local ub = commanderBody(u)
            if ub then
                local d = LF.dist(ub:getX(), ub:getY(), lb:getX(), lb:getY())
                if d <= CFG.radius then cands[#cands + 1] = { u = u, d = d, b = ub } end
            end
        end
    end
    table.sort(cands, function(a, b) return a.d < b.d end)
    local n = 0
    for _, c in ipairs(cands) do
        local slot = nil
        for _, s in ipairs(CFG.slotOrder) do
            if not used[s] then slot = s; break end
        end
        if not slot then break end
        local home = { x = c.b:getX(), y = c.b:getY(), z = c.b:getZ(), fx = c.u.facingX, fy = c.u.facingY }
        if merge(lead, c.u, slot, home) then
            used[slot] = true
            n = n + 1
            LF.log("JOIN " .. c.u.name .. " joins " .. lead.name .. " as " .. LF.Units.TEAM_SLOTS[slot].name)
            local ucid = LF.Units.commander(c.u) or (LF.Units.get(c.u.joinTeam) or {}).leader
            if ucid and LF.Tactics then
                local lr = LF.Records.get(LF.Units.commander(lead))
                LF.Tactics.shout(ucid, "We'll come with you" .. (lr and (", " .. LF.Units.title(lr)) or "") .. "!")
            end
        end
    end
    if n > 0 and not lead.attachedFor then lead.attachedFor = purpose or "patrol" end
    return n
end

-- Ordered to help: fire team u joins unit lead now, wherever it is (it walks over as part of
-- lead). Returns true if it joined; false (and why) if it can't - a full squad, a unit that is
-- itself attached or has others attached, or no free slot.
function LF.Join.attach(lead, u, purpose)
    if u.id == lead.id or u.faction ~= lead.faction then return false, "not the same side" end
    if not u.teamOnly or #u.teams ~= 1 then return false, "only a fire team can join another unit" end
    if u.joined or u.attached then return false, u.name .. " is already part of another unit" end
    local used = {}
    for _, tid in ipairs(lead.teams) do
        local t = LF.Units.get(tid)
        if t then used[lead.teamOnly and 1 or t.slot] = true end
    end
    local slot = nil
    for _, sl in ipairs(CFG.slotOrder) do if not used[sl] then slot = sl; break end end
    if not slot then return false, lead.name .. " has no room for another team" end
    if LF.March then LF.March.cancel(u.id) end
    u.objTask = nil
    local ub = commanderBody(u)
    local home = ub and { x = ub:getX(), y = ub:getY(), z = ub:getZ(), fx = u.facingX, fy = u.facingY } or nil
    if not merge(lead, u, slot, home) then return false, "its team is gone" end
    if not lead.attachedFor then lead.attachedFor = purpose or "defend" end
    LF.log("JOIN " .. u.name .. " ordered to join " .. lead.name .. " as " .. LF.Units.TEAM_SLOTS[slot].name)
    return true
end

-- The task is over: the joined teams go back to their own units, walk back to where they were,
-- and stand by there.
function LF.Join.release(lead, why)
    local list = lead.attached
    if not list then return end
    lead.attached, lead.attachedFor = nil, nil
    for _, uid in ipairs(list) do
        local u = LF.Units.get(uid)
        local T = u and LF.Units.get(u.joinTeam)
        if u and T then
            for i = #lead.teams, 1, -1 do
                if lead.teams[i] == T.id then table.remove(lead.teams, i) end
            end
            local was = u.joinWas or {}
            T.squad, T.slot, T.element, T.name = u.id, was.slot or 1, was.element or "A", was.name or "Alpha 1"
            for _, rid in ipairs(T.members) do
                local r = LF.Records.get(rid)
                if r then r.squad = u.id end
            end
            u.teams = { T.id }
            local home = u.joinHome
            u.joined, u.joinTeam, u.joinWas, u.joinHome = nil, nil, nil, nil
            LF.Units.dirty(u.id)
            forgetTactics(u)
            LF.log("JOIN " .. u.name .. " leaves " .. lead.name .. (why and (" (" .. why .. ")") or "")
                .. (home and (", back to " .. math.floor(home.x) .. "," .. math.floor(home.y)) or ""))
            -- Back to where they were, then stand by there.
            local ub, ucid = commanderBody(u)
            local sent = false
            if home and ub and LF.dist(ub:getX(), ub:getY(), home.x, home.y) > 6 and LF.March then
                u.returning = { fx = home.fx, fy = home.fy }
                local ok = LF.March.order(u, math.floor(home.x), math.floor(home.y), math.floor(home.z or 0), "auto", { noGather = true })
                sent = ok and true or false
                if not sent then u.returning = nil end
            end
            if not sent and LF.Tactics then
                if home and home.fx then u.facingX, u.facingY = home.fx, home.fy end
                LF.Tactics.setStance(u, "standby")
            end
            if ucid and LF.Tactics then LF.Tactics.shout(ucid, sent and "Good work - back to our position." or "Stand easy.") end
        end
    end
    if lead.wasTeamOnly and #lead.teams == 1 then
        lead.teamOnly, lead.wasTeamOnly, lead.cmdFromTeam = true, nil, nil
        local t = LF.Units.get(lead.teams[1])
        if t then t.slot = 1 end
    end
    LF.Units.dirty(lead.id)
    forgetTactics(lead)
end

-- Is the lead unit's task over (so the joined teams can go)?
function LF.Join.taskOver(lead)
    if not lead.attached then return false end
    if LF.Stance.get(lead).name == "standby" then return true end
    if lead.attachedFor == "defend" then return false end      -- helping hold it: stay till it's over
    local t = lead.objTask
    return t ~= nil and t.kind == "hold"
end
