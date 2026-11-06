# Contribuindo

Obrigado pelo interesse! Para relatar problemas ou sugerir algo, use os formulários de
[issue](../../issues/new/choose); este guia é para quem quer mexer no código.

## Estrutura

| Caminho | O quê |
|---|---|
| `WowPilot.toc`, `WowPilot.lua` | addon: coleta (equipamento, bolsas, moedas, Vault, grupos, chat, leveling no Forever) |
| `WowPilotLive.lua` | addon: monta o JSON, comprime, desenha o código de pixels e chama `Screenshot()` |
| `client/WowPilotSync/` | cliente Windows em C# (.NET Framework 4, WinForms): vigia a pasta Screenshots, decodifica e envia |
| `client/WowPilotSync.ps1` | o mesmo cliente em PowerShell 5.1+, sem interface (decodificador C# embutido) |
| `client/build.cmd` | compila o `WowPilotSync.exe` com o `csc.exe` que já vem no Windows |
| `tests/` | testes do addon com um stub da API do WoW, e ponta a ponta do código de pixels |

### Como os dados saem do jogo

Addons não acessam rede nem arquivos. O addon desenha os dados como um código colorido no canto superior esquerdo,
tira um print e esconde o código; o cliente lê o PNG, decodifica e envia por HTTPS com o token do usuário.

O formato do código (cabeçalho, paleta, páginas, compressão) está documentado no topo de `WowPilotLive.lua` e em
`tests/livecode_ref.py`, que é o decodificador de referência.

A busca das instalações do jogo também mora no código compartilhado (`WowInstall` em `Decoder.cs`): chaves de
desinstalação do Battle.net no registro, a chave antiga da Blizzard e caminhos comuns em todos os discos. Cada
variação é uma pasta `_nome_` com `.flavor.info` (produto: `wow`, `wowf`…) ou `Wow*.exe`; pastas vazias de variações
desinstaladas ficam de fora. A busca roda ao iniciar o motor (abrir o programa, salvar as configurações) e no
botão **Buscar de novo**; não há busca periódica. Para ver o que o cliente acha numa máquina:

```bash
WowPilotSync.exe --list-games > jogos.txt
```

O addon sempre coleta o chat; quem decide se ele sai do PC é o cliente: com `SendChat` desligado (padrão),
`Decoder.DropKey` tira a chave `chat` do JSON antes de enviar ou guardar como pendente. O decodificador C# existe em dois lugares,
`client/WowPilotSync/Decoder.cs` e embutido no `.ps1`: mantenha os dois iguais (o teste confere).

## Ambiente

- Python 3.10+ com `pip install lupa pillow` para os testes.
- Windows (ou WSL) para compilar e testar o cliente de verdade.

## Testes

```bash
python3 tests/run_tests.py          # addon
python3 tests/test_live_decode.py   # código de pixels: referência em Python; .ps1 e .exe quando há powershell.exe
```

O `lupa` roda Lua 5.4; o WoW usa Lua 5.1. Evite sintaxe nova no addon (`goto`, `//`, `<const>`, inteiros de 64
bits): o teste passaria, mas o jogo quebraria.

Teste também no jogo: `/reload` e `/wpilot agora`. `/wpilot api` mostra quais APIs o cliente do jogo expõe (útil
para diferenças entre Retail e Forever).

## Pull requests

- Um assunto por PR, com a descrição do que mudou e como testou (testes e/ou no jogo).
- O GitHub Actions roda os testes e compila o `.exe` em todo PR; precisa ficar verde.
- Não commite o `.exe` nem o `.zip`: eles são gerados pelo build.
- Textos para o usuário em português.

## Versões

O número da versão fica em quatro lugares e precisa ser igual em todos: `## Version:` no `WowPilot.toc`, `Version`
em `client/WowPilotSync/Sync.cs`, `$ClientVersion` no `.ps1` e `client/WowPilotSync/AssemblyInfo.cs`.

Para publicar, suba a versão nesses arquivos, faça o commit e crie a tag:

```bash
git tag v1.3.3 && git push origin v1.3.3
```

O workflow confere as versões, compila e publica o Release com `WowPilotSync.exe` e `WowPilot.zip`.

O botão **Atualizar** do cliente (`Update.cs`) lê `releases/latest` pela API do GitHub e só aceita os arquivos se o
SHA-256 bater com o `digest` que o GitHub publica para cada asset. Ele não mexe numa pasta do addon que seja clone do
git. Para testar sem o GitHub: `WowPilotSync.exe --update --api <url do JSON> --wow <pasta>` (veja
`tests/test_live_decode.py`).

Gere tags só para publicar uma versão de verdade (ou validar o pipeline): cada tag vira um Release que o botão
Atualizar oferece a todos.
