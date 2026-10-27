-- Living Front: core config, factions, and small shared helpers.

LF = LF or {}
LF.VERSION = "0.69"

LF.Config = {
    spawnRadius = 50,        -- a record gets a body when the player is within this many tiles
    despawnRadius = 58,      -- a body is put away beyond this distance (gap prevents flapping)
    managerInterval = 30,    -- ticks between body-manager passes (about twice a second)
    maxSpawnsPerPass = 4,    -- spread spawns over frames to avoid hitches
    -- Off-screen need rates per 10 in-game minutes, measured from a spawned body in testing.
    rates = { hunger = 0.0037, thirst = 0.0031, fatigue = 0.0042 },
    logShots = true,         -- one log line per shot (debugging); turn off for long sessions
    logAreaFire = false,     -- one log line per area-fire shot (very chatty)
    logGait = false,         -- running/sprinting checks and measured speed (debugging; very chatty)
    logPerf = true,          -- frame rate and the mod's own cost, every perfWindowMs (stress testing)
    perfWindowMs = 5000,
}

-- femaleChance: share of new NPCs who are women. Soldiers are all men; civilians lean female
-- because fighting-age men are at the front.
LF.Factions = {
    CIV = { name = "Civilian", femaleChance = 0.65, outfits = { "Generic01", "Generic02", "Generic03", "Generic04", "Generic05",
                                           "Farmer", "Tourist", "Classy", "OfficeWorker", "Student",
                                           "ConstructionWorker", "Young" } },
    -- Placeholder uniforms until period-accurate clothing exists.
    GER = { name = "German", femaleChance = 0, outfits = { "ArmyCamoDesert" } },
    SOV = { name = "Soviet", femaleChance = 0, outfits = { "ArmyCamoGreen" } },
}

-- Skin texture indices allowed for new NPCs. Index 0 is the lightest tone in the game's
-- character creator, 4 the darkest; 0-1 are light European skin tones.
LF.SkinIndices = { 0, 1 }

-- Natural hair colours (r, g, b) for new NPCs.
LF.HairColors = {
    { 0.10, 0.08, 0.06 }, -- near black
    { 0.25, 0.17, 0.10 }, -- dark brown
    { 0.42, 0.29, 0.17 }, -- brown
    { 0.60, 0.45, 0.28 }, -- light brown
    { 0.80, 0.68, 0.45 }, -- dark blonde
    { 0.92, 0.82, 0.58 }, -- blonde
    { 0.55, 0.25, 0.12 }, -- auburn
}

-- Who is hostile to whom. Civilians side with the Soviets.
LF.Hostile = {
    CIV = { GER = true },
    GER = { CIV = true, SOV = true },
    SOV = { GER = true },
}

function LF.isHostile(factionA, factionB)
    local t = LF.Hostile[factionA]
    return t ~= nil and t[factionB] == true
end

local TAG = "[LivingFront] "
local seenErrors = {}

function LF.log(msg)
    print(TAG .. tostring(msg))
end

local function reportOnce(label, err)
    if not seenErrors[label] then
        seenErrors[label] = true
        LF.log(label .. " FAILED: " .. tostring(err))
    end
end

-- Runs fn in pcall. Logs each distinct failure label once, returns nil on failure.
-- For rare, one-off calls (spawning, dressing): it costs a closure per call.
function LF.try(label, fn)
    local ok, result = pcall(fn)
    if not ok then
        reportOnce(label, result)
        return nil
    end
    return result
end

