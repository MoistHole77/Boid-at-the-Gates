-- Living Front: talking to your men.
--
-- Right-click a soldier: "Talk to <him>". A chat window opens; type, press Enter, and he
-- answers in it (and over his head, briefly). He answers as himself (LF_Persona: his age, home,
-- trade, family, traits, way of talking, what he thinks of the war, his friend in the squad),
-- from his state now (morale, wounds, what his unit is doing) and from what he has seen
-- (LF_Memory). With the LF bridge running, a language model plays him; without it, he answers
-- plainly from what he last saw.
-- When the window closes, the conversation is summed up in a short note in his record, with
-- whether he now thinks better or worse of you (LF.Persona.remember) - so next time he
-- remembers. Within a conversation, the last exchanges go back to the model each turn.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/World/LF_Chasm"
require "LivingFront/Soldier/LF_Memory"
require "LivingFront/Soldier/LF_Persona"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISTextEntryBox"
require "ISUI/ISButton"

LF.Talk = LF.Talk or {}

local CFG = {
    keep = 8,               -- exchanges sent back to the model within a conversation
    W = 820, H = 520, PAD = 12,
    INFO_W = 270,           -- the panel on the left: what you know about him
    talkRange = 2.6,        -- tiles: close enough to talk with E
    talkCone = 0.55,        -- ... and roughly in front of you (cos of the angle off your facing)
}

-- ---- what he says with no language model ----------------------------------------------------------

local function firstPerson(s)
    s = s:gsub("from your squad", "from our squad"):gsub("Your squad", "Our squad"):gsub("your squad", "our squad")
    s = s:gsub("You were wounded", "I was wounded"):gsub("your side", "our side")
    return s
end

local GREET = { GER = "Jawohl.", SOV = "Da, comrade." }

-- What he asks about: the first topic whose words are in the question.
local TOPICS = {
    { "name", { "your name", "who are you", "called" } },
    { "home", { "where are you from", "where you from", "hometown", "home town", "born", "from?" } },
    { "family", { "family", "wife", "mother", "mum", "mom", "children", "kids", "sweetheart", "girl", "brother",
                  "sister", "married", "parents", "father", "letters" } },
    { "job", { "job", "work", "before the war", "trade", "for a living" } },
    { "past", { "how long", "served", "serving", "join", "enlist", "called up", "experience", "veteran", "been in" } },
    { "age", { "how old", "your age" } },
    { "fear", { "afraid", "fear", "scared", "frightened" } },
    { "want", { "want", "wish", "after the war", "dream", "hope" } },
    { "friend", { "friend", "mates", "team", "squad", "the others", "the men", "people in", "get along" } },
    { "war", { "war", "win", "lose", "winning", "losing", "fight for", "politic", "party", "stalin", "hitler",
               "fuhrer", "führer", "think of", "worth it" } },
    { "seen", { "happen", "seen", "see anything", "news", "report", "what's going on", "whats going on", "lately" } },
    { "mood", { "how are", "how's it", "hows it", "how is it", "feel", "doing", "morale", "okay", "alright", "all right" } },
}

local function topicOf(text)
    local t = " " .. text:lower() .. " "
    for _, tp in ipairs(TOPICS) do
        for _, w in ipairs(tp[2]) do
            if t:find(w, 1, true) then return tp[1] end
        end
    end
    return nil
end

