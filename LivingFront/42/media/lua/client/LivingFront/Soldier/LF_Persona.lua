-- Living Front: who each soldier is (roadmap B - soldiers with personalities).
--
-- Every man gets a life, rolled once from period tables for his side and kept in his record
-- (rec.persona): age, hometown, what he did before the war, family, two or three traits, how he
-- talks (with example lines a language model can copy), what he thinks of the war, what he
-- wants, what he fears, and a secret. It is seeded by his id, so a man is the same man whether
-- you first speak to him today or next week. Rolled the first time it's needed: soldiers from
-- older saves get one too.
--
-- He also gets ties: a friend in his squad and, now and then, a man he can't stand
-- (LF.Persona.ties). And what passes between you and him - short notes, and whether he thinks
-- better or worse of you - is kept in rec.talk (LF_Talk).
-- Code only: no language model is involved in any of this.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Core/LF_Names"

LF.Persona = LF.Persona or {}

-- ---- a seeded random (the same man every time) -----------------------------------------------------

local function rng(seed)
    local s = (seed * 2654435761 + 12345) % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function(n)
        s = (s * 16807) % 2147483647
        if not n then return s / 2147483647 end
        return s % n + 1
    end
end

local function pick(r, list) return list[r(#list)] end

local function pickN(r, list, n)
    local out, used = {}, {}
    local tries = 0
    while #out < n and tries < 50 do
        tries = tries + 1
        local i = r(#list)
        if not used[i] then used[i] = true; out[#out + 1] = list[i] end
    end
    return out
end

-- ---- tables ----------------------------------------------------------------------------------------

local HOME = {
    GER = { "Hamburg", "Bremen", "Kiel", "Rostock", "Stettin", "Danzig", "Koenigsberg", "a farm in East Prussia",
            "Berlin-Wedding", "Berlin-Spandau", "Leipzig", "Dresden", "Breslau", "Hanover", "Essen", "Dortmund",
            "Cologne", "Frankfurt", "Stuttgart", "Munich", "Nuremberg", "a village in the Black Forest",
            "a village in the Eifel", "Vienna", "Graz", "Linz", "a mining town in Silesia", "Magdeburg" },
    SOV = { "Moscow", "Leningrad", "Kiev", "Kharkov", "Stalingrad", "Gorky", "Kazan", "Sverdlovsk", "Novosibirsk",
            "Tula", "Ryazan", "a kolkhoz near Kursk", "Smolensk", "Minsk", "Odessa", "Tashkent", "Tbilisi", "Baku",
            "Omsk", "a village near Vologda", "Yaroslavl", "a Cossack stanitsa on the Don", "Ivanovo",
            "a fishing village on the Volga", "Arkhangelsk", "Chelyabinsk", "a village in the Ukrainian steppe" },
}

local JOB = {
    GER = { "a farmhand", "an apprentice baker", "a lathe hand at Krupp", "a coal miner in the Ruhr", "a schoolteacher",
            "an insurance clerk", "a university student", "a carpenter", "a butcher's boy", "a tram conductor",
            "a fisherman", "a car mechanic", "a shop assistant", "a railwayman", "a printer's apprentice",
            "a law student", "a brewer", "a postman", "a bricklayer", "a forester", "a waiter in a beer hall",
            "a bank clerk", "a musician in a dance band", "a seminarian who never took his vows" },
    SOV = { "a tractor driver on a kolkhoz", "a lathe operator in a tank factory", "a miner in the Donbass",
            "a village schoolteacher", "a student at the polytechnic", "a railway linesman", "a shepherd",
            "a Volga fisherman", "a Komsomol organizer", "a bookkeeper", "a steelworker in Magnitogorsk",
            "a cobbler", "a lumberjack", "a hospital orderly", "a carpenter", "a truck driver",
            "a stoker on the railways", "a cinema projectionist", "a baker", "a herdsman on a sovkhoz",
            "a factory electrician", "a river boatman" },
}

local TRAITS = { "brave", "cautious", "cheerful", "gloomy", "hot-tempered", "calm", "curious", "stubborn",
                 "fiercely loyal", "cynical", "kind", "hard", "superstitious", "proud", "shy", "talkative",
                 "homesick", "ambitious", "lazy", "devout", "practical", "sentimental", "suspicious", "easygoing" }
local CLASH = { brave = "cautious", cautious = "brave", cheerful = "gloomy", gloomy = "cheerful",
                ["hot-tempered"] = "calm", calm = "hot-tempered", shy = "talkative", talkative = "shy",
                kind = "hard", hard = "kind", lazy = "ambitious", ambitious = "lazy", cynical = "sentimental",
                sentimental = "cynical", suspicious = "easygoing", easygoing = "suspicious" }

-- How he talks, with lines in that voice (the model copies style from examples far better than
-- it follows a description of it).
local STYLES = {
    terse = { "short and blunt; few words, no small talk",
              { "Yes, sir.", "Quiet now. Won't last.", "Don't know. Don't ask me." } },
    rambling = { "rambling; drifts into stories about home and people you've never met",
                 { "Funny you ask, sir - my uncle used to say the same, back when we hauled beets in the autumn, and he'd go on about the weather like it owed him money...",
                   "Well, it's like this, see, and I'm getting to it..." } },
    sardonic = { "dry and sarcastic; jokes darkly about everything",
                 { "Oh, splendid. Another lovely day for a walk in the mud.", "Of course, sir. Whatever headquarters dreams up." } },
    earnest = { "earnest and eager; wants to do well and says so",
                { "I'll do my best, sir. I mean it.", "Should I go now? I can go now." } },
    pious = { "quietly religious; mentions God and luck and prayer",
              { "God willing, we'll see the other side of this.", "I said a prayer for him. It's all I could do." } },
    boastful = { "boastful; exaggerates his own deeds",
                 { "Ten of them? I'd have taken twenty.", "You should have seen me at the river, sir. They'll tell you." } },
    nervous = { "nervous and jumpy; stammers, apologises, keeps glancing about",
                { "Did - did you hear that, sir? Sorry. I'm fine.", "I don't... I'm all right. Really." } },
    earthy = { "plain country speech; sayings from the farm and the village",
               { "Mud's like back home in spring, only nobody's planting anything in it.", "You don't count the chickens till they're plucked, sir." } },
    formal = { "educated and careful; full sentences, a little formal",
               { "If I may, sir, the situation is rather less certain than we are told.", "I would prefer not to speculate, sir." } },
    grim = { "grim and fatalistic; nothing surprises him any more",
             { "We all go sooner or later. Better not to think about which.", "It is what it is, sir." } },
    joker = { "a joker; makes light of things to keep the others going",
              { "Cheer up, sir, at least the lice are warm.", "If they shoot like they cook, we've nothing to worry about." } },
}
local STYLE_KEYS = { "terse", "rambling", "sardonic", "earnest", "pious", "boastful", "nervous", "earthy", "formal",
                     "grim", "joker" }

local WAR = {
    GER = { "does his duty and keeps out of politics", "fights only for the men beside him",
            "thinks the war was lost the day they marched east, and keeps it to himself",
            "believes what the newsreels tell him and repeats it", "is bitter about the generals and the Party men",
            "wants it over, any way at all", "was proud to go and is less proud every month" },
    SOV = { "is a convinced communist and Komsomol member", "fights for the Motherland, not for any commissar",
            "fights for revenge - the Germans burned his village", "keeps his head down and trusts no political officer",
            "fights because there is no going back", "wants it over so he can go home to the land",
            "volunteered in '41 and has seen too much since" },
}

local WANT = { "to get home to his family", "a medal to send home", "revenge for what was done to his people",
               "to see the sea once in his life", "promotion", "to finish his studies after the war",
               "a warm bed and real coffee", "to marry his sweetheart", "a posting away from the front",
               "to prove himself to his father", "to keep his friend alive", "to open a shop of his own one day" }
local FEAR = { "dying alone in a field", "being taken prisoner", "tanks", "being a coward when it counts",
               "losing his friend", "going blind", "another winter", "being forgotten", "the letters from home stopping",
               "the officers", "fire", "being buried alive in a cellar" }
local SECRET = {
    any = { "he hasn't written home in months", "he is terrified every single day", "he can barely read",
            "he once froze and a friend died for it", "he writes poems in a notebook he hides",
            "he took a dead man's watch and still wears it", "he doesn't believe in any of it any more",
            "he ran once, and came back before anyone noticed", "he hopes to be wounded - just badly enough to go home" },
    GER = { "his brother was sent to a camp for something he said in a bar", "he listens to enemy radio when he can" },
    SOV = { "his father was arrested in 1937 and never came back", "he still wears a cross under his shirt",
            "he was in a penal company and won his way out" },
    young = { "he lied about his age to get in" },
}

local AGE = { PVT = { 18, 27 }, CPL = { 21, 31 }, SGT = { 24, 38 }, SSG = { 27, 41 }, LT = { 21, 30 },
              ["1SG"] = { 30, 45 }, CPT = { 25, 38 } }

local PAST = {
    GER = { young = { "joined last spring", "came to the front this year with a replacement draft" },
            old = { "has been in since Poland", "fought in France and has been in Russia since the first day",
                    "has been on the Eastern Front since the summer of '41" } },
    SOV = { young = { "was called up last year", "came from a training regiment this spring" },
            old = { "fought in the Finnish war", "survived the retreat of '41", "was at Moscow in the winter of '41" } },
}

-- ---- making a man --------------------------------------------------------------------------------

local function familyOf(r, rec, age)
    local fk = rec.faction == "SOV" and "SOV" or "GER"
    local function forename(female)
        local f = LF.Names.random(fk, female)
        return f
    end
    local roll = r(100)
    if age >= 26 and roll <= 60 then
        local kids = r(4) - 1
        local wife = forename(true)
        if kids == 0 then return "a wife, " .. wife end
        return "a wife, " .. wife .. ", and " .. (kids == 1 and "a little boy" or (kids .. " children")) .. " he hasn't seen in a year"
    elseif roll <= 75 then
        return "a sweetheart back home, " .. forename(true) .. ", who writes every week"
    elseif roll <= 90 then
        return "his mother and " .. (r(2) == 1 and "two younger sisters" or ("a brother, " .. forename(false) .. ", in the "
            .. (fk == "GER" and "Kriegsmarine" or "Baltic Fleet")))
    end
    return "no one left - his family is gone"
end

-- The man's life: rolled once, then kept.
function LF.Persona.of(rec)
    if not rec then return nil end
    if rec.persona then return rec.persona end
    local r = rng(rec.id * 7919 + 17)
    local side = rec.faction == "SOV" and "SOV" or "GER"
    local band = AGE[rec.rank or "PVT"] or AGE.PVT
    local age = band[1] + r(band[2] - band[1] + 1) - 1
    local traits = { pick(r, TRAITS) }
    local tries = 0
    while #traits < 2 + (r(3) == 1 and 1 or 0) and tries < 40 do
        tries = tries + 1
        local t = pick(r, TRAITS)
        local ok = true
        for _, have in ipairs(traits) do if have == t or CLASH[have] == t then ok = false end end
        if ok then traits[#traits + 1] = t end
    end
    local secrets = {}
    for _, s in ipairs(SECRET.any) do secrets[#secrets + 1] = s end
    for _, s in ipairs(SECRET[side]) do secrets[#secrets + 1] = s end
    if age <= 19 then for _, s in ipairs(SECRET.young) do secrets[#secrets + 1] = s end end
    local p = {
        age = age,
        home = pick(r, HOME[side]),
        job = (rec.rank == "LT" or rec.rank == "CPT") and (side == "GER" and "a law student" or "an engineering student")
            or (rec.hqRole == "surgeon" and "a doctor") or pick(r, JOB[side]),
        family = familyOf(r, rec, age),
        traits = traits,
        style = pick(r, STYLE_KEYS),
        war = pick(r, WAR[side]),
        want = pick(r, WANT),
        fear = pick(r, FEAR),
        secret = pick(r, secrets),
        past = pick(r, (age <= 22) and PAST[side].young or PAST[side].old),
    }
    rec.persona = p
    return p
end

-- ---- ties in his squad -----------------------------------------------------------------------------

-- His friend (and maybe a rival) in his squad: friends are paired off in the order the men
-- joined; a rival is another man, for about one man in three. Kept once given.
function LF.Persona.ties(rec)
    if not (rec and rec.squad) then return nil, nil end
    if rec.friend == nil then
        local ids = {}
        for _, rid in ipairs(LF.Units and LF.Units.members(rec.squad) or {}) do
            local r2 = LF.Records.get(rid)
            if r2 and rid ~= rec.id then ids[#ids + 1] = rid end
        end
        table.sort(ids)
        if #ids == 0 then rec.friend = false
        else
            -- (Prefer a man who has no friend yet, so friendships come in pairs.)
            local r = rng(rec.id * 31 + 7)
            local free = {}
            for _, rid in ipairs(ids) do
                local r2 = LF.Records.get(rid)
                if r2 and (r2.friend == nil or r2.friend == rec.id) then free[#free + 1] = rid end
            end
            local list = #free > 0 and free or ids
            local f = list[r(#list)]
            rec.friend = f
            local fr = LF.Records.get(f)
            if fr and fr.friend == nil then fr.friend = rec.id end
            if r(3) == 1 and #ids > 1 then
                local rv = ids[r(#ids)]
                if rv ~= f then rec.rival = rv end
            end
        end
    end
    return rec.friend or nil, rec.rival
end

-- ---- in words, for the language model --------------------------------------------------------------

local function manTitle(id)
    local r = id and LF.Records.get(id)
    if not r then return nil end
    return (LF.Units and LF.Units.title(r) or LF.Records.fullName(r)), r
end

-- Everything about him a model needs to play him, as a flat table of strings.
function LF.Persona.card(rec)
    local p = LF.Persona.of(rec)
    local st = STYLES[p.style] or STYLES.terse
    local card = {
        age = tostring(p.age), home = p.home, job = p.job, family = p.family,
        traits = table.concat(p.traits, ", "), speech = st[1], examples = st[2],
        war = p.war, want = p.want, fear = p.fear, secret = p.secret, past = p.past,
    }
    local f, rv = LF.Persona.ties(rec)
    local ft, fr = manTitle(f)
    if ft then
        if fr.captured then card.friend = ft .. ", his closest friend, was taken prisoner"
        elseif fr.alive then card.friend = ft .. " is his closest friend in the squad"
        else card.friend = ft .. ", his closest friend, is dead" end
    end
    local rt, rr = manTitle(rv)
    if rt then card.rival = "he can't stand " .. rt .. (rr.alive and "" or " - and feels strange now that he's dead") end
    local t = rec.talk
    if t then
        card.notes = t.notes or {}
        card.trust = t.trust or 0
        card.talks = t.n or 0
    end
    return card
end

-- ---- in his own words, with no language model ---------------------------------------------------------

local WAR_SAY = {
    ["does his duty and keeps out of politics"] = "I do my duty and keep out of politics. Safer that way.",
    ["fights only for the men beside him"] = "Win, lose - I fight for the men beside me. That's all I've got.",
    ["thinks the war was lost the day they marched east, and keeps it to himself"] = "Between us, sir? It was lost the day we marched east.",
    ["believes what the newsreels tell him and repeats it"] = "The newsreels say we're winning, so we're winning.",
    ["is bitter about the generals and the Party men"] = "The generals and the Party men should come up here and fight it themselves.",
    ["wants it over, any way at all"] = "I just want it over, sir. Any way at all.",
    ["was proud to go and is less proud every month"] = "I was proud to go. Less proud every month.",
    ["is a convinced communist and Komsomol member"] = "We'll win. The Party and the people - nothing can stop that.",
    ["fights for the Motherland, not for any commissar"] = "I fight for the Motherland. Not for any commissar.",
    ["fights for revenge - the Germans burned his village"] = "They burned my village. I'll make them pay for every house.",
    ["keeps his head down and trusts no political officer"] = "I keep my head down, comrade. Best way.",
    ["fights because there is no going back"] = "There's no going back. So we go forward.",
    ["wants it over so he can go home to the land"] = "I want it over so I can go home to the land.",
    ["volunteered in '41 and has seen too much since"] = "I volunteered in '41. I've seen too much since.",
}

local MINE = { he = "I", his = "my", him = "me", himself = "myself", hasn = "haven" }
local function mine(s)
    -- (word by word; Kahlua's patterns may lack %f frontiers)
    return (s:gsub("(%a+)", function(w) return MINE[w] end))
end

local function cap(s) return (s:gsub("^%l", string.upper)) end

-- A line about one topic of his life, first person, from his persona (no model needed).
function LF.Persona.say(rec, topic)
    local p = LF.Persona.of(rec)
    if topic == "home" then return "I'm from " .. p.home .. "." end
    if topic == "job" then return "Before all this I was " .. p.job .. "." end
    if topic == "family" then
        if p.family:find("^no one") then return "No one left. My family is gone." end
        return "I've got " .. mine(p.family) .. "."
    end
    if topic == "past" then return "I " .. (p.past:gsub("^has ", "have ")) .. "." end
    if topic == "age" then return "I'm " .. p.age .. ", sir." end
    if topic == "war" then return WAR_SAY[p.war] or ("I " .. mine(p.war) .. ".") end
    if topic == "want" then return "What I want? " .. cap(mine(p.want)) .. "." end
    if topic == "fear" then return "Afraid? Of " .. mine(p.fear) .. ", if you must know." end
    if topic == "friend" then
        local f = LF.Persona.ties(rec)
        local fr = f and LF.Records.get(f)
        if not fr then return "I keep to myself mostly." end
        local who = fr.forename or (LF.Units and LF.Units.title(fr)) or "my friend"
        if fr.captured then return "They took " .. who .. " prisoner. I keep thinking about it." end
        if not fr.alive then return who .. " was my friend. He's dead now." end
        return who .. " looks out for me, and I look out for him. The rest are all right."
    end
    if topic == "mood" then
        local m = LF.Morale and LF.Morale.get(rec) or 60
        if rec.wounded then return "It hurts, sir. I'll manage." end
        if m >= 75 then return "Good, sir. Ready for anything." end
        if m >= 50 then return "All right, sir. Tired." end
        if m >= 30 then return "Not good, sir. Not good at all." end
        return "I can't take much more of this, sir."
    end
    return nil
end

-- One of his own example lines (how he talks).
function LF.Persona.line(rec, n)
    local p = LF.Persona.of(rec)
    local st = STYLES[p.style] or STYLES.terse
    return st[2][(n - 1) % #st[2] + 1]
end

-- After a conversation: a note on it and which way his opinion of you moved (+1, 0, -1).
function LF.Persona.remember(rec, note, delta)
    rec.talk = rec.talk or { notes = {}, trust = 0, n = 0 }
    local t = rec.talk
    t.n = (t.n or 0) + 1
    if note and note ~= "" then
        t.notes[#t.notes + 1] = note
        while #t.notes > 4 do table.remove(t.notes, 1) end
    end
    t.trust = math.max(-3, math.min(3, (t.trust or 0) + (delta or 0)))
end
