-- Living Front: military units (squads and fire teams).
--
-- Structure (see the squad tactics design doc): every unit is a leader plus two alpha elements
-- (nearer the front) and two bravo elements (the rear).
--   team  = corporal + 3 privates; its elements are individual soldiers (A A B B)
--   squad = sergeant + 4 teams; its elements are teams (Alpha 1, Alpha 2, Bravo 1, Bravo 2)
-- Platoons and companies come later, with the war layer.
--
-- Units are saved alongside the NPC records (global ModData, key "units"). Each soldier's record
-- carries its place: squad, team, rank, element and slot. Unit membership does not change when a
-- soldier dies; the record's alive flag says who is left.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"

LF.Units = LF.Units or {}

LF.Units.RANKS = { PVT = "Private", CPL = "Corporal", SGT = "Sergeant" }
local RANK_SHORT = { PVT = "Pvt.", CPL = "Cpl.", SGT = "Sgt." }

local function units()
    local data = LF.Records.data()
    if not data.units then data.units = {} end
    if not data.nextUnitId then data.nextUnitId = 1 end
    return data
end

local function newUnit(fields)
    local data = units()
    local id = data.nextUnitId
    data.nextUnitId = id + 1
    fields.id = id
    data.units[id] = fields
    return fields
end

function LF.Units.get(id)
    return id and units().units[id] or nil
end

function LF.Units.all()
    return units().units
end

local memberCache = {}     -- squad id -> array of record ids (runtime only)

function LF.Units.clear()
    local data = units()
    data.units = {}
    data.nextUnitId = 1
    memberCache = {}
end

Events.OnInitGlobalModData.Add(function() memberCache = {} end)

-- Remove squads (and their teams) with nobody left alive. Returns how many were removed.
function LF.Units.pruneDead()
    local data = units()
    local removed = 0
    for id, squad in pairs(data.units) do
        if squad.kind == "squad" then
            local anyAlive = false
            for _, rid in ipairs(LF.Units.members(id)) do
                local r = LF.Records.get(rid)
                if r and r.alive then anyAlive = true; break end
            end
            if not anyAlive then
                for _, tid in ipairs(squad.teams) do data.units[tid] = nil end
                data.units[id] = nil
                memberCache[id] = nil
                removed = removed + 1
            end
        end
    end
    return removed
end

-- "Sgt. Hans Becker" for soldiers, the plain name for everyone else.
function LF.Units.title(rec)
    local short = rec.rank and RANK_SHORT[rec.rank]
    return (short and (short .. " ") or "") .. LF.Records.fullName(rec)
end

-- How many squads this faction has had, for naming.
local function nextSquadNumber(faction)
    local n = 0
    for _, u in pairs(units().units) do
        if u.kind == "squad" and u.faction == faction then n = n + 1 end
    end
    return n + 1
end

-- The nearest free square to (x, y) within 2 tiles, so nobody is placed inside a wall.
local function freeSpot(x, y, z)
    local cell = getCell()
    for r = 0, 2 do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local sq = cell:getGridSquare(math.floor(x) + dx, math.floor(y) + dy, z)
                    if sq and sq:isFree(false) then return sq:getX() + 0.5, sq:getY() + 0.5 end
                end
            end
        end
    end
    return x, y
end

-- Formation offsets, in tiles: forward (toward the enemy), lateral (to the right of forward).
-- Teams sit in a box around the sergeant: alphas forward, bravos back, 1s left, 2s right.
local TEAM_SLOTS = {
    { name = "Alpha 1", element = "A", fwd = 3, lat = -5 },
    { name = "Alpha 2", element = "A", fwd = 3, lat = 5 },
    { name = "Bravo 1", element = "B", fwd = -3, lat = -5 },
    { name = "Bravo 2", element = "B", fwd = -3, lat = 5 },
}
-- Inside a team: A A in front, B B behind; the corporal takes the second alpha slot.
local MAN_SLOTS = {
    { element = "A", fwd = 1, lat = -1.5 },
    { element = "A", fwd = 1, lat = 1.5, leader = true },
    { element = "B", fwd = -1, lat = -1.5 },
    { element = "B", fwd = -1, lat = 1.5 },
}

local function placeSoldier(faction, x, y, z, fields)
    local px, py = freeSpot(x, y, z)
    local rec = LF.Records.create({ faction = faction, x = px, y = py, z = z })
    for k, v in pairs(fields) do rec[k] = v end
    return rec
end

-- Who commands this unit: the squad leader, or for a lone fire team, its corporal.
function LF.Units.commander(squad)
    if squad.leader then return squad.leader end
    if squad.teamOnly then
        local team = LF.Units.get(squad.teams[1])
        return team and team.leader
    end
    return nil
end

