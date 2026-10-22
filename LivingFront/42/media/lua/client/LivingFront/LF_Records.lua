-- Living Front: NPC records, the single source of truth.
-- Records live in global ModData, which the game saves with the world.
-- Bodies are never saved by the game (map squares only save dead bodies), so a body is
-- always rebuilt from its record.

require "LivingFront/LF_Core"
require "LivingFront/LF_Names"

LF.Records = LF.Records or {}

local DATA_KEY = "LivingFront"
LF.Records.SCHEMA = 2   -- bump when the record layout changes

-- The ModData table is fetched once and cached: records are read every tick by the brain, and
-- ModData.getOrCreate is a Java call. The cache is dropped whenever the game (re)loads world data.
local cached = nil

local function store()
    if cached then return cached end
    local data = ModData.getOrCreate(DATA_KEY)
    if not data.nextId then data.nextId = 1 end
    if not data.npcs then data.npcs = {} end
    cached = data
    return data
end

Events.OnInitGlobalModData.Add(function() cached = nil end)

-- The whole saved table (records, units, id counters), for other modules that store data.
function LF.Records.data()
    return store()
end

local function javaListToTable(list)
    local out = {}
    if not list then return out end
    for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
    return out
end

-- Decide who this person is: sex by faction, name to match, and how they look.
local function newIdentity(factionKey)
    local faction = LF.Factions[factionKey]
    local female = ZombRand(100) < math.floor((faction.femaleChance or 0.5) * 100)

    local forename, surname = LF.Names.random(factionKey, female)
    if not forename then forename, surname = "Survivor", "Unknown" end
    if not LF.Names.byFaction[factionKey] then LF.try("random name", function()
        local desc = SurvivorFactory.CreateSurvivor()
        desc:setFemale(female)
        SurvivorFactory.randomName(desc)
        forename, surname = desc:getForename(), desc:getSurname()
        return true
    end) end

    local hairStyles = {}
    for _, style in ipairs(LF.try("hair styles", function() return javaListToTable(getAllHairStyles(female)) end) or {}) do
        -- Women never get a shaved head; empty ids are also skipped.
        if style ~= "" and not (female and style == "Bald") then hairStyles[#hairStyles + 1] = style end
    end
    local hair = #hairStyles > 0 and LF.pick(hairStyles) or nil

    local beard = nil
    if not female and ZombRand(100) < 40 then
        local beards = LF.try("beard styles", function() return javaListToTable(getAllBeardStyles()) end) or {}
        if #beards > 0 then beard = LF.pick(beards) end
    end

    local color = LF.pick(LF.HairColors)
    return {
        female = female,
        forename = forename,
        surname = surname,
        look = {
            skin = LF.pick(LF.SkinIndices),
            hair = hair,
            beard = beard or "",
            hairR = color[1], hairG = color[2], hairB = color[3],
        },
    }
end

-- fields: faction, x, y, z (required).
function LF.Records.create(fields)
    local data = store()
    local id = data.nextId
    data.nextId = id + 1

    local factionKey = fields.faction or "CIV"
    local who = newIdentity(factionKey)

    local rec = {
        schema = LF.Records.SCHEMA,
        id = id,
        faction = factionKey,
        alive = true,
        female = who.female,
        forename = who.forename,
        surname = who.surname,
        look = who.look,
        outfit = LF.pick(LF.Factions[factionKey].outfits),
        worn = nil,       -- worn item full types, captured from the first body
        x = fields.x, y = fields.y, z = fields.z or 0,
        homeX = fields.x, homeY = fields.y, homeZ = fields.z or 0,
        hunger = 0, thirst = 0, fatigue = 0,
        created = getGameTime():getWorldAgeHours(),
    }
    data.npcs[id] = rec
    return rec
end

function LF.Records.get(id)
    return store().npcs[id]
end

function LF.Records.all()
    return store().npcs
end

function LF.Records.remove(id)
    store().npcs[id] = nil
end

function LF.Records.count()
    local n = 0
    for _ in pairs(store().npcs) do n = n + 1 end
    return n
end

-- Remove records from older, incompatible versions of the mod.
function LF.Records.dropOutdated()
    local dropped = 0
    for id, rec in pairs(store().npcs) do
        if rec.schema ~= LF.Records.SCHEMA then
            store().npcs[id] = nil
            dropped = dropped + 1
        end
    end
    return dropped
end

function LF.Records.fullName(rec)
    return rec.forename .. " " .. rec.surname
end
