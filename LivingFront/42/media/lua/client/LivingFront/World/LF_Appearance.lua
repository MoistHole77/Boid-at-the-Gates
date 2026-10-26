-- Living Front: building a consistent-looking person from a record.
-- The record decides sex, skin, hair and beard when it is created. Clothing comes from the
-- record's named outfit on first spawn, then is remembered as a list of worn items.
--
-- Engine notes (from the game's code):
--  * IsoPlayer:dressInNamedOutfit() only builds a preview for non-local players; turning it
--    into worn items is gated on isLocalPlayer(). We do that conversion ourselves.
--  * The body type ("torso") is set when a descriptor is created. Changing sex afterwards
--    needs SurvivorFactory.setTorso(), as the game's character creator does.

require "LivingFront/Core/LF_Core"

LF.Appearance = LF.Appearance or {}

local function applyLook(visual, look)
    if not visual or not look then return end
    LF.try("apply skin", function() visual:setSkinTextureIndex(look.skin); return true end)
    LF.try("apply hair", function() visual:setHairModel(look.hair or ""); return true end)
    LF.try("apply beard", function() visual:setBeardModel(look.beard or ""); return true end)
    if look.hairR then
        LF.try("apply hair colour", function()
            local c = ImmutableColor.new(look.hairR, look.hairG, look.hairB, 1)
            visual:setHairColor(c)
            visual:setNaturalHairColor(c)
            visual:setBeardColor(c)
            visual:setNaturalBeardColor(c)
            return true
        end)
    end
end

-- A descriptor with the record's sex, body type, name and look.
function LF.Appearance.makeDescriptor(rec)
    local desc = LF.try("CreateSurvivor", function() return SurvivorFactory.CreateSurvivor() end)
    if not desc then return nil end
    LF.try("desc sex", function()
        desc:setFemale(rec.female)
        SurvivorFactory.setTorso(desc)
        return true
    end)
    LF.try("desc name", function()
        desc:setForename(rec.forename)
        desc:setSurname(rec.surname)
        return true
    end)
    applyLook(desc:getHumanVisual(), rec.look)
    return desc
end

local function captureWorn(body)
    return LF.try("capture worn", function()
        local list = {}
        local worn = body:getWornItems()
        for i = 0, worn:size() - 1 do
            local item = worn:getItemByIndex(i)
            if item then list[#list + 1] = item:getFullType() end
        end
        return list
    end) or {}
end

-- Turn a named outfit into real worn items (the step vanilla only does for local players).
local function wearNamedOutfit(body, outfit)
    return LF.try("wear outfit " .. tostring(outfit), function()
        local visuals = ItemVisuals.new()
        body:getHumanVisual():dressInNamedOutfit(outfit, visuals)
        body:getWornItems():setFromItemVisuals(visuals)
        body:getWornItems():addItemsToItemContainer(body:getInventory())
        return true
    end)
end

local function wearList(body, list)
    local inv = body:getInventory()
    for _, fullType in ipairs(list) do
        LF.try("wear " .. fullType, function()
            local item = inv:AddItem(fullType)
            if item and item:getBodyLocation() then
                body:setWornItem(item:getBodyLocation(), item)
            end
            return true
        end)
    end
end

-- ---- kit by role ---------------------------------------------------------------------------------
-- The army outfits hand out field radios at random; only a platoon's radio operator carries one.
-- He wears it on his back in place of his pack. A captain wears an officer's greatcoat (field
-- grey for the Germans, brown for the Soviets) and a peaked cap, and no pack; a lieutenant the
-- same greatcoat with his side's helmet (0.66); a company first sergeant the peaked cap over his
-- ordinary uniform; the company surgeon a white apron over his.
local function typeOf(item) return item and item:getType() or "" end
-- The helmets the army outfits give each side (ArmyCamoDesert, ArmyCamoGreen).
local HELMET = { GER = "Base.Hat_ArmyDesert", SOV = "Base.Hat_Army" }
local BACK_PACKS = { "Bag_ALICEpack", "Bag_HydrationBackpack", "Bag_Military" }

local function isBackPack(t)
    for _, p in ipairs(BACK_PACKS) do if t:sub(1, #p) == p then return true end end
    return false
end

local function strip(body, test)
    local gone = 0
    local worn = body:getWornItems()
    for i = worn:size() - 1, 0, -1 do
        local item = worn:getItemByIndex(i)
        if item and test(typeOf(item), item) then
            pcall(function() body:removeWornItem(item) end)
            pcall(function() body:getInventory():Remove(item) end)
            gone = gone + 1
        end
    end
    return gone
end

local function wears(body, fullType)
    local worn = body:getWornItems()
    for i = 0, worn:size() - 1 do
        local item = worn:getItemByIndex(i)
        if item and item:getFullType() == fullType then return true end
    end
    return false
end

local function put(body, fullType, locations)
    if wears(body, fullType) then return true end
    local item = body:getInventory():AddItem(fullType)
    if not item then LF.log("KIT couldn't make " .. fullType); return false end
    -- (No error() inside pcall for a missing location: the game logs every caught error with a
    -- full stack trace.)
    local tries = {}
    pcall(function() tries[#tries + 1] = item:getBodyLocation() end)
    pcall(function() tries[#tries + 1] = item:canBeEquipped() end)
    for _, l in ipairs(locations or {}) do tries[#tries + 1] = l end
    for _, l in ipairs(tries) do
        if l and l ~= "" then
            pcall(function() body:setWornItem(l, item) end)
            if wears(body, fullType) then return true end
        end
    end
    LF.log("KIT couldn't put on " .. fullType)
    return false
end

-- Returns true if anything changed.
function LF.Appearance.roleKit(body, rec)
    local changed = 0
    local rto = rec.hqRole == "rto"
    changed = changed + strip(body, function(t) return not rto and (t:find("ManPack") or t:find("Radio")) ~= nil end)
    if rto then
        changed = changed + strip(body, function(t) return isBackPack(t) end)
        if not wears(body, "Base.ManPackRadio") and put(body, "Base.ManPackRadio", { "base:back", "Back" }) then changed = changed + 1 end
    end
    local coat, cap = "Base.LF_Greatcoat_" .. (rec.faction or ""), "Base.LF_PeakCap_" .. (rec.faction or "")
    local helmet = HELMET[rec.faction] or "Base.Hat_Army"
    local function isHat(t) return t:sub(1, 4) == "Hat_" or t:sub(1, 11) == "LF_PeakCap_" end
    local function isCoat(t) return t:sub(1, 7) == "Jacket_" or t:sub(1, 11) == "JacketLong_" end
    if rec.rank == "CPT" then
        -- A captain: the officer's greatcoat and peaked cap, no pack.
        changed = changed + strip(body, function(t, item)
            local full = item:getFullType()
            if full == coat or full == cap then return false end
            return isHat(t) or isCoat(t) or isBackPack(t)
        end)
        if put(body, coat) then changed = changed + 1 end
        if put(body, cap) then changed = changed + 1 end
    elseif rec.rank == "LT" then
        -- A lieutenant: the greatcoat, with a helmet (his side's) instead of the cap; no pack.
        changed = changed + strip(body, function(t, item)
            local full = item:getFullType()
            if full == coat or full == helmet then return false end
            return isHat(t) or isCoat(t) or isBackPack(t)
        end)
        if put(body, coat) then changed = changed + 1 end
        if put(body, helmet) then changed = changed + 1 end
    elseif rec.rank == "1SG" then
        -- The first sergeant: the officers' peaked cap over his ordinary uniform.
        changed = changed + strip(body, function(t, item)
            return item:getFullType() ~= cap and isHat(t)
        end)
        if put(body, cap) then changed = changed + 1 end
    end
    if rec.hqRole == "surgeon" then
        -- The surgeon: a white apron over his uniform.
        if not wears(body, "Base.Apron_White") and put(body, "Base.Apron_White") then changed = changed + 1 end
    end
    if changed > 0 then
        pcall(function() body:onWornItemsChanged(); body:resetModelNextFrame() end)
    end
    return changed > 0
end

-- Dress and style a freshly created body. Returns how many items it is wearing.
function LF.Appearance.dress(body, rec)
    LF.try("body sex", function() body:setFemale(rec.female); return true end)

    if rec.worn and #rec.worn > 0 then
        wearList(body, rec.worn)
    else
        -- Some outfits have no version for one sex and produce nothing. Try the record's
        -- outfit, then the faction's others, then a plain generic outfit.
        local candidates = { rec.outfit }
        for _, name in ipairs(LF.Factions[rec.faction].outfits) do
            if name ~= rec.outfit then candidates[#candidates + 1] = name end
        end
        candidates[#candidates + 1] = "Generic01"
        rec.worn = {}
        for _, name in ipairs(candidates) do
            wearNamedOutfit(body, name)
            rec.worn = captureWorn(body)
            if #rec.worn > 0 then
                if name ~= rec.outfit then
                    LF.log("#" .. rec.id .. " outfit " .. tostring(rec.outfit) .. " gave no clothes; using " .. name)
                    rec.outfit = name
                end
                break
            end
        end
    end

    -- His place in the unit changes the kit (radio, officer's coat and cap).
    if rec.faction == "GER" or rec.faction == "SOV" then
        if LF.guard("role kit", LF.Appearance.roleKit, body, rec) then rec.worn = captureWorn(body) end
    end

    -- Outfits can change hair, so the record's look is applied last.
    applyLook(body:getHumanVisual(), rec.look)

    LF.try("refresh visuals", function()
        body:onWornItemsChanged()
        body:resetModelNextFrame()
        return true
    end)
    return #rec.worn
end
