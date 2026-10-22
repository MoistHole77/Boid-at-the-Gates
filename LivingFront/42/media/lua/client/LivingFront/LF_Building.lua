-- Living Front: building layouts, for defending (and clearing) a building.
--
-- LF.Building.at(x, y, z) scans the building at that square (one floor) and returns its layout,
-- cached per building and floor:
--   inside    - walkable squares inside: { x, y }; insideSet["x,y"] = true
--   openings  - windows and doors to the outside: { x, y (the inside square), dx, dy (outward),
--               kind = "window" | "door", wall, blocked (furniture on the square), movable (that
--               furniture is a single-tile movable piece a man can shove aside) }
--   edges[w]  - inside squares along wall w (the square beyond them that way is not inside)
--   cx, cy    - the middle (average of the inside squares)
-- Walls are numbered by the way they face, the same order as the perimeter quarters:
--   1 north (0,-1), 2 west (-1,0), 3 south (0,1), 4 east (1,0)

require "TimedActions/ISBaseTimedAction"
require "LivingFront/LF_Core"

LF.Building = LF.Building or {}

local WALL_DIR = { { 0, -1 }, { -1, 0 }, { 0, 1 }, { 1, 0 } }
LF.Building.WALL_DIR = WALL_DIR
LF.Building.WALL_NAME = { "north", "west", "south", "east" }

local SCAN = 25            -- tiles around the starting square
local cache = {}           -- "buildingId:z" -> layout

Events.OnInitGlobalModData.Add(function() cache = {} end)

local function bid(sq)
    local b = sq and sq:getBuilding()
    return b and b:getID() or nil
end

function LF.Building.idAt(x, y, z)
    return bid(getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z)))
end

local function key(x, y) return x .. "," .. y end