-- Create a full squad (17 soldiers) centred on (x, y), facing the direction (fx, fy).
-- With teamOnly, a lone fire team (4 soldiers, led by its corporal) instead.
-- Returns the squad unit (a lone team is stored as a squad with one team and no sergeant).
function LF.Units.createSquad(faction, x, y, z, fx, fy, teamOnly)
    local len = math.sqrt(fx * fx + fy * fy)
    if len < 0.01 then fx, fy, len = 1, 0, 1 end
    fx, fy = fx / len, fy / len
    local rx, ry = -fy, fx          -- right of forward on the map grid (y points south)
    local function at(fwd, lat) return x + fx * fwd + rx * lat, y + fy * fwd + ry * lat end

    local squad = newUnit({ kind = "squad", faction = faction, teams = {}, teamOnly = teamOnly or nil,
        name = faction .. (teamOnly and " team " or " squad ") .. nextSquadNumber(faction), facingX = fx, facingY = fy })

    local sgt = nil
    if not teamOnly then
        local sx, sy = at(0, 0)
        sgt = placeSoldier(faction, sx, sy, z, { squad = squad.id, rank = "SGT", element = "L", slot = 0 })
        squad.leader = sgt.id
    end

    for ti, ts in ipairs(TEAM_SLOTS) do
        if teamOnly and ti > 1 then break end
        local tf, tl = ts.fwd, ts.lat
        if teamOnly then tf, tl = 0, 0 end      -- a lone team is centred on the spot
        local team = newUnit({ kind = "team", faction = faction, squad = squad.id, name = ts.name,
            element = ts.element, slot = ti, members = {} })
        squad.teams[ti] = team.id
        for mi, ms in ipairs(MAN_SLOTS) do
            local mx, my = at(tf + ms.fwd, tl + ms.lat)
            local rec = placeSoldier(faction, mx, my, z, { squad = squad.id, team = team.id,
                rank = ms.leader and "CPL" or "PVT", element = ms.element, slot = mi })
            team.members[mi] = rec.id
            if ms.leader then team.leader = rec.id end
        end
    end
    LF.log("UNITS created " .. squad.name .. " (#" .. squad.id .. ") at " .. math.floor(x) .. "," .. math.floor(y)
        .. " facing " .. string.format("%.1f,%.1f", fx, fy) .. ", led by "
        .. LF.Units.title(LF.Records.get(LF.Units.commander(squad))))
    return squad
end

