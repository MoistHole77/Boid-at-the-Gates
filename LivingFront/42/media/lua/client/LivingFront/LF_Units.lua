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
local RANK_SHORT = { PVT = "Pte.", CPL = "Cpl.", SGT = "Sgt." }

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

function LF.Units.clear()
    local data = units()
    data.units = {}
    data.nextUnitId = 1
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

-- Create a full squad (17 soldiers) centred on (x, y), facing the direction (fx, fy).
-- Returns the squad unit.
function LF.Units.createSquad(faction, x, y, z, fx, fy)
    local len = math.sqrt(fx * fx + fy * fy)
    if len < 0.01 then fx, fy, len = 1, 0, 1 end
    fx, fy = fx / len, fy / len
    local rx, ry = -fy, fx          -- right of forward on the map grid (y points south)
    local function at(fwd, lat) return x + fx * fwd + rx * lat, y + fy * fwd + ry * lat end

    local squad = newUnit({ kind = "squad", faction = faction, teams = {},
        name = faction .. " squad " .. nextSquadNumber(faction), facingX = fx, facingY = fy })

    local sx, sy = at(0, 0)
    local sgt = placeSoldier(faction, sx, sy, z, { squad = squad.id, rank = "SGT", element = "L", slot = 0 })
    squad.leader = sgt.id

    for ti, ts in ipairs(TEAM_SLOTS) do
        local team = newUnit({ kind = "team", faction = faction, squad = squad.id, name = ts.name,
            element = ts.element, slot = ti, members = {} })
        squad.teams[ti] = team.id
        for mi, ms in ipairs(MAN_SLOTS) do
            local mx, my = at(ts.fwd + ms.fwd, ts.lat + ms.lat)
            local rec = placeSoldier(faction, mx, my, z, { squad = squad.id, team = team.id,
                rank = ms.leader and "CPL" or "PVT", element = ms.element, slot = mi })
            team.members[mi] = rec.id
            if ms.leader then team.leader = rec.id end
        end
    end
    LF.log("UNITS created " .. squad.name .. " (#" .. squad.id .. ") at " .. math.floor(x) .. "," .. math.floor(y)
        .. " facing " .. string.format("%.1f,%.1f", fx, fy) .. ", led by " .. LF.Units.title(sgt))
    return squad
end

-- Log every unit: who leads it and who is still alive.
function LF.Units.report()
    local squads = 0
    for _, squad in pairs(LF.Units.all()) do
        if squad.kind == "squad" then
            squads = squads + 1
            local lead = LF.Records.get(squad.leader)
            local alive, total = 0, 1
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
