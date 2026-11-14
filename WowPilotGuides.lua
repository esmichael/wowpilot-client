-- Guias do WowPilot para o RestedXP (RXPGuides): aparecem na lista de guias do RXP, no grupo "WowPilot" (sem "+": grupo com "+" é guia de farm de ouro e só aparece no modo Assistente de Ouro), com a
-- seta e os pontos no mapa como os guias deles. Sem o RXP, este arquivo não faz nada.
--
-- Pesca: "Nat Pagle, o pescador supremo" (6607). Os quatro peixes só fisgam com a missão aceita; os pontos são os
-- lugares de pesca da missão (Questie), e a ordem e os voos vêm do planejador de rotas do site (Horda, saindo do
-- Pântano Vadeoso, aprendendo no caminho os voos de Muralha Verde, Mojache e Pedregal). Ao entregar, o Nat ensina
-- Pesca Artesã (até 300).
local R = _G.RXPGuides
if type(R) ~= "table" or type(R.RegisterGuide) ~= "function" then return end

R.RegisterGuide([[
#classic
#forever
<< Horde
#group WowPilot
#name Pesca: missão do Nat Pagle (Horda)
#displayname Pesca: missão do Nat Pagle
#guideKind profession

step
    #sticky
    #label Dicas
    +|cRXP_WARN_Leve vara e isca (o Atraidor Aquadinâmico dá +75 e ajuda a não perder o peixe). Com Pesca 225 você já fisga nos quatro lugares; jogue a linha na água perto dos pontos do mapa até o peixe da missão vir.|r
step
    #completewith Nat
    .goto Dustwallow Marsh,35.6,31.9
    .fp Brackenwall Village >> No caminho para o Nat, aprenda o voo da |cRXP_FRIENDLY_Aldeia Muralha Verde|r (voe até o Acampamento Taurajo e siga a estrada para o leste)
step
    #label Nat
    .goto Dustwallow Marsh,58.6,60.1
    >>Fale com |cRXP_FRIENDLY_Nat Pagle|r na beira do lago
    .accept 6607 >>Aceite "Nat Pagle, o pescador supremo"
    .target Nat Pagle
step
    #completewith next
    .fly Shadowprey Village >> Volte à Muralha Verde e voe até a |cRXP_FRIENDLY_Aldeia Pescassombra|r (Desolação)
step
    .goto Desolace,25.5,77.4,25,0
    .goto Desolace,24.8,81.7,25,0
    .goto Desolace,25.5,77.4
    >>Pesque na |cRXP_PICK_Praia de Sar'theris|r, ao sul da Aldeia Pescassombra
    .collect 16968,1,6607 --Piranha-de-sar'theris
step
    .goto Feralas,62.5,52.1,25,0
    .goto Feralas,62.5,50.0,25,0
    .goto Feralas,63.7,53.1,25,0
    .goto Feralas,62.5,52.1
    >>Desça para Feralas e pesque no |cRXP_PICK_Rio Verdantis|r
    .collect 16967,1,6607 --Atum-amarelo-de-feralas
step
    .goto Feralas,75.4,44.4
    .fp Camp Mojache >> Aprenda o voo da |cRXP_FRIENDLY_Aldeia Mojache|r
step
    #completewith next
    .fly Ratchet >> Voe até a |cRXP_FRIENDLY_Vila Catraca|r e pegue o barco para a |cRXP_FRIENDLY_Angra do Butim|r
step
    #completewith next
    .fly Grom'gol >> Na Angra do Butim, voe até |cRXP_FRIENDLY_Grom'gol|r
step
    .goto Stranglethorn Vale,24.7,19.6,25,0
    .goto Stranglethorn Vale,29.1,23.7,25,0
    .goto Stranglethorn Vale,29.9,28.5,25,0
    .goto Stranglethorn Vale,24.7,19.6
    >>Pesque na |cRXP_PICK_Costa Selvagem|r, a noroeste de Grom'gol
    .collect 16969,1,6607 --Molinésia-azul-da-costa-selvagem
step
    .goto Swamp of Sorrows,46.1,54.8
    >>Vá a pé pelo norte (Floresta do Crepúsculo e Passo do Vento Morto) até o Pântano das Mágoas
    .fp Stonard >> Aprenda o voo de |cRXP_FRIENDLY_Pedregal|r
step
    .goto Swamp of Sorrows,90.4,73.1,25,0
    .goto Swamp of Sorrows,89.9,82.2,25,0
    .goto Swamp of Sorrows,87.8,79.0,25,0
    .goto Swamp of Sorrows,90.4,73.1
    >>Pesque na |cRXP_PICK_Praia de Junco Brumoso|r, na costa leste do pântano
    .collect 16970,1,6607 --Graçapé-brumalga
step
    #completewith next
    .fly Booty Bay >> Volte a Pedregal, voe até a |cRXP_FRIENDLY_Angra do Butim|r e pegue o barco para a |cRXP_FRIENDLY_Vila Catraca|r
step
    #completewith next
    .fly Brackenwall Village >> Na Vila Catraca, voe até a |cRXP_FRIENDLY_Aldeia Muralha Verde|r
step
    .goto Dustwallow Marsh,58.6,60.1
    >>Leve os quatro peixes ao |cRXP_FRIENDLY_Nat Pagle|r
    .turnin 6607 >>Entregue "Nat Pagle, o pescador supremo"
    .target Nat Pagle
step
    .goto Dustwallow Marsh,58.6,60.1
    .train 18248 >>Fale de novo com o |cRXP_FRIENDLY_Nat Pagle|r e aprenda |cRXP_WARN_Pesca Artesã|r (o limite sobe para 300)
    .target Nat Pagle
]])

