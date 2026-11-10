# WowPilot

Leva os dados do seu personagem do **World of Warcraft** para o seu painel no site WowPilot: equipamento, bolsas,
moedas, Great Vault, Mítica+, grupos, chat e, no **WoW: Forever**, o leveling (XP/h, quests, guia do RestedXP e o
caminho até o próximo objetivo no mapa).

São duas peças, mas você só instala uma: o WowPilot Sync instala o addon para você.

- **Addon WowPilot**, dentro do jogo: junta os dados e mostra um código colorido por um instante no canto da tela.
- **WowPilot Sync**, no Windows: lê esse código nos prints do jogo e envia ao site.

Funciona no **Retail** e no **WoW: Forever**.

## Instalação

### 1. Crie sua conta no site

Entre no site do WowPilot, crie a conta e abra a página **Configurar**. Lá você gera o **token**, a chave que liga
este PC à sua conta.

### 2. Instale o WowPilot Sync

1. Baixe o **`WowPilotSync.exe`** da [última versão](../../releases/latest) e salve numa pasta sua (por exemplo
   `Documentos\WowPilot`). Não precisa instalar nada.
2. Abra o programa. Se o Windows mostrar *"O Windows protegeu o computador"*, clique em **Mais informações** →
   **Executar assim mesmo** (o programa ainda não tem assinatura digital paga).
3. Na janela de configuração, preencha:
   - **Endereço do site**: já vem preenchido com `https://wowpilot.mican.com.br`. Só troque se você usa outro
     servidor do WowPilot;
   - **Token**: o que você gerou na página Configurar;
   - **Pasta do WoW**: deixe em branco. O programa acha o jogo sozinho (em qualquer disco) e mostra embaixo o que
     encontrou, por exemplo *Encontrado: Retail · WoW: Forever*. Só escolha a pasta se ele não achar.
4. Clique em **Testar conexão** e depois em **Salvar**.

O programa faz o resto sozinho:

- **instala o addon WowPilot** no Retail e no WoW: Forever (e o mantém atualizado). Se o jogo estiver aberto,
  feche e abra de novo para o addon aparecer;
- cria no Menu Iniciar o atalho **WowPilot Sync** (abre o programa) e o atalho **WowPilot** (abre o site no seu
  navegador). Se você mudar o `.exe` de pasta, os atalhos se corrigem sozinhos.

**Site na barra de tarefas:** o Windows não deixa um programa se fixar sozinho, mas é um clique: no Menu Iniciar,
clique com o botão direito em **WowPilot** → **Fixar na barra de tarefas** (no Windows 11, em **Mais**).

Dica: na página Configurar do site, o botão **Configurar o WowPilot Sync** preenche endereço e token sozinho
(com o programa já aberto uma vez).

Pronto. Deixe o WowPilot Sync aberto enquanto joga; ele fica como um ícone perto do relógio. Ele vigia ao mesmo
tempo todas as variações instaladas (Retail, WoW: Forever, Classic, PTR…). A busca acontece quando o programa
abre; instalou uma variação nova? Reabra o programa ou use **Buscar de novo** em **Configurações…**.

### Instalar o addon à mão (opcional)

