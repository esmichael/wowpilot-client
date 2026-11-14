-- Guias do WowPilot para o RestedXP (RXPGuides): aparecem na lista de guias do RXP, no grupo "+WowPilot", com a
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
#group +WowPilot
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
    >>Vá a pé pelo norte (Bosque do Corvo e Passo do Vento Morto) até o Pântano das Mágoas
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
