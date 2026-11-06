# WowPilot — cliente (addon + WowPilotSync)

Parte que roda no seu PC: o **addon** dentro do World of Warcraft e o **cliente Windows** que leva os dados ao seu
dashboard WowPilot.

```
addon (no jogo)                     WowPilotSync (Windows)                     site
código colorido no canto   ──►      vigia Screenshots\ a cada 1 s,     ──►     dashboard
sup. esquerdo + Screenshot()        decodifica, envia (HTTPS + token)
```

## Conteúdo

| Caminho | O quê |
|---|---|
| `WowPilot.toc`, `WowPilot.lua`, `WowPilotLive.lua` | addon (Retail e WoW: Forever) |
| `client/WowPilotSync.ps1` | cliente em PowerShell 5.1+ (já vem no Windows), decodificador C# embutido |
| `client/WowPilotSync/`, `client/build.cmd` | cliente em C# (`WowPilotSync.exe`, com janela e ícone na bandeja) |
| `tests/` | testes do addon fora do jogo (stub da API do WoW) e do decodificador |

## Instalar

1. Coloque esta pasta como `WowPilot` em `World of Warcraft\_retail_\Interface\AddOns\` (e/ou
   `_forever_\Interface\AddOns\`) e dê `/reload` no jogo. O jogo ignora `client/` e `tests/`.
2. No site, em **Configurar**, gere um token e rode o `WowPilotSync.exe` (dos Releases) ou o `.ps1` com o endereço do site.

No jogo: `/wpilot` mostra o status; `/wpilot agora` envia já (macro: `/run WowPilot_Send()`);
`/wpilot intervalo N` define o intervalo mínimo entre envios, em segundos.

## Baixar ou compilar

O `WowPilotSync.exe` e o `WowPilot.zip` (addon) saem prontos nos **Releases** do GitHub: o GitHub Actions compila a
partir deste código a cada tag `vX.Y.Z` (a versão do `.toc`, do `Sync.cs`, do `.ps1` e do `AssemblyInfo.cs` tem que ser igual à da tag). Para compilar na mão,
`client\build.cmd` usa o `csc.exe` que já vem no Windows (.NET Framework 4); não precisa instalar nada.

Nova versão: suba a versão nesses quatro arquivos, faça o commit e

```bash
git tag v1.1.1 && git push origin v1.1.1
```

## Testes

```bash
pip install lupa pillow
python3 tests/run_tests.py          # addon (Lua 5.4 do lupa; o jogo usa 5.1: evite sintaxe nova)
python3 tests/test_live_decode.py   # código na tela → decodificador (.ps1 e .exe só no Windows/WSL)
```
