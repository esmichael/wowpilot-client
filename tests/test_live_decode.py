"""Ponta a ponta do envio: WowPilotLive (Lua: frames + draw) → "tela" → PNG → leitor.

As texturas que o Live.draw cria no stub são redesenhadas numa imagem com "cena de jogo" aleatória
(canto superior esquerdo, célula de 2 px, 64 cores) e o leitor tem que recuperar a mensagem:
  1. leitor de referência em Python (tests/livecode_ref.py), com e sem distorção de gama/brilho;
  2. o cliente de verdade, client/WowPilotSync.ps1 (decodificador C#), via powershell.exe — só quando
     roda no Windows; recebe os envios num servidor HTTP local e confere o JSON.
A compressão do jogo (C_EncodingUtil.CompressString) é simulada com zlib do Python.

Requisitos: pip install lupa pillow.  Uso: python3 tests/test_live_decode.py
"""
import gzip
import json
import random
import shutil
import subprocess
import sys
import threading
import zlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
from livecode_ref import KIND_FULL, Assembler, decode_file  # noqa: E402
from run_tests import ROOT, fresh  # noqa: E402

SCREEN = (1920, 1080)
CELL = 2


def scene(seed=1):
    rnd = random.Random(seed)
    img = Image.new("RGB", SCREEN)
    img.putdata([(rnd.randrange(256), rnd.randrange(256), rnd.randrange(256)) for _ in range(SCREEN[0] * SCREEN[1])])
    return img


def paint(lua, code, seed=1):
    """Roda Live.draw no stub e pinta as texturas visíveis no canto superior esquerdo."""
    lua.eval("NS.Live.draw")(code)
    img = scene(seed)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, code.cols * CELL - 1, code.rows * CELL - 1], fill=(255, 255, 255))  # fundo do frame
    for t in lua.eval("TEXLIST").values():
        if t.shown and t.w:
            col = tuple(round(255 * (getattr(t, k) or 0)) for k in "rgb")
            d.rectangle([t.x, -t.y, t.x + t.w - 1, -t.y + t.h - 1], fill=col)
    return img


def distort(img, gamma=1.0, gain=1.0):
    lut = [min(255, round(255 * ((i / 255) ** gamma) * gain)) for i in range(256)]
    return img.point(lut * 3)


def frames(lua, payload):
    codes, raw, sent = lua.eval("NS.Live.frames")(KIND_FULL, payload)
    return list(codes.values()), raw, sent


def ref_decode(paths):
    asm, msg = Assembler(), None
    for p in paths:
        f = decode_file(p)
        if f is None:
            return None
        msg = asm.add(f, 0) or msg
    return msg[1] if msg else None