-- What he says with no language model: an answer on what you asked about, in his own words,
-- or else what he last saw, or a line in his own voice.
local function plainReply(rec, mems, n, text)
    local topic = topicOf(text or "")
    if topic == "name" then return LF.Units.title(rec) .. ", sir." end
    if topic == "seen" or (n == 1 and not topic and #mems > 0) then
        if #mems == 0 then return (GREET[rec.faction] or "") .. " Nothing to report - it has been quiet." end
        local said = {}
        for i = 1, math.min(2, #mems) do said[#said + 1] = firstPerson(mems[i]) end
        return table.concat(said, " ")
    end
    local line = topic and LF.Persona.say(rec, topic)
    if line then return line end
    if n == 1 then return (GREET[rec.faction] or "Yes?") .. " " .. LF.Persona.say(rec, "mood") end
    return LF.Persona.line(rec, n)
end

local function doing(rec)
    local u = rec.squad and LF.Units.get(rec.squad)
    if not u then return "" end
    local t = u.objTask
    local obj = t and LF.Objective and LF.Objective.get(t.obj)
    if t and t.kind == "take" and obj then return "taking " .. obj.name end
    if t and t.kind == "hold" and obj then return "holding " .. obj.name end
    local M = LF.March and LF.March.get(u.id)
    if M and not M.arrived then return "on the march" end
    return u.stance or ""
end

-- ---- a conversation ---------------------------------------------------------------------------------

local sessions = {}         -- record id -> { lines = { {who, text} }, exchanges = { {you, him} }, waiting }
Events.OnInitGlobalModData.Add(function() sessions = {} end)

local function session(id)
    local s = sessions[id]
    if not s then s = { lines = {}, exchanges = {} }; sessions[id] = s end
    return s
end

local function addLine(id, who, text)
    local s = session(id)
    s.lines[#s.lines + 1] = { who = who, text = text }
    while #s.lines > 60 do table.remove(s.lines, 1) end
end

-- You say text to him; his answer comes into the conversation (and the window, if open).
function LF.Talk.say(id, text)
    local rec = LF.Records.get(id)
    if not (rec and rec.alive) then return end
    local s = session(id)
    local title = LF.Units.title(rec)
    addLine(id, "You", text)
    LF.log("TALK you to " .. title .. " #" .. id .. ": " .. text)
    local mems = LF.Memory.of(rec, 6)
    local fallback = plainReply(rec, mems, #s.exchanges + 1, text)
    local function answer(words, how)
        s.waiting = nil
        s.partial = nil
        s.exchanges[#s.exchanges + 1] = { you = text, him = words }
        while #s.exchanges > CFG.keep do table.remove(s.exchanges, 1) end
        addLine(id, title, words)
        LF.log("TALK " .. title .. " #" .. id .. (how and (" (" .. how .. ")") or "") .. ": " .. words)
        if LF.Tactics and LF.Tactics.say then LF.Tactics.say(id, words) end
    end
    if LF.Chasm.alive() then
        local prof = LF.Memory.profile(rec)
        prof.doing = doing(rec)
        s.waiting = true
        local sent = LF.Chasm.request({ kind = "talk", soldier = prof, persona = LF.Persona.card(rec), memories = mems,
                                        history = s.exchanges, player_text = text, fallback = fallback },
            function(ans)
                if ans and ans.text and ans.text ~= "" then answer(ans.text, ans.worded == "yes" and "language model" or nil)
                else answer(fallback, "plain") end
            end, id,
            function(ans)                   -- (his words so far, as the model writes them)
                if s.waiting and ans.text and ans.text ~= "" then
                    s.partial = ans.text
                    if LF.Tactics and LF.Tactics.say then LF.Tactics.say(id, ans.text, nil, true) end
                end
            end)
        if sent then return end
        s.waiting = nil
    end
    answer(fallback, "plain")
end

-- The conversation is over: sum it up in a note he keeps.
local function finish(id)
    local s = sessions[id]
    sessions[id] = nil
    if not s or #s.exchanges == 0 then return end
    local rec = LF.Records.get(id)
    if not (rec and rec.alive) then return end
    local first = s.exchanges[1].you
    local plainNote = "The officer talked with him" .. (first and (" (he asked: \"" .. first:sub(1, 60) .. "\")") or "") .. "."
    local function keep(note, delta)
        LF.Persona.remember(rec, note, delta)
        LF.log("TALK " .. LF.Units.title(rec) .. " #" .. id .. " remembers: " .. note .. " (trust " .. tostring(rec.talk.trust) .. ")")
    end
    if LF.Chasm.alive() then
        local sent = LF.Chasm.request({ kind = "summarize", soldier = LF.Memory.profile(rec), persona = LF.Persona.card(rec),
                                        history = s.exchanges, fallback = plainNote },
            function(ans)
                if ans and ans.text and ans.text ~= "" then
                    local d = tonumber((tostring(ans.trust or "0"):gsub("^%+", ""))) or 0
                    keep(ans.text, math.max(-1, math.min(1, d)))
                else keep(plainNote, 0) end
            end)
        if sent then return end
    end
    keep(plainNote, 0)
end

-- ---- what you know about him (the panel beside the conversation) ------------------------------------
-- Only what an officer standing in front of him would know: what he can see (rank, kit, wounds,
-- what the man is doing and how he bears up), what he knows of his own units, and what has
-- passed between the two of them. Not his past, his kills, his thoughts - unless he told you.

local ROLE = { lt = "platoon commander", ssgt = "platoon sergeant", rto = "radio operator",
               gunner = "machine gunner", assistant = "assistant gunner", ammo = "ammunition bearer" }
local REGARD = { [-3] = "resents you", [-2] = "doesn't trust you", [-1] = "is wary of you", [0] = "doesn't know you well",
                 [1] = "is warming to you", [2] = "trusts you", [3] = "would follow you anywhere" }

local function roleOf(rec)
    local r = ROLE[rec.hqRole or ""] or ROLE[rec.mgRole or ""]
    if r then return r end
    if rec.medic then return "medic" end
    if LF.Units.leads(rec) then return "squad leader" end
    return "rifleman"
end

-- What you can see of his wounds: each hurt part, and how (bleeding, bandaged, broken...).
local function wounds(body)
    local out = {}
    local ok = pcall(function()
        local parts = body:getBodyDamage():getBodyParts()
        for i = 0, parts:size() - 1 do
            local bp = parts:get(i)
            local what = {}
            local function has(f) local ok2, v = pcall(f); return ok2 and v end
            if has(function() return bp:bleeding() end) then what[#what + 1] = "bleeding" end
            if has(function() return bp:haveBullet() end) then what[#what + 1] = "bullet wound" end
            if has(function() return bp:isDeepWounded() end) then what[#what + 1] = "deep wound" end
            if has(function() return bp:getFractureTime() > 0 end) then what[#what + 1] = "broken" end
            if has(function() return bp:isBurnt() end) then what[#what + 1] = "burnt" end
            if #what == 0 and has(function() return bp:scratched() or bp:isCut() end) then what[#what + 1] = "cut" end
            if has(function() return bp:bandaged() end) then what[#what + 1] = "bandaged" end
            if #what > 0 then
                local name = "?"
                pcall(function() name = BodyPartType.getDisplayName(bp:getType()) end)
                out[#out + 1] = name .. ": " .. table.concat(what, ", ")
            end
        end
    end)
    return ok and out or {}
end

local function condition(rec, body)
    if not rec.alive then return "dead" end
    if LF.Medic and LF.Medic.busy and LF.Medic.busy(rec.id) and rec.wounded then return "down, being seen to" end
    local h = body and LF.Combat and LF.Combat.health(body) or 100
    if h >= 95 then return rec.wounded and "wounded, patched up" or "unhurt" end
    if h >= 70 then return "lightly wounded" end
    if h >= 40 then return "wounded" end
    return "badly wounded"
end

local function weaponOf(body)
    local g = body and (body:getPrimaryHandItem() or (LF.Combat and LF.Combat.slungGun(body)))
    local name = nil
    if g then pcall(function() name = g:getDisplayName() end) end
    return name
end

-- The panel, as { {head=...} | {text=..., dim=bool} } rows.
local function infoRows(rec)
    local rows = {}
    local function head(t) rows[#rows + 1] = { head = t } end
    local function line(t, dim) if t and t ~= "" then rows[#rows + 1] = { text = t, dim = dim } end end
    local body = LF.Bodies and LF.Bodies.get(rec.id)
    local u = rec.squad and LF.Units.get(rec.squad)
    local plt = u and u.platoon and LF.Units.get(u.platoon)
    head(LF.Records.fullName(rec))
    line((rec.faction == "GER" and "Wehrmacht" or rec.faction == "SOV" and "Red Army" or "") .. " - " .. LF.Units.title(rec):gsub(" .*", "") .. ", " .. roleOf(rec))
    if u then
        head("Unit")
        line(u.kind == "hq" and "Platoon headquarters" or (u.name:gsub("^.* / ", "")))
        if plt then line((plt.name:gsub("^.* / ", ""))) end
        local cid = u.kind ~= "hq" and LF.Units.commander(u)
        local c = cid and cid ~= rec.id and LF.Records.get(cid)
        if c then line("Squad leader: " .. LF.Units.title(c)) end
    end
    head("Now")
    local d = doing(rec)
    line(d ~= "" and ((d:gsub("^%l", string.upper))) or "Standing by")
    if LF.Morale then line("Morale: " .. LF.Morale.word(LF.Morale.get(rec))) end
    line(weaponOf(body) and ("Armed with: " .. weaponOf(body)))
    head("Condition")
    line((condition(rec, body):gsub("^%l", string.upper)))
    for _, w in ipairs(body and wounds(body) or {}) do line(w, true) end
    head("Between you")
    local t = rec.talk
    local n = t and t.n or 0
    if n == 0 then line("You haven't spoken with him before.", true)
    else
        line("Spoken with him " .. (n == 1 and "once" or (n .. " times")) .. " before")
        line("He " .. (REGARD[math.max(-3, math.min(3, t.trust or 0))] or REGARD[0]))
        for i = #(t.notes or {}), 1, -1 do line(t.notes[i], true) end
    end
    return rows
end

-- ---- the window -----------------------------------------------------------------------------------------

LF_TalkWindow = ISCollapsableWindow:derive("LF_TalkWindow")
local open = {}

function LF_TalkWindow:new(x, y, id)
    local o = ISCollapsableWindow.new(self, x, y, CFG.W, CFG.H)
    o.recId = id
    o.resizable = false
    local rec = LF.Records.get(id)
    o.title = "Talking to " .. (rec and LF.Units.title(rec) or "?")
    return o
end

function LF_TalkWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local eh = 24
    local bw = 64
    self.chatX = CFG.PAD * 2 + CFG.INFO_W
    self.entry = ISTextEntryBox:new("", self.chatX, self.height - eh - CFG.PAD, self.width - self.chatX - CFG.PAD * 2 - bw, eh)
    self.entry:initialise()
    self.entry:instantiate()
    local win = self
    self.entry.onCommandEntered = function() win:send() end
    self:addChild(self.entry)
    self.button = ISButton:new(self.width - CFG.PAD - bw, self.height - eh - CFG.PAD, bw, eh, "Say", self, LF_TalkWindow.send)
    self.button:initialise()
    self:addChild(self.button)
    self.top = th + CFG.PAD
end

function LF_TalkWindow:send()
    local t = self.entry:getText()
    if not (t and t:match("%S")) then return end
    self.entry:setText("")
    LF.Talk.say(self.recId, t)
    pcall(function() self.entry:focus() end)
end

-- Wrap text to a pixel width.
local function wrapPx(text, font, width)
    local tm = getTextManager()
    local lines, line = {}, ""
    for word in string.gmatch(text, "%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if tm:MeasureStringX(font, try) > width and line ~= "" then
            lines[#lines + 1] = line
            line = word
        else line = try end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

function LF_TalkWindow:prerender()
    ISCollapsableWindow.prerender(self)
    if self.isCollapsed then return end
    local rec = LF.Records.get(self.recId)
    local font = UIFont.Small
    local tm = getTextManager()
    local fh = tm:getFontHeight(font)
    local cx = self.chatX or CFG.PAD
    local w = self.width - cx - CFG.PAD
    local bottom = self.height - 24 - CFG.PAD * 2
    local s = sessions[self.recId]
    -- What you know about him, on the left.
    if rec then
        self:drawRect(CFG.PAD, self.top, CFG.INFO_W, self.height - self.top - CFG.PAD, 0.35, 0, 0, 0)
        self:drawRectBorder(CFG.PAD, self.top, CFG.INFO_W, self.height - self.top - CFG.PAD, 0.5, 0.6, 0.6, 0.6)
        local y = self.top + 6
        local limit = self.height - CFG.PAD - fh
        for _, row in ipairs(infoRows(rec)) do
            if y > limit then break end
            if row.head then
                y = y + (y > self.top + 6 and 6 or 0)
                self:drawText(row.head, CFG.PAD + 8, y, 0.95, 0.85, 0.55, 1, UIFont.Medium)
                y = y + tm:getFontHeight(UIFont.Medium)
            else
                for _, part in ipairs(wrapPx(row.text, font, CFG.INFO_W - 24)) do
                    if y > limit then break end
                    local c = row.dim and 0.72 or 0.95
                    self:drawText(part, CFG.PAD + 12, y, c, c, c, 1, font)
                    y = y + fh
                end
            end
        end
    end
    self:drawRect(cx, self.top, w, bottom - self.top + fh, 0.2, 0, 0, 0)
    -- Lay out the conversation from the bottom up; the oldest lines scroll off the top.
    local rows = {}
    local shown = s and s.lines or {}
    if s and s.waiting then
        if s.partial then
            -- He is still speaking: his words so far, as one more line of the conversation.
            local rec2 = LF.Records.get(self.recId)
            shown = {}
            for i, l in ipairs(s.lines) do shown[i] = l end
            shown[#shown + 1] = { who = rec2 and LF.Units.title(rec2) or "?", text = s.partial .. " ..." }
        else rows[#rows + 1] = { text = "...", r = 0.7, g = 0.7, b = 0.7 } end
    end
    for i = #shown, 1, -1 do
        local l = shown[i]
        local you = l.who == "You"
        local body = wrapPx(l.text, font, w - 12)
        for j = #body, 1, -1 do rows[#rows + 1] = { text = body[j], x = 12, r = 1, g = 1, b = 1 } end
        rows[#rows + 1] = { text = l.who .. ":", r = you and 0.6 or 0.95, g = you and 0.85 or 0.85, b = you and 1 or 0.55 }
        if (#rows + 1) * fh > bottom - self.top then break end
    end
    local y = bottom - fh
    for _, row in ipairs(rows) do
        if y < self.top then break end
        self:drawText(row.text, cx + 6 + (row.x or 0), y, row.r, row.g, row.b, 1, font)
        y = y - fh
    end
    if not s or #s.lines == 0 then
        local hint = rec and rec.alive and "Type and press Enter to speak to him." or "He can't answer you."
        self:drawText(hint, cx + 6, self.top + 4, 0.7, 0.7, 0.7, 1, font)
    end
end

function LF_TalkWindow:close()
    open[self.recId] = nil
    LF.guard("talk finish", finish, self.recId)
    self:setVisible(false)
    self:removeFromUIManager()
end

function LF.Talk.open(id, keyed)
    if open[id] then open[id]:bringToTop(); return end
    local x = math.min(getMouseX() + 20, getCore():getScreenWidth() - CFG.W - 10)
    local y = math.min(math.max(10, getMouseY() - 80), getCore():getScreenHeight() - CFG.H - 10)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    if keyed then x, y = math.floor((sw - CFG.W) / 2), math.floor(sh - CFG.H - sh * 0.12) end
    x, y = math.max(10, x), math.max(10, y)
    local w = LF_TalkWindow:new(x, y, id)
    w:initialise()
    w:addToUIManager()
    open[id] = w
    pcall(function() w.entry:focus() end)
end

-- He walked off, died, or you walked away: the conversation ends.
Events.OnTick.Add(function()
    if LF.tick % 60 ~= 31 then return end
    local p = getPlayer()
    for id, w in pairs(open) do
        local rec = LF.Records.get(id)
        local b = LF.Bodies and LF.Bodies.get(id)
        local far = b and p and LF.dist(b:getX(), b:getY(), p:getX(), p:getY()) > 12
        if not (rec and rec.alive) or not b or far then
            LF.guard("talk close", function() w:close() end)
        end
    end
end)

-- ---- E to talk ---------------------------------------------------------------------------------------
-- The soldier you're next to and facing: "[E] Talk" over his head, and E opens the conversation.

local facingId = nil

local function talkTarget()
    local p = getPlayer()
    if not p or p:isDead() or p:getVehicle() or p:isAiming() then return nil end
    local px, py, pz = p:getX(), p:getY(), math.floor(p:getZ())
    local fx, fy = 0, 0
    pcall(function() local v = p:getForwardDirection(); fx, fy = v:getX(), v:getY() end)
    local best, bestScore = nil, nil
    for id, body in pairs(LF.Bodies.all()) do
        if math.floor(body:getZ()) == pz and not body:isDead() then
            local dx, dy = body:getX() - px, body:getY() - py
            local d = math.sqrt(dx * dx + dy * dy)
            if d <= CFG.talkRange then
                local dot = d > 0.01 and (dx * fx + dy * fy) / d or 1
                local rec = LF.Records.get(id)
                if dot >= CFG.talkCone and rec and rec.alive and rec.faction ~= "CIV" and not rec.captured then
                    local score = d - dot          -- (nearest, most in front)
                    if not bestScore or score < bestScore then best, bestScore = id, score end
                end
            end
        end
    end
    return best
end

local function typing()
    for _, w in pairs(open) do
        local f = false
        pcall(function() f = w.entry:isFocused() end)
        if f then return true end
    end
    return false
end

Events.OnTick.Add(function()
    if LF.tick % 6 ~= 2 then return end
    facingId = LF.try("talk target", talkTarget)
end)

Events.OnKeyPressed.Add(function(key)
    local want = (Keyboard and Keyboard.KEY_E) or 18
    pcall(function() want = getCore():getKey("Interact") end)
    if key ~= want or not facingId or typing() then return end
    if open[facingId] then open[facingId]:bringToTop(); return end
    LF.guard("talk key", LF.Talk.open, facingId, true)
end)

Events.OnPostUIDraw.Add(function()
    if not facingId or open[facingId] then return end
    LF.guard("talk prompt", function()
        local body = LF.Bodies.get(facingId)
        if not (body and body:isOnScreen()) then return end
        local x, y, z = body:getX(), body:getY(), body:getZ()
        local sx, sy = isoToScreenX(0, x, y, z), isoToScreenY(0, x, y, z)
        local zoom = getCore():getZoom(0)
        local key = "E"
        pcall(function() key = Keyboard.getKeyName(getCore():getKey("Interact")) end)
        local text = "[" .. key .. "] Talk"
        local tm = getTextManager()
        local ty = sy - 112 / zoom
        tm:DrawStringCentre(UIFont.Small, sx + 1, ty + 1, text, 0, 0, 0, 0.8)
        tm:DrawStringCentre(UIFont.Small, sx, ty, text, 1, 0.9, 0.55, 1)
    end)
end)

-- Right-click: "Talk to ..." for the soldiers right there.
local function onMenu(playerNum, context, worldObjects, test)
    if test then return end
    local sq = LF.try("talk square", function() return worldObjects[1]:getSquare() end)
    if not sq or not LF.Inspect then return end
    for _, f in ipairs(LF.Inspect.near(sq:getX(), sq:getY(), sq:getZ())) do
        local rec = LF.Records.get(f.id)
        if rec and rec.alive and rec.faction ~= "CIV" then
            local id = f.id
            context:addOption("Talk to " .. LF.Units.title(rec), nil, function() LF.Talk.open(id) end)
        end
    end
end
Events.OnFillWorldObjectContextMenu.Add(function(...) LF.guard("talk menu", onMenu, ...) end)
