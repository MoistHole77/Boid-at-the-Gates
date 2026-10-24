-- Living Front: perception.
--
-- Cheap "who is near me" through a grid of live bodies rebuilt a few times a second, instead of
-- every NPC scanning every other NPC (that grew with the square of the headcount: about 8 ms per
-- frame at 150 soldiers). Line-of-sight checks, the expensive part, are capped per look.
--
-- LF.Sense.look(id, body, rec, range) returns the hostile bodies this NPC can actually see,
-- nearest first, as a reused array of { body, id, rec, dist }.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Bodies"

LF.Sense = LF.Sense or {}

local CELL = 10              -- grid cell size, tiles
local REBUILD_TICKS = 10     -- the grid is rebuilt this often (bodies move under a tile in that time)
local MAX_LOS = 5            -- enemies seen per look (nearest first)
local MAX_CHECKS = 14        -- line-of-sight checks per look at most

local grid = {}              -- cell key -> array of entries
local entryPool = {}
local poolUsed = 0
local builtTick = -1

local function cellKey(cx, cy) return cx * 65536 + cy end

local function rebuild()
    for k in pairs(grid) do grid[k] = nil end
    poolUsed = 0
    for id, body in pairs(LF.Bodies.all()) do
        if not body:isDead() then
            local rec = LF.Records.get(id)
            if rec then
                poolUsed = poolUsed + 1
                local e = entryPool[poolUsed]
                if not e then e = {}; entryPool[poolUsed] = e end
                e.id, e.body, e.rec = id, body, rec
                e.x, e.y = body:getX(), body:getY()
                local k = cellKey(math.floor(e.x / CELL), math.floor(e.y / CELL))
                local list = grid[k]
                if not list then list = {}; grid[k] = list end
                list[#list + 1] = e
            end
        end
    end
    builtTick = LF.tick
end

local function ensureGrid()
    if LF.tick - builtTick >= REBUILD_TICKS or builtTick > LF.tick then rebuild() end
end

-- Call fn(entry, dsq) for every live NPC body within range of (x, y). Positions are up to
-- REBUILD_TICKS old; callers that need precision re-read the body.
function LF.Sense.near(x, y, range, fn, ctx)
    ensureGrid()
    local rangeSq = range * range
    local c0x, c1x = math.floor((x - range) / CELL), math.floor((x + range) / CELL)
    local c0y, c1y = math.floor((y - range) / CELL), math.floor((y + range) / CELL)
    for cx = c0x, c1x do
        for cy = c0y, c1y do
            local list = grid[cellKey(cx, cy)]
            if list then
                for i = 1, #list do
                    local e = list[i]
                    local dx, dy = e.x - x, e.y - y
                    local dsq = dx * dx + dy * dy
                    if dsq <= rangeSq then fn(e, dsq, ctx) end
                end
            end
        end
    end
end

-- Line of sight between two characters, using the game's own line test.
-- Blocked and closed doors stop sight; open doors and windows don't.
local function lineResult(a, b)
    return tostring(LosUtil.lineClear(getCell(),
        math.floor(a:getX()), math.floor(a:getY()), math.floor(a:getZ()),
        math.floor(b:getX()), math.floor(b:getY()), math.floor(b:getZ()), false))
end

local losFailed = false
function LF.Sense.canSee(a, b)
    if losFailed then return true, "unknown" end
    local ok, res = pcall(lineResult, a, b)
    if not ok then
        losFailed = true
        LF.log("SENSE line of sight check FAILED (" .. tostring(res) .. "); assuming clear sight")
        return true, "unknown"
    end
    return res ~= "Blocked" and res ~= "ClearThroughClosedDoor", res
end

-- ---- look ---------------------------------------------------------------------------------

local cands = {}
local nCands = 0
local seen = {}
local function byDsq(a, b) return a.dsq < b.dsq end

local function collect(e, dsq, ctx)
    if e.id == ctx.id or not LF.isHostile(ctx.faction, e.rec.faction) then return end
    nCands = nCands + 1
    local c = cands[nCands]
    if not c then c = {}; cands[nCands] = c end
    c.e, c.dsq = e, dsq
end

local ctx = {}

-- Hostile bodies this NPC can see within range, nearest first (at most MAX_LOS checked).
-- The returned array is reused by the next call: copy what you keep.
function LF.Sense.look(id, body, rec, range)
    nCands = 0
    ctx.id, ctx.faction = id, rec.faction
    LF.Sense.near(body:getX(), body:getY(), range, collect, ctx)
    for i = #cands, nCands + 1, -1 do cands[i] = nil end
    if nCands > 1 then table.sort(cands, byDsq) end
    local n = 0
    -- The nearest MAX_LOS that he can actually see, checking at most MAX_CHECKS: the nearest
    -- enemies are often behind a wall (up to 0.37 only the nearest 5 were checked, so a defender
    -- with the enemy at the door behind him never saw the man in front of his own window).
    for i = 1, math.min(nCands, MAX_CHECKS) do
        if n >= MAX_LOS then break end
        local e = cands[i].e
        if not e.body:isDead() and LF.Sense.canSee(body, e.body) then
            n = n + 1
            local s = seen[n]
            if not s then s = {}; seen[n] = s end
            s.body, s.id, s.rec, s.dist = e.body, e.id, e.rec, math.sqrt(cands[i].dsq)
        end
    end
    for i = #seen, n + 1, -1 do seen[i] = nil end
    return seen
end