-- Like LF.try, but passes arguments straight to fn, so hot paths (per tick, per frame) don't
-- allocate a closure on every call. Returns up to three results.
function LF.guard(label, fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        reportOnce(label, a)
        return nil
    end
    return a, b, c
end

-- One shared game clock (ticks since load) for every module.
LF.tick = 0
function LF.now()
    return LF.tick
end
Events.OnTick.Add(function() LF.tick = LF.tick + 1 end)

-- Simulated seconds: real time scaled by the game speed (1x, 5x, 20x, 40x), stopped while
-- paused. What the off-screen war is timed by - a squad walking 0.75 tiles a second walks that
-- many tiles per simulated second whether you can see it or not.
LF.simTime = 0
local SPEEDS = { [0] = 0, [1] = 1, [2] = 5, [3] = 20, [4] = 40 }   -- (0: paused - the map can do that)
local lastMs = nil
Events.OnTick.Add(function()
    local now = getTimestampMs and getTimestampMs() or nil
    if not now then return end
    local dt = lastMs and (now - lastMs) / 1000 or 0
    lastMs = now
    if dt <= 0 then return end
    dt = math.min(dt, 0.25)                     -- (a hitch or a load screen isn't marching time)
    if isGamePaused and isGamePaused() then return end
    local sp = getGameSpeed and getGameSpeed() or 1
    LF.simTime = LF.simTime + dt * (SPEEDS[sp] or 1)
end)

-- Speech bubble over the real player, for debug feedback.
function LF.say(text)
    local p = getPlayer()
    if p then LF.try("say", function() p:Say(text); return true end) end
end

function LF.pick(list)
    return list[ZombRand(#list) + 1]
end

-- ---- text over a character ---------------------------------------------------------------------------
-- Where a world point is on screen (UI pixels) the way the game places its own text over a
-- character: from the camera offset the world was drawn with, shifted as the game shifts models
-- so the camera's character lands on whole pixels. (isoToScreenX instead lines a point up with
-- the floor tiles, a fraction of a pixel off the models: text drawn with it jiggles while the
-- camera moves.)
local function exactScreen(x, y, z, zoom)
    local sx = (IsoUtils.XToScreen(x, y, z, 0) - IsoCamera.getOffX()) / zoom + IsoCamera.getScreenLeft(0)
    local sy = (IsoUtils.YToScreen(x, y, z, 0) - IsoCamera.getOffY()) / zoom + IsoCamera.getScreenTop(0)
    return sx, sy
end
local screenOk = nil
-- (A plain function handed to pcall: nothing created per call.)
local function modelScreen(x, y, z, zoom)
    local ax, ay = exactScreen(x, y, z, zoom)
    local p = getPlayer()
    local qx, qy = ax, ay
    if p then qx, qy = exactScreen(p:getX(), p:getY(), p:getZ(), zoom) end
    return ax, ay, qx - math.floor(qx), qy - math.floor(qy)
end
function LF.screenOf(x, y, z)
    local zoom = getCore():getZoom(0)
    if screenOk ~= false then
        local ok, sx, sy, fx, fy = pcall(modelScreen, x, y, z, zoom)
        if ok and sx then
            screenOk = true
            return math.floor(sx - fx + 0.5), math.floor(sy - fy + 0.5)
        end
        screenOk = false
        LF.log("text over characters: falling back to isoToScreen")
    end
    return isoToScreenX(0, x, y, z), isoToScreenY(0, x, y, z)
end

-- How high over a body his head is (UI pixels at zoom 1): standing, crouched, sitting, lying.
-- Eased per body, so text over him glides down as he sits rather than dropping.
local headNow, headTick = {}, {}
local function postureHeight(body)
    if body:isOnFloor() or body:isKnockedDown() then return 40 end
    if LF.Idle and LF.Idle.isSitting(body) then return 82 end
    if body:isSneaking() then return 108 end
    return 135
end
function LF.headHeight(body)
    if headTick[body] == LF.tick and headNow[body] then return headNow[body] end
    headTick[body] = LF.tick
    local ok, target = pcall(postureHeight, body)
    if not ok or not target then target = 135 end
    local cur = headNow[body] or target
    cur = cur + (target - cur) * 0.15
    if math.abs(target - cur) < 0.5 then cur = target end
    headNow[body] = cur
    return cur
end
Events.OnTick.Add(function()
    if (LF.tick or 0) % 600 ~= 7 then return end
    for b in pairs(headNow) do
        local ok, dead = pcall(function() return b:isDead() or not b:getCurrentSquare() end)
        if not ok or dead then headNow[b] = nil; headTick[b] = nil end
    end
end)

function LF.dist(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end

-- Squared distance: compare against range * range to skip the square root in loops.
function LF.distSq(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return dx * dx + dy * dy
end