-- Angra do Butim: as missões da Angra que o guia do RXP deixou para trás (Kebok, Drizzlik e Cranque Mirrabolha). Cada
-- uma só destrava a própria continuação: Orelhas → Presas Rachacrânio, Oferta e demanda → Algumas partes faltando →
-- Excelsior, Estilhaços azuis → Mineração da Empreendimentos. Pontos dos monstros pelo Questie (Selva do Espinhaço).
R.RegisterGuide([[
#classic
#forever
<< Horde
#group WowPilot
#name Angra do Butim: missões que faltaram (36-38)
#displayname Angra do Butim: missões que faltaram (36-38)
#next Angra do Butim: missões que faltaram (40-42)

step
    #completewith next
    .fly Booty Bay >> Voe de |cRXP_FRIENDLY_Grom'gol|r até a |cRXP_FRIENDLY_Angra do Butim|r
step
    .goto Stranglethorn Vale,27.0,77.1
    >>Fale com |cRXP_FRIENDLY_Kebok|r
    .accept 189 >>Aceite "Orelhas de Sanguescalpo"
    .accept 213 >>Aceite "Abordagem hostil"
    .target Kebok
step
    .goto Stranglethorn Vale,27.1,77.2
    >>Fale com |cRXP_FRIENDLY_Cranque Mirrabolha|r
    .accept 605 >>Aceite "Estilhaços azuis cantantes"
    .target Crank Fizzlebub
step
    .goto Stranglethorn Vale,28.3,77.6
    >>Fale com |cRXP_FRIENDLY_Drizzlik|r
    .accept 575 >>Aceite "Oferta e demanda"
    .target Drizzlik
step
    #completewith next
    .fly Grom'gol >> Volte voando para |cRXP_FRIENDLY_Grom'gol|r
step
    #completewith Cristais
    >>Mate os |cRXP_ENEMY_basiliscos|r que encontrar no caminho: os |cRXP_PICK_Estilhaços de Cristal Cantante|r caem deles
    .complete 605,1
    .mob Crystal Spine Basilisk
    .mob Stone Maw Basilisk
step
    .goto Stranglethorn Vale,24.4,11.2,30,0
    .goto Stranglethorn Vale,23.1,10.7,30,0
    .goto Stranglethorn Vale,25.6,10.6,30,0
    .goto Stranglethorn Vale,24.4,11.2
    >>Mate os |cRXP_ENEMY_trolls Sanguescalpo|r na costa oeste e pegue as |cRXP_LOOT_Orelhas|r (junto com as Cabeças e os Colares, se ainda faltarem)
    .complete 189,1
    .mob Bloodscalp Scout
    .mob Bloodscalp Hunter
    .mob Bloodscalp Berserker
    .mob Bloodscalp Headhunter
    .mob Bloodscalp Witch Doctor
step
    .goto Stranglethorn Vale,24.6,18.2,30,0
    .goto Stranglethorn Vale,27.1,18.6,30,0
    .goto Stranglethorn Vale,24.6,18.2
    >>Desça um pouco para o sul e mate os |cRXP_ENEMY_Basiliscos da Serra dos Cristais|r
    .complete 605,1
    .mob Crystal Spine Basilisk
step
    .goto Stranglethorn Vale,33.7,6.4,30,0
    .goto Stranglethorn Vale,35.7,6.8,30,0
    .goto Stranglethorn Vale,33.7,6.4
    >>Se ainda faltarem estilhaços, mate os |cRXP_ENEMY_Basiliscos Petragorja|r no extremo norte
    .complete 605,1
    .mob Stone Maw Basilisk
step
    .goto Stranglethorn Vale,34.6,10.5,30,0
    .goto Stranglethorn Vale,36.9,10.5,30,0
    .goto Stranglethorn Vale,39.9,11.5,30,0
    .goto Stranglethorn Vale,34.6,10.5
    >>Mate os |cRXP_ENEMY_Crocoliscos do Rio|r e pegue as |cRXP_LOOT_Peles de Crocolisco Grande do Rio|r
    .complete 575,1
    .mob River Crocolisk
step
    .goto Stranglethorn Vale,43.0,19.1,30,0
    .goto Stranglethorn Vale,44.2,18.6,30,0
    .goto Stranglethorn Vale,45.4,20.8,30,0
    .goto Stranglethorn Vale,43.0,19.1
    >>Mate os |cRXP_ENEMY_Geólogos da Empreendimentos S.A.|r e pegue os |cRXP_LOOT_Cristais Rolados|r
    .complete 213,1
    .mob Venture Co. Geologist
step
    #label Cristais
    .goto Stranglethorn Vale,48.2,8.2
    >>Se ainda faltarem estilhaços, termine nos |cRXP_ENEMY_Basiliscos da Serra dos Cristais|r a nordeste
    .complete 605,1
    .mob Crystal Spine Basilisk
step
    #completewith next
    .fly Booty Bay >> Vá a |cRXP_FRIENDLY_Grom'gol|r e voe até a |cRXP_FRIENDLY_Angra do Butim|r
step
    .goto Stranglethorn Vale,27.0,77.1
    .turnin 189 >>Entregue "Orelhas de Sanguescalpo"
    .turnin 213 >>Entregue "Abordagem hostil"
    .target Kebok
step
    .goto Stranglethorn Vale,27.1,77.2
    .turnin 605 >>Entregue "Estilhaços azuis cantantes"
    .target Crank Fizzlebub
step
    .goto Stranglethorn Vale,28.3,77.6
    .turnin 575 >>Entregue "Oferta e demanda"
    .accept 577 >>Aceite "Algumas partes faltando"
    .target Drizzlik
step
    #completewith next
    .fly Grom'gol >> Voe para |cRXP_FRIENDLY_Grom'gol|r
step
    .goto Stranglethorn Vale,39.5,28.7,30,0
    .goto Stranglethorn Vale,40.1,22.9,30,0
    .goto Stranglethorn Vale,41.3,15.3,30,0
    .goto Stranglethorn Vale,39.5,28.7
    >>Suba o rio a leste de Grom'gol matando os |cRXP_ENEMY_Crocoliscos Arapuca|r e pegue as |cRXP_LOOT_Peles de Crocolisco Arapuca|r
    .complete 577,1
    .mob Snapjaw Crocolisk
step
    #completewith next
    .fly Booty Bay >> Volte a |cRXP_FRIENDLY_Grom'gol|r e voe até a |cRXP_FRIENDLY_Angra do Butim|r
step
    .goto Stranglethorn Vale,28.3,77.6
    .turnin 577 >>Entregue "Algumas partes faltando"
    .accept 628 >>Aceite "Excelsior"
    .target Drizzlik
step
    #completewith next
    .fly Grom'gol >> Voe para |cRXP_FRIENDLY_Grom'gol|r
step
    .goto Stranglethorn Vale,29.3,22.3,30,0
    .goto Stranglethorn Vale,29.8,25.5,30,0
    .goto Stranglethorn Vale,33.4,32.5,30,0
    .goto Stranglethorn Vale,29.3,22.3
    >>Procure o |cRXP_ENEMY_Crocolisco de Água Salgada Ancião|r (nível 38) na costa perto de Grom'gol. São poucos: dê a volta pelos pontos até achar um
    .complete 628,1
    .mob Elder Saltwater Crocolisk
step
    #completewith next
    .fly Booty Bay >> Volte a |cRXP_FRIENDLY_Grom'gol|r e voe até a |cRXP_FRIENDLY_Angra do Butim|r
step
    .goto Stranglethorn Vale,28.3,77.6
    .turnin 628 >>Entregue "Excelsior"
    .target Drizzlik
]])