-- Log every unit: who leads it and who is still alive.
function LF.Units.report()
    local squads = 0
    for _, squad in pairs(LF.Units.all()) do
        if squad.kind == "squad" then
            squads = squads + 1
            local lead = LF.Records.get(squad.leader)
            local alive, total = 0, squad.leader and 1 or 0
            if lead and lead.alive then alive = 1 end
            local lines = {}
            for _, teamId in ipairs(squad.teams) do
                local team = LF.Units.get(teamId)
                if team then
                    local names = {}
                    for _, rid in ipairs(team.members) do
                        local rec = LF.Records.get(rid)
                        total = total + 1
                        if rec then
                            if rec.alive then alive = alive + 1 end
                            names[#names + 1] = rec.element .. ":" .. LF.Units.title(rec) .. (rec.alive and "" or " (dead)")
                        end
                    end
                    lines[#lines + 1] = "  " .. team.name .. ": " .. table.concat(names, ", ")
                end
            end
            LF.log("UNIT " .. squad.name .. " (#" .. squad.id .. ") " .. alive .. "/" .. total .. " alive, leader "
                .. (lead and (LF.Units.title(lead) .. (lead.alive and "" or " (dead)")) or "none"))
            for _, line in ipairs(lines) do LF.log(line) end
        end
    end
    LF.say(squads .. " squads; unit report written to log")
end

-- ---- membership and formation -------------------------------------------------------------

-- Every record id in a squad: its current leader first, then the team members (dead included;
-- check rec.alive).
function LF.Units.members(squadId)
    local list = memberCache[squadId]
    if list then return list end
    local squad = LF.Units.get(squadId)
    list = {}
    if squad then
        local inList = {}
        if squad.leader then list[1] = squad.leader; inList[squad.leader] = true end
        for _, teamId in ipairs(squad.teams) do
            local team = LF.Units.get(teamId)
            if team then
                for _, rid in ipairs(team.members) do
                    if not inList[rid] then list[#list + 1] = rid; inList[rid] = true end
                end
            end
        end
    end
    memberCache[squadId] = list
    return list
end

-- A soldier's formation slot relative to his squad leader: forward, lateral (tiles).
function LF.Units.slotOffset(rec)
    if rec.rank == "SGT" or not rec.team then return 0, 0 end
    local team = LF.Units.get(rec.team)
    local ts = team and TEAM_SLOTS[team.slot]
    local ms = MAN_SLOTS[rec.slot]
    if not (ts and ms) then return 0, 0 end
    return ts.fwd + ms.fwd, ts.lat + ms.lat
end

-- A soldier's sideways place within his pair (tiles; negative = left).
function LF.Units.slotLat(rec)
    local ms = MAN_SLOTS[rec.slot]
    return ms and ms.lat or 0
end

-- ---- succession -----------------------------------------------------------------------------

local function promote(rec, rank, why)
    local was = rec.rank
    rec.rank = rank
    local body = LF.Bodies and LF.Bodies.get(rec.id)
    if body then
        local name = LF.Units.title(rec)
        LF.try("rename on promotion", function()
            body:setDisplayName(name)
            body:setUsername(name)
            return true
        end)
    end
    LF.log("PROMOTED " .. LF.Records.fullName(rec) .. " #" .. rec.id .. " " .. tostring(was) .. " -> " .. rank .. " (" .. why .. ")")
end

-- Health below which a leader hands over command (kept equal to the brain's flee threshold).
LF.Units.woundedHealth = 35

-- Can this man take command? Alive, not relieved for wounds, and not badly hurt right now.
local function able(r)
    if not (r and r.alive and not r.wounded) then return false end
    local body = LF.Bodies and LF.Bodies.get(r.id)
    if body and LF.Combat and LF.Combat.health(body) < LF.Units.woundedHealth then return false end
    return true
end

-- Give a team a new corporal: the first able private, alphas first.
local function refillTeam(team, why)
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and r.rank == "PVT" and r.team == team.id and able(r) then
            promote(r, "CPL", why)
            team.leader = r.id
            return r
        end
    end
    team.leader = nil
    LF.log("UNITS " .. team.name .. " (#" .. team.id .. ") has no one fit to lead it")
    return nil
end

-- Does this soldier currently lead a team or the squad?
function LF.Units.leads(rec)
    local squad = rec.squad and LF.Units.get(rec.squad)
    if squad and squad.leader == rec.id then return true end
    local team = rec.team and LF.Units.get(rec.team)
    return team ~= nil and team.leader == rec.id
end

-- rec stops leading (killed, or relieved for wounds): the next man in line takes over.
-- Returns false if nobody was fit to take over (a relieved leader then keeps command).
local function handOver(rec, why)
    if not rec.squad then return true end
    local team = rec.team and LF.Units.get(rec.team)
    if team and team.leader == rec.id then refillTeam(team, why) end

    local squad = LF.Units.get(rec.squad)
    if not (squad and squad.leader == rec.id) then return true end
    -- First able corporal, team by team; failing that, any able soldier.
    local new, fromTeam = nil, nil
    for _, teamId in ipairs(squad.teams) do
        local t = LF.Units.get(teamId)
        local r = t and t.leader and LF.Records.get(t.leader)
        if r and r.id ~= rec.id and able(r) then new, fromTeam = r, t; break end
    end
    if not new then
        for _, rid in ipairs(LF.Units.members(squad.id)) do
            local r = LF.Records.get(rid)
            if r and r.id ~= rec.id and able(r) then new, fromTeam = r, LF.Units.get(r.team); break end
        end
    end
    if not new then
        if rec.alive then return false end
        squad.leader = nil
        LF.log("UNITS " .. squad.name .. " has no one left to lead it")
        return true
    end
    local oldSlot = new.slot
    promote(new, "SGT", why)
    new.team, new.element, new.slot = nil, "L", 0
    squad.leader = new.id
    if fromTeam then
        if rec.alive then
            -- The relieved sergeant takes his successor's old place in that team.
            for i, rid in ipairs(fromTeam.members) do
                if rid == new.id then fromTeam.members[i] = rec.id end
            end
            local ms = MAN_SLOTS[oldSlot]
            rec.team, rec.slot, rec.element = fromTeam.id, oldSlot, ms and ms.element or "B"
        end
        if fromTeam.leader == new.id then refillTeam(fromTeam, fromTeam.name .. " corporal moved up to lead the squad") end
    end
    memberCache[squad.id] = nil
    return true
end

-- Called when a soldier dies.
function LF.Units.onDeath(rec)
    handOver(rec, LF.Units.title(rec) .. " killed")
end

-- A leader so badly wounded that he seeks cover hands over command at once, rather than his
-- men waiting on him. He stays with the squad as an ordinary member. Returns true if relieved.
function LF.Units.relieve(rec)
    if rec.wounded or not LF.Units.leads(rec) then return false end
    local who = LF.Units.title(rec)
    rec.wounded = true
    if not handOver(rec, who .. " too badly wounded to lead") then
        rec.wounded = nil
        return false
    end
    LF.log("RELIEVED " .. who .. " #" .. rec.id .. " hands over command (badly wounded)")
    return true
end