Prefere não deixar o programa mexer na pasta do jogo? Desligue **Instalar e atualizar o addon** nas configurações,
baixe o **`WowPilot.zip`** da [última versão](../../releases/latest) e extraia a pasta `WowPilot` em
`World of Warcraft\_retail_\Interface\AddOns\` (ou `_forever_\Interface\AddOns\`).

## Uso no dia a dia

O envio é automático sempre que algo muda (equipamento, bolsas, moedas, grupo…) e **nunca durante combate**, no
Retail e no Forever: o que mudar na luta é enviado assim que ela acaba.
Você vai ver um código colorido piscar no canto superior esquerdo da tela: é o addon enviando.

Comandos no jogo:

| Comando | O que faz |
|---|---|
| `/wpilot` | mostra o status e o último envio |
| `/wpilot agora` | envia na hora (também como macro: `/run WowPilot_Send()`) |
| `/wpilot intervalo N` | espera no mínimo N segundos entre envios automáticos (padrão 30, mínimo 5; `0` = só manual) |
| `/wpilot pulso on\|off` | liga/desliga a faixinha no canto superior esquerdo que leva a posição ao site a cada segundo |

A faixinha colorida fixa no canto superior esquerdo (cerca de 112×4 pixels) é o **pulso**: o WowPilot Sync lê
esses pixels da janela do jogo a cada segundo, sem tirar print, e o mapa do site acompanha você quase em tempo real.
Funciona com o jogo em janela ou em tela cheia em janela, à vista (minimizado ou coberto por outra janela, não dá).

Para ver o seu painel: botão **Abrir o site** na janela do programa, no menu do ícone perto do relógio ou no atalho
**WowPilot**. Ele abre no seu navegador padrão.

No ícone do WowPilot Sync (perto do relógio): **Abrir o site**, **Configurações…** e **Sair**.

### Atualizar

Ao abrir, o WowPilot Sync avisa quando há versão nova: aparece uma notificação do Windows (clique nela para abrir
o programa) e o botão vira **Atualizar para vX.Y.Z**, em destaque. Clique nele: ele baixa a
versão mais recente daqui do GitHub, confere os arquivos (SHA-256), atualiza o addon em todas as pastas do jogo onde
ele está instalado e reabre sozinho. Depois, no jogo, dê `/reload`.

### Opções do WowPilot Sync

- **Iniciar com o Windows**: abre sozinho, só com o ícone perto do relógio.
- **Instalar e atualizar o addon** (ligado): instala o addon no Retail e no Forever e o atualiza junto com o
  programa. Desligue se preferir cuidar do addon à mão.
- **Atalhos no Menu Iniciar** (ligado) e **Atalhos na Área de Trabalho** (desligado): os atalhos **WowPilot Sync**
  e **WowPilot** (site). Desligar remove os atalhos.
- **Enviar as mensagens do chat**: **desligada por padrão**. Desligada, o WowPilot Sync tira o chat dos dados antes
  de enviar: nenhuma mensagem sai do seu PC.
  - **Incluir o chat log do jogo** (só com a opção acima ligada): no Retail, o jogo esconde dos addons o chat durante
    o combate; o arquivo de registro do chat recupera essas mensagens. Precisa do registro ligado no jogo
    (`/chatlog`). No Forever não faz diferença.
- **Manter os prints do código**: por padrão, os prints com o código são apagados depois de enviados. Seus prints
  normais nunca são tocados.

## O que é enviado

Só para a sua conta no site, por conexão segura (HTTPS):

- personagem: nome, reino, classe, especialização, nível, ouro;
- equipamento, bolsas, banco e moedas;
- Great Vault, Mítica+ e desempenho em grupo (do medidor do próprio jogo);
- grupos: quem estava e onde;
- **só se você ligar a opção de chat**: mensagens privadas e de grupo (sussurros, inclusive do Battle.net, grupo,
  raide, instância, guilda e oficiais; canais públicos como dizer, gritar, Comércio e Geral nunca entram) e, com o
  chat log, o final do arquivo de registro de chat do jogo, que tem tudo o que o jogo registrou;
- no WoW: Forever: XP, posição no mapa, quests, talentos, profissões e o passo atual do RestedXP.

Nada é enviado a terceiros. O token fica guardado só neste PC (`%LOCALAPPDATA%\WowPilot`); se desconfiar dele, gere
outro na página Configurar e o antigo deixa de funcionar.

## Problemas comuns

**Nada chega no site.**
Confira se o WowPilot Sync está aberto (ícone perto do relógio) e se o status dele está verde. Use `/wpilot agora`
no jogo e veja a lista **Atividade** do programa.

**"Token inválido" ou "token recusado".**
O token foi revogado ou copiado errado. Gere outro na página Configurar e cole em **Configurações…**.

**"Site fora do ar".**
Os envios ficam guardados e são reenviados sozinhos quando o site voltar.

**O código colorido aparece mas o programa não lê.**
Filtros de imagem, HDR, ou programas que mexem nas cores da tela podem atrapalhar. Teste sem eles. Confira também se
o jogo aparece em **Jogos**, na janela do programa.

**O programa não achou o jogo.**
Em **Configurações…**, clique em **Procurar…** e escolha a pasta `World of Warcraft` (a que tem `_retail_`,
`_forever_`…).

**O Windows bloqueou o programa.**
Veja o passo 3.2 da instalação.

Ainda com problema? O registro do programa fica em `%LOCALAPPDATA%\WowPilot\WowPilotSync.log`.

## Dúvidas, problemas e sugestões

- **Dúvida** sobre como usar: abra uma conversa em [Discussions](../../discussions).
- **Algo não funciona** ou **ideia de melhoria**: abra uma [issue](../../issues/new/choose), há um formulário para
  cada caso.
- **Falha de segurança**: não abra issue pública, veja [SECURITY.md](SECURITY.md).

Nunca cole o seu token em issues, conversas ou prints.

Quer mexer no código? Veja [CONTRIBUTING.md](CONTRIBUTING.md).
