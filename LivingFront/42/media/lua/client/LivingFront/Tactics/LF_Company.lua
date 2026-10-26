-- Living Front: companies and the company headquarters (roadmap phase 5, step C2).
--
-- A company is two or three platoons under a captain. Its headquarters is a squad-sized element
-- (a squad unit marked companyHQ, so the squads' formations, marching and holding a building all
-- work for it):
--   Capt.    company commander         (the squad's leader)   greatcoat and peaked cap, no weapon
--   1stSgt.  company first sergeant    } the staff team       peaked cap, no weapon
--   Lt.      executive officer         }                      greatcoat and helmet
--   Cpl.     radio operator            }                      field radio
--   Sgt.     surgeon                   }                      white apron, no weapon
--   (a sixth billet, to come)
--   a 4-man security fire team: a corporal and three privates, armed as usual
-- What each billet does comes later; for now they are there, dressed and in place.
-- A new company takes the nearest platoons of its side that have no company yet (up to
-- CFG.platoons, within CFG.adopt tiles).

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"

LF.Company = LF.Company or {}

local CFG = {
    platoons = 3,           -- platoons a company takes
    adopt = 400,            -- tiles: how far off they may be
}
LF.Company.CFG = CFG

-- The staff, in their places in the staff team (team slots 1-4, as a fire team's men stand).
-- (A sixth billet goes here when it is decided.)
local STAFF = {
    { rank = "1SG", role = "firstsgt", unarmed = true, words = "first sergeant" },
    { rank = "LT",  role = "xo",       words = "executive officer" },
    { rank = "CPL", role = "rto",      words = "radio operator" },
    { rank = "SGT", role = "surgeon",  unarmed = true, words = "surgeon" },
}

local function nextNumber(faction)
    local n = 0
    for _, u in pairs(LF.Units.all()) do
        if u.kind == "company" and u.faction == faction then n = n + 1 end
    end
    return n + 1
end

function LF.Company.of(unit)
    if not unit then return nil end
    if unit.kind == "company" then return unit end
    if unit.company then return LF.Units.get(unit.company) end
    if unit.platoon then
        local p = LF.Units.get(unit.platoon)
        return p and p.company and LF.Units.get(p.company) or nil
    end
    return nil
end

function LF.Company.hq(c) return c and c.hq and LF.Units.get(c.hq) or nil end

function LF.Company.platoons(c)
    local out = {}
    for _, pid in ipairs(c and c.platoons or {}) do
        local p = LF.Units.get(pid)
        if p and p.kind == "platoon" then out[#out + 1] = p end
    end
    return out
end

local function platoonPos(p)
    local ids = { p.hq }
    for _, sid in ipairs(p.squads or {}) do ids[#ids + 1] = sid end
    for _, uid in ipairs(ids) do
        if uid and LF.Squad and LF.Squad.anchor then
            local x, y = LF.Squad.anchor(uid)       -- (both values: "a and f()" would keep only x)
            if x then return x, y end
        end
    end
    return nil
end

-- Take the nearest platoons of its side with no company yet.
local function adopt(c, x, y)
    local free = {}
    for _, p in pairs(LF.Units.all()) do
        if p.kind == "platoon" and p.faction == c.faction and not (p.company and LF.Units.get(p.company)) then
            local px, py = platoonPos(p)
            local d = px and LF.dist(x, y, px, py) or nil
            if d and d <= CFG.adopt then free[#free + 1] = { p = p, d = d } end
        end
    end
    table.sort(free, function(a, b) return a.d < b.d end)
    local names = {}
    for i = 1, math.min(CFG.platoons, #free) do
        local p = free[i].p
        p.company = c.id
        c.platoons[#c.platoons + 1] = p.id
        names[#names + 1] = p.name
    end
    return names
end

-- A company headquarters at (x, y), facing (fx, fy); it takes the nearest free platoons.
function LF.Company.create(faction, x, y, z, fx, fy)
    local len = math.sqrt(fx * fx + fy * fy)
    if len < 0.01 then fx, fy, len = 1, 0, 1 end
    fx, fy = fx / len, fy / len
    local rx, ry = -fy, fx
    local function at(fwd, lat) return x + fx * fwd + rx * lat, y + fy * fwd + ry * lat end
    local n = nextNumber(faction)
    local c = LF.Units.newUnit({ kind = "company", faction = faction, name = faction .. " company " .. n, platoons = {},
        facingX = fx, facingY = fy })
    local hq = LF.Units.newUnit({ kind = "squad", faction = faction, teams = {}, stance = "standby",
        name = c.name .. " HQ", company = c.id, companyHQ = true, medicSet = true, facingX = fx, facingY = fy })
    c.hq = hq.id
    local place = LF.Units.placeSoldier
    -- The captain, in the middle.
    local cx, cy = at(0, 0)
    local cpt = place(faction, cx, cy, z, { squad = hq.id, rank = "CPT", element = "L", slot = 0, hqRole = "cpt", unarmed = true })
    hq.leader = cpt.id
    -- The security team ahead, the staff behind (as a squad's Alpha and Bravo stand).
    local sec = LF.Units.newUnit({ kind = "team", faction = faction, squad = hq.id, name = "Security", element = "A", slot = 1, members = {} })
    local staff = LF.Units.newUnit({ kind = "team", faction = faction, squad = hq.id, name = "Staff", element = "B", slot = 2, members = {} })
    hq.teams = { sec.id, staff.id }
    local MEN = { { 1, -1.5, "A" }, { 1, 1.5, "A" }, { -1, -1.5, "B" }, { -1, 1.5, "B" } }
    for i, m in ipairs(MEN) do
        local mx, my = at(3 + m[1], -4 + m[2])
        local r = place(faction, mx, my, z, { squad = hq.id, team = sec.id, rank = i == 2 and "CPL" or "PVT",
            element = m[3], slot = i, hqRole = "security", grenades = i == 2 and 1 or 0 })
        sec.members[i] = r.id
        if i == 2 then sec.leader = r.id end
    end
    local staffNames = {}
    for i, b in ipairs(STAFF) do
        local m = MEN[i]
        local mx, my = at(-3 + m[1], 4 + m[2])
        local r = place(faction, mx, my, z, { squad = hq.id, team = staff.id, rank = b.rank, element = m[3], slot = i,
            hqRole = b.role, unarmed = b.unarmed or nil })
        staff.members[i] = r.id
        if b.role == "firstsgt" then staff.leader = r.id end
        staffNames[#staffNames + 1] = LF.Units.title(r) .. " (" .. b.words .. ")"
    end
    local taken = adopt(c, x, y)
    LF.log("COMPANY created " .. c.name .. " (#" .. c.id .. "): " .. LF.Units.title(cpt) .. " in command; "
        .. table.concat(staffNames, ", ") .. "; a security team of 4; platoons: "
        .. (#taken > 0 and table.concat(taken, ", ") or "none yet"))
    return c, taken
end