function LF.Building.at(x, y, z)
    local cell = getCell()
    z = math.floor(z)
    local start = cell:getGridSquare(math.floor(x), math.floor(y), z)
    local id = bid(start)
    if not id then return nil end
    local ck = id .. ":" .. z
    if cache[ck] then return cache[ck] end
    local L = { id = id, z = z, inside = {}, insideSet = {}, openings = {}, edges = { {}, {}, {}, {} } }
    local blockedWin = {}
    local sx, sy = math.floor(x), math.floor(y)
    local tx, ty = 0, 0
    for ix = sx - SCAN, sx + SCAN do
        for iy = sy - SCAN, sy + SCAN do
            local sq = cell:getGridSquare(ix, iy, z)
            if sq and bid(sq) == id then
                if sq:isFree(false) then
                    L.inside[#L.inside + 1] = { x = ix, y = iy }
                    L.insideSet[key(ix, iy)] = sq
                    tx, ty = tx + ix, ty + iy
                else
                    -- Furniture (or something) on this square: still note a window in it.
                    for w, d in ipairs(WALL_DIR) do
                        local nb = cell:getGridSquare(ix + d[1], iy + d[2], z)
                        if nb and bid(nb) ~= id and sq:isWindowTo(nb) then
                            blockedWin[#blockedWin + 1] = { x = ix, y = iy, dx = d[1], dy = d[2], kind = "window", wall = w,
                                                            blocked = true, movable = LF.Building.movableOn(sq) ~= nil }
                        end
                    end
                end
            end
        end
    end
    if #L.inside == 0 then return nil end
    L.cx, L.cy = tx / #L.inside + 0.5, ty / #L.inside + 0.5
    for _, s in ipairs(L.inside) do
        local sq = L.insideSet[key(s.x, s.y)]
        for w, d in ipairs(WALL_DIR) do
            local nx, ny = s.x + d[1], s.y + d[2]
            if not L.insideSet[key(nx, ny)] then
                local nb = cell:getGridSquare(nx, ny, z)
                local outside = nb and bid(nb) ~= id
                if outside or not nb then L.edges[w][#L.edges[w] + 1] = { x = s.x, y = s.y } end
                if nb and outside then
                    if sq:isWindowTo(nb) then
                        L.openings[#L.openings + 1] = { x = s.x, y = s.y, dx = d[1], dy = d[2], kind = "window", wall = w }
                    elseif sq:isDoorTo(nb) then
                        L.openings[#L.openings + 1] = { x = s.x, y = s.y, dx = d[1], dy = d[2], kind = "door", wall = w }
                    end
                end
            end
        end
    end
    for _, o in ipairs(blockedWin) do L.openings[#L.openings + 1] = o end
    local counts = { 0, 0, 0, 0 }
    for _, o in ipairs(L.openings) do counts[o.wall] = counts[o.wall] + 1 end
    L.wallOpenings = counts
    cache[ck] = L
    LF.log("BUILDING #" .. tostring(id) .. " floor " .. z .. ": " .. #L.inside .. " squares inside, openings north "
        .. counts[1] .. ", west " .. counts[2] .. ", south " .. counts[3] .. ", east " .. counts[4])
    return L
end

-- The single movable piece of furniture on a square that blocks it (a chair, a drawer, a
-- table), or nil. Multi-tile furniture (beds, sofas) doesn't count: too big to shove.
function LF.Building.movableOn(sq)
    local objs = sq:getObjects()
    local found = nil
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local props = o:getProperties()
        if o ~= sq:getFloor() and props and props:Is("IsMoveAble") then
            if o:getSpriteGrid() ~= nil then return nil end
            if found then return nil end            -- more than one piece: leave it
            found = o
        end
    end
    return found
end

-- Shove the furniture off a window square onto a free square beside it (inside the building,
-- not a square in `avoid`). Returns true if the window square is now free.
function LF.Building.shove(L, x, y, dx, dy, avoid)
    local cell = getCell()
    local sq = cell:getGridSquare(x, y, L.z)
    if not sq then return false end
    local obj = LF.Building.movableOn(sq)
    if not obj then return sq:isFree(false) end
    -- Along the wall first, then further in.
    local tries = { { -dy, dx }, { dy, -dx }, { -dy - dx, dx - dy }, { dy - dx, -dx - dy }, { -2 * dx, -2 * dy } }
    for _, t in ipairs(tries) do
        local nx, ny = x + t[1], y + t[2]
        local dest = L.insideSet[key(nx, ny)]
        if dest and dest:isFree(false) and not (avoid and avoid[key(nx, ny)]) and dest:getMovingObjects():size() == 0 then
            sq:RemoveTileObject(obj)
            dest:AddTileObject(obj)
            pcall(function() sq:RecalcAllWithNeighbours(true) end)
            pcall(function() dest:RecalcAllWithNeighbours(true) end)
            if sq:isFree(false) then
                L.insideSet[key(x, y)] = sq
                L.insideSet[key(nx, ny)] = nil
                for _, o in ipairs(L.openings) do
                    if o.x == x and o.y == y then o.blocked, o.movable = false, false end
                end
                return true
            end
            return false
        end
    end
    return false
end

-- The inside square d tiles in from (x, y) against direction (dx, dy), if it is inside: x, y.
function LF.Building.inward(L, x, y, dx, dy, d)
    for k = d, 1, -1 do
        local ix, iy = x - dx * k, y - dy * k
        if L.insideSet[key(ix, iy)] then return ix, iy end
    end
    return nil
end

function LF.Building.isInside(L, x, y)
    return L.insideSet[key(math.floor(x), math.floor(y))] ~= nil
end

-- A defender shoves the furniture out of his window (LF.Tactics.shoveWindow does the moving).
LF_ShoveAction = ISBaseTimedAction:derive("LF_ShoveAction")

function LF_ShoveAction:isValid() return not self.character:isDead() end
function LF_ShoveAction:waitToStart() return false end
function LF_ShoveAction:start()
    self.character:faceLocation(self.win.x + 0.5, self.win.y + 0.5)
end
function LF_ShoveAction:stop() ISBaseTimedAction.stop(self) end
function LF_ShoveAction:perform()
    if self.onDone then LF.guard("shove", self.onDone, self.rec) end
    ISBaseTimedAction.perform(self)
end
function LF_ShoveAction:new(character, rec, win, onDone)
    local o = ISBaseTimedAction.new(self, character)
    o.rec, o.win, o.onDone = rec, win, onDone
    o.maxTime = 60
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.ignoreHandsWounds = true
    return o
end