class Sink(BaseHTTPRequestHandler):
    got: list = []

    def log_message(self, *a):
        pass

    def _reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._reply({"user": "teste"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        Sink.got.append((self.path, self.headers.get("Authorization"), body.decode("utf-8")))
        self._reply({"ok": True})


def win_path(p: Path) -> str:
    return subprocess.run(["wslpath", "-w", str(p)], capture_output=True, text=True, check=True).stdout.strip()


def run_client(shots: list[list[Image.Image]], exe: bool = False, chat: bool = False):
    """Salva os prints numa pasta do Windows e roda o cliente (.ps1 -Once ou .exe --once) contra um servidor local."""
    temp = subprocess.run(["cmd.exe", "/c", "echo %TEMP%"], capture_output=True, text=True).stdout.strip()
    base = Path(subprocess.run(["wslpath", "-u", temp], capture_output=True, text=True).stdout.strip()) / "wowpilot_test"
    shutil.rmtree(base, ignore_errors=True)
    shot_dir = base / "Screenshots"
    shot_dir.mkdir(parents=True)
    n = 0
    for msg in shots:
        for img in msg:
            n += 1
            img.save(shot_dir / f"WoWScrnShot_101726_1200{n:02d}.png", "PNG")
    scene(9).save(shot_dir / "WoWScrnShot_101726_115959.png", "PNG")  # print normal: fica
    srv = HTTPServer(("0.0.0.0", 0), Sink)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    Sink.got = []
    try:
        if exe:
            cmd = [str(ROOT / "client" / "WowPilotSync.exe"), "--once", "--server", f"http://localhost:{srv.server_port}",
                   "--token", "tk123", "--screenshots", win_path(shot_dir), "--config-dir", win_path(base / "cfg"), "--no-chatlog"] + (["--chat"] if chat else [])
        else:
            cmd = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                   win_path(ROOT / "client" / "WowPilotSync.ps1"), "-Server", f"http://localhost:{srv.server_port}",
                   "-Token", "tk123", "-ScreenshotDir", win_path(shot_dir), "-ConfigDir", win_path(base / "cfg"),
                   "-Once", "-NoChatLog"] + (["-Chat"] if chat else [])
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
    finally:
        srv.shutdown()
    left = sorted(p.name for p in shot_dir.iterdir())
    shutil.rmtree(base, ignore_errors=True)
    return Sink.got, left, r.stdout + r.stderr


def check_games(check, exe: Path):
    """Busca das variações do jogo (WowInstall, a mesma fonte no .exe e no .ps1) numa instalação de mentira."""
    temp = subprocess.run(["cmd.exe", "/c", "echo %TEMP%"], capture_output=True, text=True).stdout.strip()
    root = Path(subprocess.run(["wslpath", "-u", temp], capture_output=True, text=True).stdout.strip()) / "wowpilot_games" / "World of Warcraft"
    shutil.rmtree(root.parent, ignore_errors=True)
    for folder, product, exe_name in (("_retail_", "wow", "Wow.exe"), ("_forever_", "wowf", "Wow.exe"),
                                      ("_xptr_", "wowxptr", "WowT.exe"), ("_novo_", None, "Wow.exe"), ("_classic_", None, None)):
        d = root / folder
        d.mkdir(parents=True)
        if product:
            (d / ".flavor.info").write_bytes(f"Product Flavor!STRING:0\r\n{product}\r\n".encode())
        if exe_name:
            (d / exe_name).write_bytes(b"")
    try:
        for arg in (root, root / "_forever_"):   # a pasta World of Warcraft ou a de uma variação
            r = subprocess.run([str(exe), "--list-games", "--wow", win_path(arg)], capture_output=True, text=True,
                               encoding="utf-8", errors="replace", timeout=60)
            got = [line.split("\t")[:2] for line in r.stdout.splitlines() if line.strip()]
            check(f"WowPilotSync.exe: acha as variações a partir de {arg.name} (Retail, Forever, sem pasta vazia)",
                  got == [["Retail", "wow"], ["WoW: Forever", "wowf"], ["Novo", "novo"], ["PTR 2", "wowxptr"]],
                  r.stdout + r.stderr)
    finally:
        shutil.rmtree(root.parent, ignore_errors=True)


def check_shortcuts(check, exe: Path):
    """Atalhos do .exe numa pasta de teste (no lugar do Menu Iniciar e da Área de Trabalho)."""
    temp = subprocess.run(["cmd.exe", "/c", "echo %TEMP%"], capture_output=True, text=True).stdout.strip()
    base = Path(subprocess.run(["wslpath", "-u", temp], capture_output=True, text=True).stdout.strip()) / "wowpilot_links"
    shutil.rmtree(base, ignore_errors=True)
    (base / "cfg").mkdir(parents=True)

    def run(cfg: dict):
        (base / "cfg" / "config.json").write_text(json.dumps(cfg), encoding="utf-8")
        subprocess.run([str(exe), "--sync-shortcuts", "--config-dir", win_path(base / "cfg"), "--links-dir", win_path(base)],
                       capture_output=True, timeout=60)

    def link(kind: str, name: str):
        f = base / kind / name
        if not f.exists():
            return None
        ps = f"$l = (New-Object -ComObject WScript.Shell).CreateShortcut('{win_path(f)}'); $l.TargetPath + '|' + $l.Arguments"
        return subprocess.run(["powershell.exe", "-NoProfile", "-Command", ps], capture_output=True, text=True).stdout.strip().lower()

    me = win_path(exe).lower()
    try:
        run({})
        got = [link(k, n) for k in ("menu", "desktop") for n in ("WowPilot Sync.lnk", "WowPilot.lnk")]
        check("WowPilotSync.exe: atalhos no Menu Iniciar (programa e site) por padrão; Área de Trabalho não",
              got == [me + "|", me + "|--open-site", None, None], str(got))
        run({"NoStartMenu": True, "DesktopShortcut": True})
        got = [link(k, n) for k in ("menu", "desktop") for n in ("WowPilot Sync.lnk", "WowPilot.lnk")]
        check("WowPilotSync.exe: desligar remove os atalhos; Área de Trabalho quando pedido",
              got == [None, None, me + "|", me + "|--open-site"], str(got))
    finally:
        shutil.rmtree(base, ignore_errors=True)


def check_update(check, exe: Path):
    """Atualização (--update) contra um 'GitHub' local: troca o .exe, atualiza o addon onde ele está, confere o SHA-256."""
    import hashlib
    import io
    import zipfile
    temp = subprocess.run(["cmd.exe", "/c", "echo %TEMP%"], capture_output=True, text=True).stdout.strip()
    base = Path(subprocess.run(["wslpath", "-u", temp], capture_output=True, text=True).stdout.strip()) / "wowpilot_update"
    shutil.rmtree(base, ignore_errors=True)
    app = base / "app"
    app.mkdir(parents=True)
    shutil.copy(exe, app / "WowPilotSync.exe")
    root = base / "World of Warcraft"
    for folder, product, addon in (("_retail_", "wow", True), ("_forever_", "wowf", False)):
        d = root / folder
        d.mkdir(parents=True)
        (d / ".flavor.info").write_bytes(f"Product Flavor!STRING:0\r\n{product}\r\n".encode())
        if addon:
            (d / "Interface" / "AddOns" / "WowPilot").mkdir(parents=True)
            (d / "Interface" / "AddOns" / "WowPilot" / "WowPilot.toc").write_text("## Version: 0.0.1\n")
    new_exe = b"MZ novo .exe de teste"
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("WowPilot/WowPilot.toc", "## Version: 9.9.9\n")
        z.writestr("WowPilot/WowPilot.lua", "-- novo")
        z.writestr("WowPilot/../fora.txt", "não pode sair da pasta")
    new_zip = buf.getvalue()
    sha = lambda b: "sha256:" + hashlib.sha256(b).hexdigest()

    class Gh(BaseHTTPRequestHandler):
        tag, exe_digest = "v9.9.9", sha(new_exe)

        def do_GET(self):
            port = self.server.server_port
            if self.path == "/latest":
                body = json.dumps({"tag_name": Gh.tag, "html_url": "x", "assets": [
                    {"name": "WowPilotSync.exe", "browser_download_url": f"http://127.0.0.1:{port}/exe", "digest": Gh.exe_digest},
                    {"name": "WowPilot.zip", "browser_download_url": f"http://127.0.0.1:{port}/zip", "digest": sha(new_zip)}]}).encode()
            else:
                body = new_exe if self.path == "/exe" else new_zip
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    srv = HTTPServer(("0.0.0.0", 0), Gh)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    def run():
        r = subprocess.run([str(app / "WowPilotSync.exe"), "--update", "--api", f"http://127.0.0.1:{srv.server_port}/latest",
                            "--wow", win_path(root), "--config-dir", win_path(base / "cfg")],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
        return r.stdout + r.stderr

    toc = root / "_retail_" / "Interface" / "AddOns" / "WowPilot" / "WowPilot.toc"
    try:
        Gh.exe_digest = "sha256:" + "0" * 64          # 1) SHA-256 errado: nada muda
        out = run()
        check("WowPilotSync.exe: atualização com SHA-256 errado não troca nada",
              "confere" in out and toc.read_text() == "## Version: 0.0.1\n"
              and (app / "WowPilotSync.exe").read_bytes() != new_exe, out)
        Gh.exe_digest = sha(new_exe)                    # 2) certo: troca o .exe e o addon onde ele está
        out = run()
        check("WowPilotSync.exe: atualização troca o .exe e o addon só onde ele está instalado",
              (app / "WowPilotSync.exe").read_bytes() == new_exe and (app / "WowPilotSync.exe.old").exists()
              and toc.read_text() == "## Version: 9.9.9\n" and (toc.parent / "WowPilot.lua").exists()
              and not (root / "_forever_" / "Interface").exists() and not (toc.parent.parent / "fora.txt").exists()
              and "addon: Retail" in out, out)
        shutil.copy(exe, app / "WowPilotSync.exe")     # 3) mesma versão: nada a fazer
        Gh.tag = "v" + subprocess.run(["powershell.exe", "-NoProfile", "-Command",
                                       f"(Get-Item '{win_path(exe)}').VersionInfo.ProductVersion"],
                                      capture_output=True, text=True).stdout.strip()
        out = run()
        check(f"WowPilotSync.exe: na versão mais recente ({Gh.tag}) não faz nada", "mais recente" in out, out)
    finally:
        srv.shutdown()
        shutil.rmtree(base, ignore_errors=True)


def check_addon_install(check, exe: Path):
    """Addon embutido no .exe: instala no Retail/Forever, atualiza versão velha, não mexe em clone do git nem no PTR."""
    temp = subprocess.run(["cmd.exe", "/c", "echo %TEMP%"], capture_output=True, text=True).stdout.strip()
    root = Path(subprocess.run(["wslpath", "-u", temp], capture_output=True, text=True).stdout.strip()) / "wowpilot_addon" / "World of Warcraft"
    shutil.rmtree(root.parent, ignore_errors=True)
    for folder, product in (("_retail_", "wow"), ("_forever_", "wowf"), ("_xptr_", "wowxptr")):
        d = root / folder
        (d / "WTF").mkdir(parents=True)
        (d / ".flavor.info").write_bytes(f"Product Flavor!STRING:0\r\n{product}\r\n".encode())
    old = root / "_forever_" / "Interface" / "AddOns" / "WowPilot"
    old.mkdir(parents=True)
    (old / "WowPilot.toc").write_text("## Version: 0.0.1\n")
    mine = (ROOT / "WowPilot.toc").read_bytes()
    addon = lambda f: root / f / "Interface" / "AddOns" / "WowPilot"

    def run():
        r = subprocess.run([str(exe), "--install-addon", "--wow", win_path(root)], capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=60)
        return r.stdout + r.stderr
    try:
        out = run()
        check("WowPilotSync.exe: instala o addon embutido no Retail, atualiza o do Forever, não mexe no PTR",
              (addon("_retail_") / "WowPilot.toc").read_bytes() == mine
              and (addon("_retail_") / "WowPilotLive.lua").read_bytes() == (ROOT / "WowPilotLive.lua").read_bytes()
              and (old / "WowPilot.toc").read_bytes() == mine and not addon("_xptr_").exists(), out)
        out2 = run()
        (old / "WowPilot.toc").write_text("## Version: 0.0.1\n")
        (old / ".git").mkdir()
        out3 = run()
        check("WowPilotSync.exe: na mesma versão não regrava; clone do git fica como está",
              out2.strip() == "" and out3.strip() == "" and (old / "WowPilot.toc").read_text() == "## Version: 0.0.1\n",
              out2 + out3)
    finally:
        shutil.rmtree(root.parent, ignore_errors=True)


def main():
    failed = 0

    def check(name, ok, detail=""):
        nonlocal failed
        failed += not ok
        print(f"  {'ok   ' if ok else 'FALHA'} {name}" + (f"\n        {detail}" if not ok and detail else ""))

    lua = fresh()
    lua.execute('fire("ADDON_LOADED", "WowPilot"); fire("PLAYER_LOGIN")')
    lua.execute('fire("CHAT_MSG_WHISPER", "bora +8? \\"aspas\\" ção", "Tank-Reinoteste", "", "", "", "", 0, 0, "", 0, 1, "", 0)')
    payload = lua.eval("NS.Live.fullPayload(false)")
    tmp = Path("/tmp/wowpilot_decode_test")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir()

    # 1) snapshot real (1 página, sem compressão)
    (code,), _, _ = frames(lua, payload)
    small = [paint(lua, code)]
    for name, img in (("PNG", small[0]), ("PNG gama 1,25 / brilho 0,92", distort(small[0], 1.25, 0.92)),
                      ("PNG gama 0,8", distort(small[0], 0.8))):
        p = tmp / "a.png"
        img.save(p, "PNG")
        out = ref_decode([p])
        check(f"referência: {name} ({len(payload)} bytes, {code.rows} linhas)", out == payload)
    p = tmp / "normal.png"
    scene(2).save(p, "PNG")
    check("referência: print normal não é decodificado", decode_file(p) is None)

    # 2) grande e incompressível: várias páginas
    rnd = random.Random(3)
    big = json.dumps({**json.loads(payload), "pad": "".join(rnd.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(45000))})
    codes, raw, sent = frames(lua, big)
    pages = [paint(lua, c, seed=i + 3) for i, c in enumerate(codes)]
    paths = []
    for i, img in enumerate(pages):
        paths.append(tmp / f"p{i}.png")
        img.save(paths[-1], "PNG")
    check(f"referência: {len(codes)} páginas fora de ordem ({raw} bytes)", len(codes) >= 3 and ref_decode(paths[::-1]) == big)

    # 3) comprimido (zlib do Python no lugar de C_EncodingUtil)
    lua.globals().C_EncodingUtil = lua.table(CompressString=lambda s, *_: zlib.compress(
        s if isinstance(s, bytes) else s.encode("utf-8"), 9))
    medium = json.dumps({**json.loads(payload), "simc": "shaman=x\n" * 800})
    codes_z, raw_z, sent_z = frames(lua, medium)
    zipped = [paint(lua, c, seed=7) for c in codes_z]
    p = tmp / "z.png"
    zipped[0].save(p, "PNG")
    check(f"referência: comprimido {raw_z} → {sent_z} bytes", sent_z < raw_z and ref_decode([p]) == medium)

    # 4) clientes de verdade (PowerShell + C# e o WowPilotSync.exe compilado por client/build.cmd)
    client = ROOT / "client"
    src = (client / "WowPilotSync.ps1").read_text(encoding="utf-8-sig")
    embedded = src.split("$decoderSource = @'", 1)[1].split("\n'@", 1)[0].strip()
    standalone = (client / "WowPilotSync" / "Decoder.cs").read_text(encoding="utf-8").split("using System;", 1)[1]
    check("decodificador do .ps1 igual ao client/WowPilotSync/Decoder.cs",
          embedded.replace("\r\n", "\n") == ("using System;" + standalone).strip().replace("\r\n", "\n"))
    if shutil.which("powershell.exe"):
        for name, exe in (("WowPilotSync.ps1", False), ("WowPilotSync.exe", True)):
            if exe and not (client / "WowPilotSync.exe").exists():
                print("  (sem client/WowPilotSync.exe: rode client\\build.cmd)")
                continue
            got, left, log = run_client([small, pages, zipped], exe, chat=True)
            bodies = [b for path, _, b in got if path == "/api/ingest"]
            check(f"{name}: 3 mensagens enviadas a /api/ingest com o token",
                  len(bodies) == 3 and all(a == "Token tk123" for _, a, _ in got), log)
            check(f"{name}: com o chat ligado, JSON idêntico (1 página, multipágina, comprimido)",
                  bodies == [payload, big, medium], log if len(bodies) == 3 else "")
            check(f"{name}: prints com código apagados, print normal mantido",
                  left == ["WoWScrnShot_101726_115959.png"], str(left))
            # padrão: o chat sai do JSON e o resto chega igual
            got, _, log = run_client([small, pages, zipped], exe)
            bodies = [b for path, _, b in got if path == "/api/ingest"]
            want = [{k: v for k, v in json.loads(p).items() if k != "chat"} for p in (payload, big, medium)]
            check(f"{name}: com o chat desligado (padrão), sem chat e o resto igual",
                  '"chat"' in payload and [json.loads(b) for b in bodies] == want
                  and all('"chat"' not in b for b in bodies), log)
        exe = client / "WowPilotSync.exe"
        if exe.exists():
            check_games(check, exe)
            check_shortcuts(check, exe)
            check_update(check, exe)
            check_addon_install(check, exe)
    else:
        print("  (sem powershell.exe: clientes não testados)")
    shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
