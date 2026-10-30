-- Living Front: NPC posture (crouching / standing) that ignores the player's crouch key.
--
-- The bug: NPC bodies are IsoPlayers with player index 0, so the engine's crouch-key handler
-- (IsoPlayer.updateSneakKey -> CharacterInputComponent, keyboard mode for index 0) reads the
-- real keyboard for them too. Every press of the player's crouch key toggled every NPC.
-- The index can't be changed from Lua.
--
-- The fix: the mod decides each NPC's posture (LF.Posture.set), and enforces it from the
-- OnPlayerUpdate event, which the engine fires for each NPC just before its crouch-key check
-- in the same update. If the crouch key was pressed this frame, the engine is about to flip
-- the posture, so we set the opposite first and the flip lands on the posture we want.

require "LivingFront/Core/LF_Core"

LF.Posture = LF.Posture or {}

local want = {}            -- record id -> true (crouch) / nil (stand)
local canReadKey = nil     -- can Lua call isCrouchButtonPressed on a body? (checked once)

local function readKey(body)
    return body:isCrouchButtonPressed()
end

-- Choose a posture for an NPC body (true = crouched).
function LF.Posture.set(body, crouch)
    local id = body:getModData().LF_id
    if not id then return end
    want[id] = crouch or nil
    if body:isSneaking() ~= (crouch == true) then body:setSneaking(crouch == true) end
end

function LF.Posture.crouched(body)
    local id = body:getModData().LF_id
    return id ~= nil and want[id] == true
end

function LF.Posture.forget(id)
    want[id] = nil
end

-- (0.78) The crouch key is the same key for every body (they all read player 0's keyboard): it is
-- read once a frame, by the first body updated, not once per body.
local keyFrame, keyDown = -1, false

-- (0.83.2) The game only flips a body's posture on the crouch key: on a frame the key isn't down,
-- a body is checked only once in 30 frames (in case anything else stood him up or crouched him),
-- with no call into the game, and no protected call, for the rest. Up to 0.83.1 every body was
-- checked every frame (0.4-1.0 ms a frame with 80 bodies). Bodies are known by the object itself
-- (no mod-data read); the table is emptied once a minute so bodies put away don't pile up.
local idOf = {}
local seen, clearedAt = 0, 0
local function quiet(body)
    local id = idOf[body]
    if not id or not canReadKey or keyFrame ~= LF.frame or keyDown then return false end
    seen = seen + 1
    return (seen + id) % 30 ~= 0
end
local function onPlayerUpdate(body)
    local id = idOf[body]
    if not id then
        id = body:getModData().LF_id
        if id then idOf[body] = id end
        if LF.frame - clearedAt > 3600 then idOf, clearedAt = {}, LF.frame end
    end
    if not id then                -- the real player, or someone else's character
        if LF.Watch and LF.Watch.onUpdate then LF.Watch.onUpdate(body) end
        return
    end
    local desired = want[id] == true
    local target = desired
    if canReadKey == nil then
        local ok = pcall(readKey, body)
        canReadKey = ok
        LF.log("POSTURE crouch-key prediction " .. (ok and "available" or "UNAVAILABLE (NPCs may twitch on the crouch key)"))
    end
    if canReadKey then
        if keyFrame ~= LF.frame then keyFrame, keyDown = LF.frame, body:isCrouchButtonPressed() == true end
        if keyDown then target = not desired end
    end
    if body:isSneaking() ~= target then body:setSneaking(target) end
end

LF.on("OnPlayerUpdate", "Posture", function(body)
    if quiet(body) then return end
    LF.guard("posture", onPlayerUpdate, body)
end, 32)
