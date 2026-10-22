-- Living Front: core config, factions, and small shared helpers.

LF = LF or {}
LF.VERSION = "0.3.2"

LF.Config = {
    spawnRadius = 30,        -- a record gets a body when the player is within this many tiles
    despawnRadius = 45,      -- a body is put away beyond this distance (gap prevents flapping)
    managerInterval = 30,    -- ticks between body-manager passes (about twice a second)
    maxSpawnsPerPass = 2,    -- spread spawns over frames to avoid hitches
    -- Off-screen need rates per 10 in-game minutes, measured from a spawned body in testing.
    rates = { hunger = 0.0037, thirst = 0.0031, fatigue = 0.0042 },
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

-- Runs fn in pcall. Logs each distinct failure label once, returns nil on failure.
function LF.try(label, fn)
    local ok, result = pcall(fn)
    if not ok then
        if not seenErrors[label] then
            seenErrors[label] = true
            LF.log(label .. " FAILED: " .. tostring(result))
        end
        return nil
    end
    return result
end

-- Speech bubble over the real player, for debug feedback.
function LF.say(text)
    local p = getPlayer()
    if p then LF.try("say", function() p:Say(text); return true end) end
end

function LF.pick(list)
    return list[ZombRand(#list) + 1]
end

function LF.dist(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end
