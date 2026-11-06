# WowPilot

Leva os dados do seu personagem do **World of Warcraft** para o seu painel no site WowPilot: equipamento, bolsas,
moedas, Great Vault, Mítica+, grupos, chat e, no **WoW: Forever**, o leveling (XP/h, quests, guia do RestedXP e o
caminho até o próximo objetivo no mapa).

São duas peças, e você precisa das duas:

- **Addon WowPilot**, dentro do jogo: junta os dados e mostra um código colorido por um instante no canto da tela.
- **WowPilot Sync**, no Windows: lê esse código nos prints do jogo e envia ao site.

Funciona no **Retail** e no **WoW: Forever**.

## Instalação

### 1. Crie sua conta no site

Entre no site do WowPilot, crie a conta e abra a página **Configurar**. Lá você gera o **token**, a chave que liga
este PC à sua conta.

### 2. Instale o addon

1. Baixe o **`WowPilot.zip`** da [última versão](../../releases/latest).
2. Extraia a pasta `WowPilot` dentro de:
   - Retail: `World of Warcraft\_retail_\Interface\AddOns\`
   - WoW: Forever: `World of Warcraft\_forever_\Interface\AddOns\`
3. Abra o jogo (ou dê `/reload`). Na lista de addons deve aparecer **WowPilot**.

### 3. Instale o WowPilot Sync

1. Baixe o **`WowPilotSync.exe`** da [última versão](../../releases/latest) e salve numa pasta sua (por exemplo
   `Documentos\WowPilot`). Não precisa instalar nada.
2. Abra o programa. Se o Windows mostrar *"O Windows protegeu o computador"*, clique em **Mais informações** →
   **Executar assim mesmo** (o programa ainda não tem assinatura digital paga).
3. Na janela de configuração, preencha:
   - **Endereço do site**: o endereço do WowPilot que você usa;
   - **Token**: o que você gerou na página Configurar;
   - **Pasta do WoW**: normalmente é encontrada sozinha.
4. Clique em **Testar conexão** e depois em **Salvar**.

Dica: na página Configurar do site, o botão **Configurar o WowPilot Sync** preenche endereço e token sozinho
(com o programa já aberto uma vez).

Pronto. Deixe o WowPilot Sync aberto enquanto joga; ele fica como um ícone perto do relógio.

## Uso no dia a dia

O envio é automático sempre que algo muda (equipamento, bolsas, moedas, grupo, chat…) e **nunca durante combate**.
Você vai ver um código colorido piscar no canto superior esquerdo da tela: é o addon enviando.

Comandos no jogo:

| Comando | O que faz |
|---|---|
| `/wpilot` | mostra o status e o último envio |
| `/wpilot agora` | envia na hora (também como macro: `/run WowPilot_Send()`) |
| `/wpilot intervalo N` | espera no mínimo N segundos entre envios automáticos (padrão 30, mínimo 5; `0` = só manual) |

No ícone do WowPilot Sync (perto do relógio): **Abrir dashboard**, **Configurações…** e **Sair**.

### Opções do WowPilot Sync

- **Iniciar com o Windows**: abre sozinho, só com o ícone perto do relógio.
- **Enviar o chat log do jogo**: recupera mensagens que o jogo esconde dos addons durante o combate. Só funciona com o
  registro de chat ligado no jogo (`/chatlog`).
- **Manter os prints do código**: por padrão, os prints com o código são apagados depois de enviados. Seus prints
  normais nunca são tocados.

## O que é enviado

Só para a sua conta no site, por conexão segura (HTTPS):

- personagem: nome, reino, classe, especialização, nível, ouro;
- equipamento, bolsas, banco e moedas;
- Great Vault, Mítica+ e desempenho em grupo (do medidor do próprio jogo);
- grupos: quem estava e onde;
- chat privado e de grupo: sussurros (inclusive do Battle.net), grupo, raide, instância, guilda e oficiais. Canais
  públicos (dizer, gritar, Comércio, Geral) ficam de fora;
- se a opção **Enviar o chat log** estiver ligada: o final do arquivo de registro de chat do jogo (`/chatlog`),
  que contém tudo o que o jogo registrou;
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
a pasta do WoW nas configurações é a do jogo que você está usando (`_retail_` ou `_forever_`).

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
