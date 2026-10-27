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
-- A company is always the same four platoons (CFG.platoons), kept with the save: right-click its
-- captain to spawn the next one under his command. Units spawned any other way stand outside
-- every chain of command, as before.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/Tactics/LF_Platoon"

LF.Company = LF.Company or {}

local CFG = {
    platoons = 4,           -- a company's platoons
    spacing = 40,           -- tiles between the platoons when they are spawned, abreast ...
    ahead = 30,             -- ... this far in front of the company headquarters
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
    LF.log("COMPANY created " .. c.name .. " (#" .. c.id .. "): " .. LF.Units.title(cpt) .. " in command; "
        .. table.concat(staffNames, ", ") .. "; a security team of 4; no platoons yet (right-click the captain)")
    return c
end

-- The company a captain commands, or nil.
function LF.Company.ofCaptain(rec)
    if not (rec and rec.rank == "CPT" and rec.squad) then return nil end
    local hq = LF.Units.get(rec.squad)
    local c = hq and hq.companyHQ and LF.Units.get(hq.company)
    if c and hq.leader == rec.id then return c end
    return nil
end

-- Spawn the company's next platoon (headquarters, 3 rifle squads, a machine-gun squad), abreast
-- of the others in front of the company headquarters. Returns the platoon, or nil and why.
function LF.Company.addPlatoon(c)
    if not c then return nil, "no company" end
    c.platoons = c.platoons or {}
    if #c.platoons >= CFG.platoons then return nil, "the company already has its " .. CFG.platoons .. " platoons" end
    local hq = LF.Company.hq(c)
    local cid = hq and hq.leader
    local cap = cid and LF.Records.get(cid)
    local b = cid and LF.Bodies and LF.Bodies.get(cid)
    local x, y, z = nil, nil, 0
    if b then x, y, z = b:getX(), b:getY(), math.floor(b:getZ())
    elseif cap then x, y, z = cap.x, cap.y, cap.z or 0 end
    if not x then return nil, "the company headquarters is nowhere to be found" end
    local fx, fy = c.facingX or 1, c.facingY or 0
    local rx, ry = -fy, fx
    local slot = #c.platoons + 1
    local lat = (slot - (CFG.platoons + 1) / 2) * CFG.spacing
    local px, py = x + fx * CFG.ahead + rx * lat, y + fy * CFG.ahead + ry * lat
    local p = LF.Platoon.create(c.faction, px, py, z, fx, fy, true)
    p.company, p.companySlot = c.id, slot
    c.platoons[#c.platoons + 1] = p.id
    LF.log("COMPANY " .. c.name .. ": " .. p.name .. " joins as its platoon " .. slot .. " of " .. CFG.platoons)
    return p
end

-- ---- right-click a captain: spawn a platoon under his command --------------------------------------

local function onMenu(playerNum, context, worldObjects, test)
    if test or not LF.Inspect then return end
    local sq = LF.try("company square", function() return worldObjects[1]:getSquare() end)
    if not sq then return end
    for _, f in ipairs(LF.Inspect.near(sq:getX(), sq:getY(), sq:getZ())) do
        local rec = LF.Records.get(f.id)
        local c = rec and rec.alive and LF.Company.ofCaptain(rec)
        if c then
            local n = #(c.platoons or {})
            local opt = context:addOption(string.format("Spawn a platoon under %s's command (%d/%d)", LF.Units.title(rec), n, CFG.platoons),
                nil, function()
                    local p, why = LF.Company.addPlatoon(c)
                    LF.say(p and (p.name .. " - under " .. LF.Units.title(rec) .. "'s command") or ("Can't: " .. tostring(why)))
                end)
            if n >= CFG.platoons then opt.notAvailable = true end
        end
    end
end
Events.OnFillWorldObjectContextMenu.Add(function(...) LF.guard("company menu", onMenu, ...) end)
