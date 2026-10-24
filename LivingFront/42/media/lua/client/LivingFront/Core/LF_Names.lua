-- Living Front: period names by nationality.
--
-- The game's own name generator only knows American names. Germans get German names; Soviets
-- and civilians (the war is on Soviet soil) get Russian and Ukrainian ones, with Russian
-- surnames in the feminine form for women (Ivanov -> Ivanova, Dobrinsky -> Dobrinskaya).
-- Names are plain ASCII so every game font can draw them (Mueller, not M-umlaut-ller).
-- To change who gets which names, edit LF.Names.byFaction.

LF = LF or {}
LF.Names = LF.Names or {}

local GERMAN = {
    male = { "Hans", "Karl", "Friedrich", "Wilhelm", "Otto", "Heinrich", "Ernst", "Walter", "Paul", "Hermann",
             "Kurt", "Werner", "Gerhard", "Helmut", "Guenther", "Josef", "Franz", "Fritz", "Erich", "Rudolf",
             "Johann", "Georg", "Ludwig", "Alfred", "Heinz", "Horst", "Herbert", "Willi", "Albert", "Bruno",
             "Max", "Emil", "Konrad", "Siegfried", "Dieter", "Gustav", "Arno", "Erwin", "Rolf", "Hugo" },
    female = { "Anna", "Maria", "Elisabeth", "Margarete", "Gertrud", "Erna", "Hildegard", "Ilse", "Irmgard", "Ursula",
               "Helga", "Charlotte", "Frieda", "Lieselotte", "Edith", "Hertha", "Kaethe", "Elfriede", "Ruth", "Gerda" },
    surname = { "Mueller", "Schmidt", "Schneider", "Fischer", "Weber", "Meyer", "Wagner", "Becker", "Schulz",
                "Hoffmann", "Koch", "Bauer", "Richter", "Klein", "Wolf", "Schroeder", "Neumann", "Schwarz",
                "Zimmermann", "Braun", "Krueger", "Hofmann", "Hartmann", "Lange", "Schmitt", "Werner", "Krause",
                "Meier", "Lehmann", "Koehler", "Vogel", "Fuchs", "Keller", "Frank", "Berger", "Kaiser", "Lorenz",
                "Baumann", "Graf", "Seidel", "Brandt", "Haas", "Schuster", "Dietrich", "Kuhn", "Jung", "Pohl",
                "Engel", "Horn", "Busch", "Sommer", "Winter", "Ziegler", "Roth", "Beck", "Lang", "Walter" },
}

local RUSSIAN = {
    male = { "Ivan", "Aleksandr", "Nikolai", "Mikhail", "Sergei", "Dmitri", "Andrei", "Vasily", "Pyotr", "Aleksei",
             "Fyodor", "Grigory", "Yakov", "Pavel", "Boris", "Viktor", "Konstantin", "Leonid", "Yuri", "Stepan",
             "Semyon", "Timofei", "Anatoly", "Vladimir", "Georgy", "Matvei", "Kirill", "Arkady", "Ilya", "Maksim",
             "Bogdan", "Taras", "Ostap", "Vitaly", "Yevgeny", "Roman", "Gennady", "Valentin", "Oleg", "Fedot" },
    female = { "Anna", "Maria", "Yelena", "Olga", "Tatyana", "Natalya", "Irina", "Svetlana", "Lyudmila", "Galina",
               "Valentina", "Nina", "Zoya", "Vera", "Nadezhda", "Lyubov", "Klavdia", "Raisa", "Antonina", "Yevdokia",
               "Praskovya", "Lidia", "Tamara", "Zinaida", "Darya", "Ksenia", "Polina", "Sofia", "Yekaterina",
               "Aleksandra", "Oksana", "Marfa", "Agafya", "Varvara", "Anastasia", "Larisa", "Yulia", "Faina" },
    surname = { "Ivanov", "Smirnov", "Kuznetsov", "Popov", "Vasiliev", "Petrov", "Sokolov", "Mikhailov", "Novikov",
                "Fedorov", "Morozov", "Volkov", "Alekseev", "Lebedev", "Semenov", "Egorov", "Pavlov", "Kozlov",
                "Stepanov", "Nikolaev", "Orlov", "Andreev", "Makarov", "Nikitin", "Zakharov", "Zaitsev", "Soloviev",
                "Borisov", "Yakovlev", "Grigoriev", "Romanov", "Vorobiev", "Sergeev", "Frolov", "Belov", "Polyakov",
                "Karpov", "Rybakov", "Gusev", "Titov", "Kiselev", "Ilyin", "Medvedev", "Komarov", "Baranov",
                "Dobrinsky", "Kovalenko", "Shevchenko", "Bondarenko", "Tkachenko", "Kravchuk", "Melnyk", "Savchenko",
                "Rudenko", "Lysenko", "Moroz", "Kovalchuk", "Golubev", "Tarasov", "Ponomarev" },
}

LF.Names.byFaction = { GER = GERMAN, SOV = RUSSIAN, CIV = RUSSIAN }

local function pick(list) return list[ZombRand(#list) + 1] end

-- Feminine form of a Russian surname; Ukrainian -enko, -uk, -yk and the like do not change.
local function feminine(surname)
    local tail2 = surname:sub(-2)
    if tail2 == "ov" or tail2 == "ev" or tail2 == "in" then return surname .. "a" end
    if surname:sub(-3) == "sky" then return surname:sub(1, -2) .. "aya" end
    return surname
end

-- forename, surname for a new person of this faction (nil if the faction has no list).
function LF.Names.random(factionKey, female)
    local set = LF.Names.byFaction[factionKey]
    if not set then return nil end
    local forename = pick(female and set.female or set.male)
    local surname = pick(set.surname)
    if female and set == RUSSIAN then surname = feminine(surname) end
    return forename, surname
end
