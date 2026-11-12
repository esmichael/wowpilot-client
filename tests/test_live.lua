-- Testes do WowPilotLive (snapshot completo via código de pixels + Screenshot).
-- Concatenado após test_wowpilot.lua (usa boot() e T de lá).

local function full(preview)
    return NS.Live.fullPayload(preview)
end

T["/wpilot vender: só com vendedor aberto, vende os itens dos IDs pedidos"] = function()
    boot()
    local sold, said = {}, {}
    local oldC, oldI, oldSay = _G.C_Container, _G.C_Item.GetItemInfo, NS.say
    NS.say = function(m) said[#said + 1] = m end
    _G.C_Container = {
        GetContainerNumSlots = function(b) return b == 0 and 3 or 0 end,
        GetContainerItemInfo = function(_, s) return ({ { itemID = 2589, stackCount = 5 }, { itemID = 4865, stackCount = 1 }, { itemID = 2589, stackCount = 2 } })[s] end,
        UseContainerItem = function(b, s) sold[#sold + 1] = b * 100 + s end,
    }
    _G.C_Item.GetItemInfo = function() return "x", nil, 1, 1, 1, "", "", 20, "", 0, 13 end
    _G.MerchantFrame = { IsShown = function() return false end }
    SlashCmdList.WOWPILOT("vender 2589")
    assert(#sold == 0 and said[#said]:find("vendedor"), "sem vendedor não vende")
    _G.MerchantFrame = { IsShown = function() return true end }
    SlashCmdList.WOWPILOT("vender 2589")
    run_timers()
    assert(#sold == 2 and sold[1] == 1 and sold[2] == 3, "vende os dois espaços do 2589")
    -- protegido: não vende; vendido na mão, compra de volta
    sold = {}
    SlashCmdList.WOWPILOT("proteger 2589")
    SlashCmdList.WOWPILOT("vender 2589,4865")
    run_timers()
    assert(#sold == 1 and sold[1] == 2, "pula o protegido")
    SlashCmdList.WOWPILOT("proteger nada")
    sold = {}
    SlashCmdList.WOWPILOT("vender 2589@0:3,4865@0:1")   -- só a pilha do espaço 3 (o espaço 1 não é 4865)
    run_timers()
    assert(#sold == 1 and sold[1] == 3, "vende pilha por pilha")
    SlashCmdList.WOWPILOT("proteger 2589")
    local bought
    _G.GetNumBuybackItems = function() return 3 end
    _G.GetBuybackItemLink = function() return "|cffffffff|Hitem:2589::::::::|h[Linho]|h|r" end
    _G.BuybackItem = function(i) bought = i end
    NS.guardSale()
    run_timers()
    assert(bought == 3, "recompra o protegido vendido")
    SlashCmdList.WOWPILOT("proteger nada")
    _G.GetNumBuybackItems, _G.GetBuybackItemLink, _G.BuybackItem = nil, nil, nil
    _G.C_Container, _G.C_Item.GetItemInfo, NS.say, _G.MerchantFrame = oldC, oldI, oldSay, nil
end

T["live: captura desenha o código, tira screenshot e restaura CVars"] = function()
    boot()  -- inclui a captura inicial do login (finalizada pelo timer de segurança)
    assert(SCREENSHOTS == 1, "captura inicial após o login: " .. SCREENSHOTS)
    slash("agora")
    assert(SCREENSHOTS == 2, "Screenshot() deveria ser chamado de novo")
    assert(CVARS.screenshotFormat == "png" and CVARS.screenshotQuality == "10")
    fire("SCREENSHOT_SUCCEEDED")
    assert(CVARS.screenshotFormat == "jpg" and CVARS.screenshotQuality == "3", "CVars restauradas")
    assert(not _G.WowPilotLiveCode:IsShown(), "código escondido após a captura")
end

T["live: snapshot completo tem resumo, Vault, moedas, equipamento e bolsas"] = function()
    boot()
    -- equipamento (players) e nomes de itens só vão quando mudam (ou a cada 5 min): o envio do login já os levou,
    -- então o forçado (/wpilot agora) é que os traz de novo
    local js = NS.Live.fullPayload(true, true)
    assert(js:find('"char":"Fulano%-Reinoteste"') and js:find('"spec":"Restauração"'), js)
    assert(js:find('"vault":%[%[1,1,1,1,7,276,276%],%[3,1,2,2,15,276,0%]%]'), "vault: " .. js)
    assert(js:find('"vd":{"claim":0,"prog":{"1":%[%[7,1%]%]},"raid":%[%["Chefe A",14,1%],%["Chefe B",15,2%]%]}'), "vd: " .. js)
    assert(js:find('"cur":%[%[3445,36,900,10,90,0,0%]%]'), "moedas: " .. js)
    assert(js:find('"head":"271483%.7534%.240910%.111%-222%.276"'), "item compacto: " .. js)
    assert(js:find('"me":true'), js)
    assert(js:find('"bags":%["1%*251148%.0%.%.12820%-13438%-6652%-13668%-12698%.276","1%*271483'), "bolsas (sem o mascote): " .. js)
end

T["live: chat vai só uma vez (mensagens novas)"] = function()
    boot()
    run_timers()
    fire("CHAT_MSG_WHISPER", "bora +8?", "Tank-Reinoteste", "", "", "", "", 0, 0, "", 0, 1, "", 0)
    local js = full(false)
    assert(js:find('"chat":%[%[1,%d+,"whisper_in","Tank%-Reinoteste","bora %+8%?",""%]%]'), "chat: " .. js)
    assert(not full(false):find('"chat"'), "mensagem já enviada não repete")
end

T["live: sessões de grupo vão só quando mudam"] = function()
    local roster = { party1 = "Tank" }
    _G.IsInGroup = function() return next(roster) ~= nil end
    _G.UnitExists = function(u) return roster[u] ~= nil end
    _G.UnitFullName = function(u) if u == "player" then return "Fulano", "Reinoteste" end return roster[u], "Reinoteste" end
    boot()
    run_timers()  -- inclui a captura automática que já leva a sessão nova
    assert(not full(false):find('"groups"'), "sessão sem mudança não repete")
    roster.party2 = "Dps"; fire("GROUP_ROSTER_UPDATE")
    local js = full(true)
    assert(js:find('"groups":%[{"id":%d+,"m":%[%[') and js:find('"places":%[%],"raid":0,"start":%d+,"stop":0,"u":%d+}%]'), "groups: " .. js)
    assert(js:find('%["Tank%-Reinoteste","SHAMAN","HEALER","",0,0,%d+,0%]') and js:find('%["Dps%-Reinoteste","SHAMAN"'), "membros: " .. js)
    assert(full(false):find('"Dps%-Reinoteste"') and not full(false):find('"groups"'), "envia uma vez")
end

T["live: M+ traz pontuação por masmorra, runs da semana e afixos"] = function()
    boot()
    local js = full(true)
    assert(js:find('"mp":{"affixes":%["Tirânico"%],"maps":%[%[1,"Repouso do Rei",195,7,0,1800%],%[2,"Fenda",0,0,0,1800%]%],"runs":%[%[1,7,0,0%]%],"score":458}'), "mp: " .. js)
end

T["grupo: desempenho do medidor nativo vai na sessão (fora de combate)"] = function()
    local roster = { party1 = "Tank" }
    _G.IsInGroup = function() return next(roster) ~= nil end
    _G.UnitExists = function(u) return roster[u] ~= nil end
    _G.UnitFullName = function(u) if u == "player" then return "Fulano", "Reinoteste" end return roster[u], "Reinoteste" end
    local data = {
        [0] = { { name = "Tank", totalAmount = 1000, amountPerSecond = 10 }, { name = "Fulano", totalAmount = 200, amountPerSecond = 2 } },
        [2] = { { name = "Fulano", totalAmount = 5000, amountPerSecond = 50 }, { name = "Spy", totalAmount = "SECRET", amountPerSecond = 1 } },
        [4] = { { name = "Fulano", totalAmount = 1000, amountPerSecond = 10 } },
    }
    _G.C_DamageMeter = { GetCombatSessionFromType = function(_, mt) return { combatSources = data[mt] or {} } end,
                         GetSessionDurationSeconds = function() return 100 end }
    boot()
    run_timers()
    NS.capturePerf()
    local g = WowPilotDB.groups[1]
    assert(g.perf and g.perf.dur == 100, "perf gravado")
    local me = g.perf.by["Fulano-Reinoteste"]
    assert(me[2] == 6000 and me[4] == 60 and me[1] == 200, "cura + absorção somadas")
    assert(g.perf.by["Tank-Reinoteste"][3] == 10 and not g.perf.by["Spy-Reinoteste"], "valor secreto fica de fora")
    assert(full(true):find('"perf":{"dur":100,"rows":%[%["Fulano%-Reinoteste",200,6000,2,60%],%["Tank%-Reinoteste",1000,0,10,0%]%]'), full(true))
    _G.C_DamageMeter = nil
end

T["live: SimC só quando o equipamento/spec muda"] = function()
    _G.Simulationcraft = {}
    _G.SimulationcraftAPI = { GetSimcProfile = function() return 'shaman="X"||a' end }
    boot()
    run_timers()  -- captura inicial já levou o SimC
    assert(not full(false):find('"simc"'), "sem mudança, sem SimC")
    fire("PLAYER_EQUIPMENT_CHANGED")
    _G.SimulationcraftAPI = { GetSimcProfile = function() return 'shaman="X"||b' end }
    assert(full(false):find('"simc":"shaman=\\"X\\"|b"'), "SimC novo após troca de item")
    _G.SimulationcraftAPI = nil
end

T["live: em combate adia e captura ao sair"] = function()
    boot()
    run_timers()
    local before = SCREENSHOTS
    local t0 = os.time()
    _G.time = function() return t0 + 120 end  -- passou o intervalo mínimo
    _G.InCombatLockdown = function() return true end
    fire("PLAYER_EQUIPMENT_CHANGED")
    run_timers()
    assert(SCREENSHOTS == before, "não captura em combate")
    _G.InCombatLockdown = function() return false end
    fire("PLAYER_REGEN_ENABLED")
    run_timers()
    assert(SCREENSHOTS == before + 1, "captura após o combate: " .. (SCREENSHOTS - before))
end

T["live: rajada de eventos vira uma captura só"] = function()
    boot()
    run_timers()
    local before = SCREENSHOTS
    fire("SCREENSHOT_SUCCEEDED")
    for _ = 1, 5 do fire("CURRENCY_DISPLAY_UPDATE"); fire("BAG_UPDATE_DELAYED") end
    run_timers()
    assert(SCREENSHOTS - before <= 1, "debounce/throttle: " .. (SCREENSHOTS - before))
end

T["live: páginas de ~7 KB (40 linhas); comprime quando a API existe"] = function()
    boot()
    run_timers()
    local codes, raw, sent = NS.Live.frames(3, string.rep("x", 40000))
    assert(#codes == 6 and raw == 40000 and sent == 40000, "40000 B sem compressão = 6 páginas: " .. #codes)
    assert(codes[1].cols == 255 and codes[1].rows == 40, "página cheia: " .. codes[1].cols .. "x" .. codes[1].rows)
    _G.C_EncodingUtil = { CompressString = function(s) return s:sub(1, 100) end }
    codes, raw, sent = NS.Live.frames(3, string.rep("x", 40000))
    assert(#codes == 1 and sent == 100, "comprimido cabe numa página")
    _G.C_EncodingUtil = nil
end

T["live: /wpilot intervalo muda a frequência; 0 = só manual"] = function()
    boot()
    run_timers()
    slash("intervalo 2")
    assert(WowPilotDB.live.interval == 5, "mínimo 5 s")
    slash("intervalo 5")
    assert(WowPilotDB.live.interval == 5)
    slash("intervalo 0")
    assert(WowPilotDB.live.interval == 0)
    local before = SCREENSHOTS
    fire("SCREENSHOT_SUCCEEDED")
    fire("PLAYER_EQUIPMENT_CHANGED")
    run_timers()
    assert(SCREENSHOTS == before, "sem envio automático")
    slash("agora")
    assert(SCREENSHOTS == before + 1, "manual continua")
end

T["live: código sempre no canto superior esquerdo, paleta na linha 1"] = function()
    boot()
    run_timers()
    local code = NS.Live.encode("abc", { kind = 3 })
    assert(code.color(0, 0) == 0 and code.color(0, 1) == code.white, "padrão de tempo")
    assert(code.color(1, 6) == 0 and code.color(1, 7) == 0 and code.color(1, 5) == code.white and code.color(1, 8) == code.white, "6 em binário nas células 1-8")
    assert(code.color(1, 9) == 0 and code.color(1, 10) == 1 and code.color(1, 72) == 63, "paleta")
    NS.Live.draw(code)
    local f = _G.WowPilotLiveCode
    assert(f.point[1] == "TOPLEFT", "canto: " .. tostring(f.point[1]))
end

T["live: equipamento do grupo inspecionado entra no snapshot"] = function()
    _G.UnitExists = function(u) return u == "party1" end
    _G.UnitGUID = function(u) return ({ party1 = "G1", player = "P" })[u] end
    _G.UnitFullName = function(u) return ({ party1 = "Tank" })[u], "Reinoteste" end
    _G.UnitGroupRolesAssigned = function() return "TANK" end
    _G.CanInspect = function() return true end
    _G.NotifyInspect = function(u) fire("INSPECT_READY", UnitGUID(u)) end
    _G.GetInspectSpecialization = function() return 73 end
    _G.GetSpecializationInfoByID = function() return 73, "Proteção" end
    _G.C_PaperDollInfo = { GetInspectItemLevel = function() return 281.5 end }
    boot()
    local js = NS.Live.fullPayload(true, true)   -- players só quando muda: o login já levou
    assert(js:find('"inspectStatus":"ok"') and js:find('"spec":"Proteção"') and js:find('"name":"Tank%-Reinoteste"'), js)
end


T["raide: lista e inspeciona os membros (sem o próprio jogador)"] = function()
    _G.IsInRaid = function() return true end
    _G.GetNumGroupMembers = function() return 3 end
    _G.UnitExists = function(u) return u == "raid1" or u == "raid2" or u == "raid3" end
    _G.UnitIsUnit = function(a, b) return a == b or (a == "raid1" and b == "player") end
    _G.UnitGUID = function(u) return ({ raid1 = "P", raid2 = "R2", raid3 = "R3", player = "P" })[u] end
    _G.UnitFullName = function(u) return ({ raid2 = "Healer", raid3 = "Longe" })[u], "Reinoteste" end
    _G.UnitGroupRolesAssigned = function() return "DAMAGER" end
    _G.CanInspect = function(u) return u == "raid2" end
    _G.NotifyInspect = function(u) fire("INSPECT_READY", UnitGUID(u)) end
    _G.GetInspectSpecialization = function() return 264 end
    _G.GetSpecializationInfoByID = function() return 264, "Restauração" end
    _G.C_PaperDollInfo = { GetInspectItemLevel = function() return 290 end }
    boot()
    local g = WowPilotDB.group.members
    assert(g.R2 and g.R2.inspectStatus == "ok" and g.R2.ilvl == 290, "raid2 inspecionado")
    assert(g.R3 and g.R3.inspectStatus == "fora de alcance", "raid3 listado mesmo longe")
    assert(not g.P, "o próprio jogador não entra como membro")
    local js = NS.Live.fullPayload(true)
    assert(js:find('"name":"Healer%-Reinoteste"') and js:find('"name":"Longe%-Reinoteste"'), js)
    _G.IsInRaid = function() return false end
end


T["forever: snapshot traz jogo, spec pelos talentos, XP, quests, profissões e nomes dos itens"] = function()
    _G.GetSpecialization = nil
    _G.UnitXP = function() return 1200 end
    _G.UnitXPMax = function() return 5000 end
    _G.GetXPExhaustion = function() return 800 end
    _G.GetRealZoneText = function() return "Floresta de Elwynn" end
    _G.GetSubZoneText = function() return "" end
    _G.GetBindLocation = function() return "Vila Norte" end
    _G.UnitCharacterPoints = function() return 2 end
    _G.GetNumTalentTabs = function() return 3 end
    local tabs = { { "Elemental", 0 }, { "Aperfeiçoamento", 11 }, { "Restauração", 3 } }
    _G.GetTalentTabInfo = function(i) return 100 + i, tabs[i][1], "", 0, tabs[i][2] end  -- formato com id
    _G.C_QuestLog = {
        GetNumQuestLogEntries = function() return 2 end,
        GetInfo = function(i)
            if i == 1 then return { isHeader = true, title = "Elwynn" } end
            return { questID = 33, title = "Lobos na mata", level = 5, isComplete = false }
        end,
        GetQuestObjectives = function() return { { text = "Lobo: 4/8", finished = false } } end,
    }
    _G.C_SkillInfo = { GetNumSkillLines = function() return 3 end, GetSkillLineInfo = function(i)
        if i == 1 then return { name = "Profissões", isHeader = true } end
        if i == 2 then return { name = "Mineração", isHeader = false, rank = 45, modifier = 5, maxRank = 75 } end
        return { name = "Línguas", isHeader = false, rank = 1, maxRank = 1 }
    end }
    _G.GetNumSkillLines = function() return 2 end
    _G.GetSkillLineInfo = function(i)
        if i == 1 then return "Profissões", true end
        return "Mineração", false, false, 45, 0, 5, 75
    end
    _G.GetInventoryItemDurability = function(slot) if slot == 1 then return 20, 80 end if slot == 5 then return 100, 100 end end
    _G.IsResting = function() return true end
    _G.RXPCData = { currentGuideName = "12-14 Floresta de Pinhaprata", currentGuideGroup = "Guia RestedXP Forever (H)", currentStep = 2 }
    _G.RXPCTrackingData = { profileKeys = {}, profiles = { x = { levels = {
        [2] = { deaths = 1, groupExperience = 0, mobs = { Z = { xp = 930, count = 20 } },
                quests = { Z = { [1] = 170, [2] = 30 } }, timestamp = { started = 612, finished = 988 } } } } } }
    _G.UnitFactionGroup = function() return "Horde", "Horda" end
    local units = { target = true }
    _G.UnitExists = function(u) return units[u] or false end
    local guids = { target = "Creature-0-5250-1-123-3246-0000AB12CD", nameplate1 = "Creature-0-1-1-1-3246-01",
                    nameplate2 = "Creature-0-1-1-1-3246-02", nameplate3 = "Creature-0-1-1-1-3255-03" }
    _G.UnitGUID = function(u) return guids[u] end
    _G.UnitName = function(u) if u == "target" then return "Pinote Fugaz" end return "Fulano" end
    _G.UnitHealth = function(u) return u == "target" and 30 or 100 end
    _G.UnitHealthMax = function() return 120 end
    _G.UnitIsDead = function() return false end
    _G.UnitReaction = function() return 4 end
    _G.UnitClassification = function() return "normal" end
    _G.GetPlayerFacing = function() return 1.5708 end
    local entrar = { zone = 1414, x = 56.81, y = 45.47, text = "Entre em Orgrimmar" }
    local steps = {
        { index = 1, active = true, elements = { entrar } },  -- "#completewith": grudado, antes do atual
        { index = 2, active = true, elements = { { text = "Mate |cRXP_ENEMY_Pinotes|r" }, { zone = 1413, x = 55.555, y = 25.1 },
            { zone = 1413, x = 1, y = 1, hidePin = true }, { zone = 1413, x = 2, y = 2, skip = true } } },
        { index = 3, completed = true, elements = { { zone = 1413, x = 70, y = 70 } } },  -- já concluído: some
        { index = 4, elements = { { zone = 1413, x = 60, y = 20 } } } }
    _G.RXP = { currentGuide = { name = "12-17 Sertões", steps = steps },
               RXPFrame = { activeSteps = { steps[2], steps[1] } }, arrowFrame = { element = entrar } }
    _G.C_NamePlate = { GetNamePlates = function() return {
        { namePlateUnitToken = "nameplate1" }, { namePlateUnitToken = "nameplate2" }, { namePlateUnitToken = "nameplate3" } } end }

    _G.UnitRace = function() return "Orc", "Orc", 2 end
    _G.C_QuestLog.GetAllCompletedQuestIDs = function() return { 30, 10, 20 } end
    boot()
    fire("TIME_PLAYED_MSG", 5000, 300)
    fire("PLAYER_DEAD")
    local js = full(true)
    assert(js:find('"rxp":{"group":"Guia RestedXP Forever %(H%)","guide":"12%-14 Floresta de Pinhaprata","levels":%[%[2,612,988,1,930,20,200,2,0%]%],"step":2}'), "rxp: " .. js)
    assert(js:find('"path":{"cur":2,"guide":"12%-17 Sertões","steps":%[%[1,1,"Entre em Orgrimmar",%[%[1414,56.81,45.47,1%]%]%],%[2,1,"Mate Pinotes",%[%[1413,55.56,25.1%]%]%],%[4,0,"",%[%[1413,60,20%]%]%]%],"total":4}'), "rxp path: " .. js)
    assert(js:find('"facing":1.571'), "direção: " .. js)
    assert(js:find('"played":%[50%d%d,3%d%d%]'), "tempo jogado: " .. js)
    assert(js:find('"dur":%[25,63%]') and js:find('"resting":1') and js:find('"deaths":1'), "durabilidade/descanso/mortes: " .. js)
    assert(js:find('"game":"forever"'), "jogo: " .. js)
    assert(js:find('"near":%[%[3246,90,83,0,4,"normal",2%],%[3255,90,83,0,4,"normal",1%]%]'), "visíveis: " .. js)
    assert(js:find('"target":{"class":"normal","dead":0,"hp":25,"id":3246,"kind":"Creature","level":90,"name":"Pinote Fugaz","reaction":4}'), "alvo: " .. js)
    assert(not js:find('"done"'), "lista de quests já enviada no login não repete")
    local forced = NS.Live.fullPayload(true, true)  -- /wpilot agora manda tudo
    assert(forced:find('"done":%[10,20,30%]') and js:find('"faction":"Horde"') and js:find('"race":2'), "quests feitas/facção: " .. forced)
    assert(js:find('"spec":"Aperfeiçoamento"'), "spec pelos talentos: " .. js)
    assert(js:find('"fv":{'), js)
    assert(js:find('"xp":1200') and js:find('"xpMax":5000') and js:find('"rested":800'), "xp: " .. js)
    assert(js:find('"zone":"Floresta de Elwynn"') and not js:find('"subzone"'), "zona: " .. js)
    assert(js:find('"quests":%[%[33,"Lobos na mata",5,0,%[%["Lobo: 4/8",0%]%]%]%]'), "quests: " .. js)
    assert(js:find('"skills":%[%["Mineração",50,75%]%]'), "profissões: " .. js)
    assert(js:find('"talents":%[%["Elemental",0%],%["Aperfeiçoamento",11%],%["Restauração",3%]%]'), js)
    assert(forced:find('"names":{"%d+":%[".-",%d+,%d+,%d+,'), "detalhes dos itens: " .. forced)   -- só quando mudam
end

T["live: retail não manda os campos do Forever"] = function()
    boot()
    local js = full(true)
    assert(js:find('"game":"retail"') and not js:find('"fv"') and not js:find('"names"'), js)
end


T["forever: spec do ForeverLevelingBiS quando não há talentos"] = function()
    _G.GetSpecialization = nil
    _G.GetRealmName = function() return "Reino Teste PvP" end
    _G.UnitName = function() return "Fulano" end
    _G.ForeverLevelingBiSDB = { chars = { ["Fulano-Reino Teste PvP"] = { spec = "enhancement" } } }
    boot()
    assert(full(true):find('"spec":"Aperfeiçoamento"'))
    slash("api")
end


T["forever: ficha do jogador (vida, recurso, mana do druida em forma, atributos) e vida/recurso do grupo"] = function()
    _G.C_Map = { GetBestMapForUnit = function() return 1413 end,
                 GetPlayerMapPosition = function(_, u) return { GetXY = function() return 0.4, 0.3 end } end }
    _G.UnitXP = function() return 100 end
    _G.UnitXPMax = function() return 400 end
    _G.GetXPExhaustion = function() return nil end
    _G.UnitRace = function() return "Orc", "Orc", 2 end
    _G.UnitFactionGroup = function() return "Horde", "Horda" end
    _G.IsInGroup = function() return true end
    _G.IsInRaid = function() return false end
    local units = { party1 = true, party2 = true }
    _G.UnitExists = function(u) return units[u] or false end
    _G.UnitName = function(u) return ({ party1 = "Tank", party2 = "Longe" })[u] or "Fulano" end
    _G.UnitHealth = function(u) return ({ player = 900, party1 = 50 })[u] end           -- party2 fora de alcance
    _G.UnitHealthMax = function(u) return ({ player = 1000, party1 = 200 })[u] end
    _G.UnitPowerType = function(u) if u == "player" then return 3, "ENERGY" end return 1, "RAGE" end
    _G.UnitPower = function(u, t) if u == "player" then return t == 0 and 300 or 60 end return u == "party1" and 33 or nil end
    _G.UnitPowerMax = function(u, t) if u == "player" then return t == 0 and 500 or 100 end return 100 end
    _G.UnitStat = function(_, i) return 10, ({ 40, 55, 60, 25, 30 })[i], 0, 0 end
    _G.UnitArmor = function() return 300, 420, 420, 0, 0 end
    _G.UnitIsDeadOrGhost = function() return false end
    boot()
    local js = NS.Live.fullPayload(true, true)
    assert(js:find('"me":{"armor":420,"hp":%[900,1000%],"mana":%[300,500%],"pw":%[60,100,"ENERGY"%],"st":%[40,55,60,25,30%]}'), "ficha: " .. js)
    assert(js:find('"party":%[%["Tank","SHAMAN",40,30,25,33,"RAGE",null%],%["Longe","SHAMAN",40,30,null,null,"RAGE",null%]%]'), "grupo: " .. js)   -- último: subgrupo (raide)
    _G.UnitPowerType = function() return 0, "MANA" end                                  -- mana como recurso: sem "mana" à parte
    _G.UnitIsDeadOrGhost = function(u) return u == "player" end
    js = NS.Live.fullPayload(true, true)
    assert(js:find('"me":{[^}]*"dead":1') and not js:find('"mana":%['), "morto, sem mana duplicada: " .. js)
end

T["forever: voos aprendidos (mapa de voo aberto) vão em ex.taxi e somam entre continentes"] = function()
    _G.C_Map = { GetBestMapForUnit = function() return 1413 end,
                 GetPlayerMapPosition = function() return { GetXY = function() return 0.4, 0.3 end } end }
    _G.UnitXP = function() return 100 end
    _G.UnitXPMax = function() return 400 end
    _G.GetXPExhaustion = function() return nil end
    _G.UnitIsDeadOrGhost = function() return false end
    _G.UnitRace = function() return "Orc", "Orc", 2 end
    _G.UnitFactionGroup = function() return "Horde", "Horda" end
    _G.GetTaxiMapID = function() return 1414 end
    _G.C_TaxiMap = { GetAllTaxiNodes = function(m) assert(m == 1414); return { { nodeID = 25, name = "Encruzilhada" }, { nodeID = 23 } } end }
    boot()
    local js = NS.Live.fullPayload(true, true)
    assert(not js:find('"taxi"'), "sem abrir o mapa de voo: " .. js)
    fire("TAXIMAP_OPENED")
    -- o jogo lista também os não aprendidos do continente (state 2 = Unreachable): ficam de fora, e saem se estavam
    _G.C_TaxiMap = { GetAllTaxiNodes = function() return { { nodeID = 80, state = 1 }, { nodeID = 25, state = 0 },
                                                         { nodeID = 18, state = 2 }, { nodeID = 23, state = 2 } } end }
    fire("TAXIMAP_OPENED")
    js = NS.Live.fullPayload(true, true)
    assert(js:find('"taxi":%[25,80%]') and js:find('"taxiV":2'), "voos: " .. js)
end

T["forever: seta do RXP vai em path.arrow mesmo fora da lista, com o motivo"] = function()
    _G.UnitXP = function() return 100 end
    _G.UnitXPMax = function() return 400 end
    _G.UnitRace = function() return "Orc", "Orc", 2 end
    _G.UnitFactionGroup = function() return "Horde", "Horda" end
    local s153 = { index = 153, active = true, elements = { { text = "Mate Kolkar ao redor do oásis" } } }
    local s154 = { index = 154, active = true, elements = { { text = "Vá ao poço", zone = 1413, x = 50, y = 50, wpHash = 7 } } }
    local gerado = { zone = 1413, x = 45.123, y = 38.456, generated = 0, step = s153 }   -- .line/.mob: não está em elements
    local shown = true
    local af = { element = gerado, IsShown = function() return shown end }
    _G.RXPCData = { currentStep = 154, completedWaypoints = {} }
    _G.RXP = { currentGuide = { name = "Sertões", steps = { [153] = s153, [154] = s154 } },
               RXPFrame = { activeSteps = { s153, s154 } }, arrowFrame = af }
    for i = 1, 152 do RXP.currentGuide.steps[i] = { index = i, completed = true, elements = {} } end
    boot()
    local js = NS.Live.fullPayload(true, true)
    assert(js:find('"arrow":%[153,1413,45.12,38.46,"fora"%]'), "seta fora da lista: " .. js)
    af.element = s154.elements[1]
    js = NS.Live.fullPayload(true, true)
    assert(js:find('"arrow":%[154,1413,50,50%]') and js:find('%[1413,50,50,1%]'), "seta num ponto da lista: " .. js)
    RXPCData.completedWaypoints[154] = { [7] = true }
    js = NS.Live.fullPayload(true, true)
    assert(js:find('"arrow":%[154,1413,50,50,"feito"%]'), "ponto alcançado: " .. js)
    shown = false
    js = NS.Live.fullPayload(true, true)
    assert(not js:find('"arrow"'), "seta escondida não vai: " .. js)
end

T["forever: andar agenda envio (mesmo sem evento), parado não"] = function()
    local px = 0.40
    _G.C_Map = { GetBestMapForUnit = function() return 1413 end,
                 GetPlayerMapPosition = function() return { GetXY = function() return px, 0.30 end } end }
    boot()
    run_timers()
    WowPilotDB.live.interval = 5
    _G.time = (function(t) return function() return t end end)(os.time() + 600)
    local before = SCREENSHOTS
    NS.Live.checkMovement()          -- 1ª posição conhecida: envia
    run_timers()
    assert(SCREENSHOTS == before + 1, "primeira posição deveria enviar: " .. (SCREENSHOTS - before))
    fire("SCREENSHOT_SUCCEEDED")
    _G.time = (function(t) return function() return t end end)(os.time() + 1200)
    NS.Live.checkMovement()          -- parado: nada
    run_timers()
    assert(SCREENSHOTS == before + 1, "parado não envia")
    px = 0.42                        -- andou 2% do mapa
    NS.Live.checkMovement()
    run_timers()
    assert(SCREENSHOTS == before + 2, "andou: envia")
end

T["forever: jogadores à vista (placas de nome) vão em nearP, com inimigo marcado"] = function()
    _G.C_Map = { GetBestMapForUnit = function() return 1413 end,
                 GetPlayerMapPosition = function(_, u) return { GetXY = function() return 0.4, 0.3 end } end }
    _G.UnitXP = function() return 100 end
    _G.UnitXPMax = function() return 400 end
    _G.GetXPExhaustion = function() return nil end
    _G.UnitRace = function() return "Orc", "Orc", 2 end
    _G.UnitFactionGroup = function() return "Horde", "Horda" end
    _G.C_NamePlate = { GetNamePlates = function() return { { namePlateUnitToken = "nameplate1" }, { namePlateUnitToken = "nameplate2" } } end }
    local guids = { nameplate1 = "Player-1-0000AAAA", nameplate2 = "Creature-0-1-2-3-3246-0000" }
    local oldGUID, oldName = _G.UnitGUID, _G.UnitName
    _G.UnitGUID = function(u) return guids[u] or (oldGUID and oldGUID(u)) end
    _G.UnitName = function(u) if u == "nameplate1" then return "Inimigo" end return oldName(u) end
    _G.UnitCanAttack = function(_, u) return u == "nameplate1" end
    _G.UnitClass = function(u) if u == "nameplate1" then return "Ladino", "ROGUE" end return "Xamã", "SHAMAN" end
    _G.UnitReaction = function(u) return u == "nameplate1" and 2 or 4 end
    _G.UnitHealth = function() return 50 end
    _G.UnitHealthMax = function() return 100 end
    _G.UnitIsDeadOrGhost = function() return false end
    _G.UnitIsDead = function() return false end
    boot()
    local js = NS.Live.fullPayload(true, true)
    assert(js:find('"nearP":%[%["Inimigo","ROGUE",%d+,50,0,2,1,"[^"]*","[^"]*","[^"]*"%]%]'), "jogadores: " .. js)
    assert(NS.Live.hostilePlayer("nameplate1") and not NS.Live.hostilePlayer("nameplate2"), "inimigo dispara envio já")
    _G.UnitGUID, _G.UnitName = oldGUID, oldName
end

T["ajustes: lista o atual e o sugerido; aplicar muda só o que difere"] = function()
    local cv = { nameplateMaxDistance = "20", nameplateShowEnemies = "1", nameplateShowFriends = "0",
                 nameplateShowFriendlyNPCs = "0", nameplateShowAll = "0" }
    _G.C_CVar = { GetCVar = function(k) return cv[k] end, SetCVar = function(k, v) cv[k] = v end }
    boot()
    slash("ajustes")
    assert(cv.nameplateMaxDistance == "20", "só listar não muda")
    slash("ajustes aplicar")
    assert(cv.nameplateMaxDistance == "41" and cv.nameplateShowFriends == "1" and cv.nameplateShowAll == "1", "aplicou")
end

return T
