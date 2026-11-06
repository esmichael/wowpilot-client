-- Testes do WowPilot. Rodar: python3 tests/run_tests.py
-- Cada teste recebe um WowPilotDB limpo (o runner recarrega o addon por teste).

local T = {}

local function boot()
    fire("ADDON_LOADED", "WowPilot")
    fire("PLAYER_LOGIN")
    run_timers()
end

T["login limpa chaves antigas e não recarrega a UI"] = function()
    _G.WowPilotDB = { last = { x = 1 }, history = { 1 }, chars = {}, chatChannels = {}, button = {}, live = { corner = "TOPRIGHT", throttle = 45, cell = 3 } }
    boot()
    assert(RELOADS == 0)
    assert(WowPilotDB.last == nil and WowPilotDB.history == nil and WowPilotDB.chars == nil and WowPilotDB.chatChannels == nil)
    assert(WowPilotDB.live.interval == 45 and WowPilotDB.live.corner == nil and WowPilotDB.live.cell == nil, "intervalo herdado do throttle")
end

T["link com campos vazios: enchant/gem/bonus nas posições certas"] = function()
    boot()
    local p = NS.parseLink("|cffa335ee|Hitem:271483:7534:240910::::::90:262::2:2:111:222|h[Elmo]|h|r")
    assert(p.id == 271483 and p.enchant == 7534 and p.gems[1] == 240910)
    assert(#p.bonus == 2 and p.bonus[1] == 111)
    p = NS.parseLink("|Hitem:251148::::::::90:262::2:5:12820:13438:6652:13668:12698|h")
    assert(p.enchant == nil and table.concat(p.bonus, ",") == "12820,13438,6652,13668,12698")
    assert(NS.parseLink("|Hbattlepet:1:2|h").id == nil, "mascote não é item")
end

T["chat: grava canais privados/grupo, ignora secreto e canal público"] = function()
    boot()
    fire("CHAT_MSG_WHISPER", "bora +8?", "Tank-Reinoteste", "", "", "", "", 0, 0, "", 0, 1, "", 0)
    fire("CHAT_MSG_BN_WHISPER", "on?", "|Kq1|k", "", "", "", "", 0, 0, "", 0, 2, "", 55)
    fire("CHAT_MSG_PARTY", "SECRET", "X")
    fire("CHAT_MSG_CHANNEL", "WTS boost", "Spam", "", "2. Comércio")
    fire("CHAT_MSG_GUILD", "gg", "Fulano")
    local c = WowPilotDB.chat
    assert(#c == 3, "esperado 3, veio " .. #c)
    assert(c[2].from == "Amigo#1234", "BNet deve usar battleTag")
end

T["grupo: inspeciona quem está perto, marca quem está longe"] = function()
    _G.UnitExists = function(u) return u == "party1" or u == "party2" end
    _G.UnitGUID = function(u) return ({ party1 = "G1", party2 = "G2", player = "P" })[u] end
    _G.UnitFullName = function(u) return ({ party1 = "Tank", party2 = "Dps" })[u], "Reinoteste" end
    _G.UnitGroupRolesAssigned = function(u) return u == "party1" and "TANK" or "DAMAGER" end
    _G.CanInspect = function(u) return u == "party1" end
    _G.NotifyInspect = function(u) fire("INSPECT_READY", UnitGUID(u)) end  -- servidor responde na hora
    _G.GetInspectSpecialization = function() return 73 end
    _G.GetSpecializationInfoByID = function() return 73, "Proteção" end
    _G.C_PaperDollInfo = { GetInspectItemLevel = function() return 281.5 end }
    _G.RaiderIO = { GetProfile = function() return { mythicKeystoneProfile = { currentScore = 1890 } } end }
    boot()
    local g = WowPilotDB.group.members
    assert(g.G1.inspectStatus == "ok" and g.G1.ilvl == 281.5 and g.G1.spec == "Proteção" and g.G1.rio == 1890)
    assert(g.G2.inspectStatus == "fora de alcance" and g.G2.role == "DAMAGER")
    _G.RaiderIO = nil
end

T["grupos: sessão registra entradas, saídas, local e fecha ao sair do grupo"] = function()
    local roster = { party1 = "Tank", party2 = "Dps" }
    _G.IsInGroup = function() return next(roster) ~= nil end
    _G.UnitExists = function(u) return roster[u] ~= nil end
    _G.UnitGUID = function(u) return roster[u] and ("G" .. roster[u]) or (u == "player" and "P" or nil) end
    _G.UnitFullName = function(u) if u == "player" then return "Fulano", "Reinoteste" end return roster[u], "Reinoteste" end
    _G.UnitClass = function(u) return "?", u == "party1" and "WARRIOR" or "MAGE" end
    _G.UnitGroupRolesAssigned = function(u) return u == "party1" and "TANK" or "DAMAGER" end
    _G.GetInstanceInfo = function() return "Fenda de Pedra", "party", 8, "Mítica+" end
    local CM = _G.C_ChallengeMode
    _G.C_ChallengeMode = setmetatable({ GetActiveKeystoneInfo = function() return 7, {} end }, { __index = CM })
    boot()
    run_timers()
    local gs = WowPilotDB.groups
    assert(#gs == 1 and not gs[1].stop, "sessão aberta após login")
    local g = gs[1]
    assert(g.members["Tank-Reinoteste"].class == "WARRIOR" and g.members["Tank-Reinoteste"].role == "TANK")
    assert(g.places[1] == "Fenda de Pedra (Mítica+)", tostring(g.places[1]))
    fire("CHALLENGE_MODE_START")
    assert(g.places[2] == "Fenda de Pedra +7", tostring(g.places[2]))
    roster.party2 = "Healer"; fire("GROUP_ROSTER_UPDATE")
    assert(g.members["Dps-Reinoteste"].left, "Dps saiu")
    assert(g.members["Healer-Reinoteste"] and not g.members["Healer-Reinoteste"].left, "Healer entrou")
    roster = {}; fire("GROUP_ROSTER_UPDATE")
    assert(g.stop and g.members["Tank-Reinoteste"].left, "sessão fechada")
    roster = { party1 = "Outro" }; fire("GROUP_ROSTER_UPDATE")
    assert(#gs == 2 and not gs[2].stop and gs[2].members["Outro-Reinoteste"], "novo grupo")
    -- Live manda só as sessões alteradas
    _G.C_ChallengeMode = CM
end

return T