R.RegisterGuide([[
#classic
#forever
<< Horde
#group WowPilot
#name Angra do Butim: missões que faltaram (40-42)
#displayname Angra do Butim: missões que faltaram (40-42)

step
    #sticky
    #label Nivel
    +|cRXP_WARN_Faça esta parte no nível 40 ou mais: a mina é nível 40-42 e os Rachacrânio, 39-44.|r
step
    .goto Stranglethorn Vale,27.0,77.1
    .accept 209 >>Aceite "Presas Rachacrânio" com o |cRXP_FRIENDLY_Kebok|r
    .target Kebok
step
    .goto Stranglethorn Vale,27.1,77.2
    .accept 600 >>Aceite "Mineração da Empreendimentos S.A." com o |cRXP_FRIENDLY_Cranque Mirrabolha|r
    .target Crank Fizzlebub
step
    #completewith next
    .fly Grom'gol >> Voe para |cRXP_FRIENDLY_Grom'gol|r
step
    .goto Stranglethorn Vale,43.8,39.4,30,0
    .goto Stranglethorn Vale,46.2,32.0,30,0
    .goto Stranglethorn Vale,45.8,43.5,30,0
    .goto Stranglethorn Vale,43.8,39.4
    >>Mate os |cRXP_ENEMY_trolls Rachacrânio|r e pegue as |cRXP_LOOT_Presas Rachacrânio|r
    .complete 209,1
    .mob Skullsplitter Warrior
    .mob Skullsplitter Axe Thrower
    .mob Skullsplitter Mystic
    .mob Skullsplitter Hunter
step
    .goto Stranglethorn Vale,41.3,42.4,25,0
    .goto Stranglethorn Vale,42.0,44.6,25,0
    .goto Stranglethorn Vale,42.1,46.2,25,0
    .goto Stranglethorn Vale,41.3,42.4
    >>Entre na mina da |cRXP_ENEMY_Empreendimentos S.A.|r logo ao sul e pegue os |cRXP_LOOT_Cristais Azuis Canoros|r dos mineiros
    .complete 600,1
    .mob Venture Co. Strip Miner
    .mob Venture Co. Tinkerer
    .mob Venture Co. Surveyor
step
    #completewith next
    .fly Booty Bay >> Volte a |cRXP_FRIENDLY_Grom'gol|r e voe até a |cRXP_FRIENDLY_Angra do Butim|r
step
    .goto Stranglethorn Vale,27.0,77.1
    .turnin 209 >>Entregue "Presas Rachacrânio"
    .target Kebok
step
    .goto Stranglethorn Vale,27.1,77.2
    .turnin 600 >>Entregue "Mineração da Empreendimentos S.A."
    .target Crank Fizzlebub
]])
