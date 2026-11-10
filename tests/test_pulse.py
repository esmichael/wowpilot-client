"""Pulso ponta a ponta: WowPilotPulse.lua (faixa no canto) → imagem → leitor de referência e o WowPilotSync.exe real.

Uso: python3 tests/test_pulse.py   (o .exe só se houver client/WowPilotSync.exe e cmd.exe — WSL)
"""
import json
import math
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_tests import ROOT, fresh  # noqa: E402

CELL, COLS, ROWS = 2, 56, 2


def adler32(b: bytes) -> int:
    a, s = 1, 0
    for x in b:
        a = (a + x) % 65521
        s = (s + a) % 65521
    return s * 65536 + a


def decode(img: Image.Image):
    """Leitor de referência (o mesmo do Pulse.cs)."""
    px = img.convert("RGB").load()
    bits = []
    for r in range(ROWS):
        for c in range(COLS):
            rgb = [0, 0, 0]
            for dy in range(CELL):
                for dx in range(CELL):
                    p = px[c * CELL + dx, r * CELL + dy]
                    for k in range(3):
                        rgb[k] += p[k]
            bits += [1 if v // (CELL * CELL) >= 128 else 0 for v in rgb]
    data = bytes(int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits) - 7, 8))
    if data[:3] != b"WQ\x01" or data[3] != 34:
        return None
    content = data[4:38]
    if adler32(content) != int.from_bytes(data[38:42], "big"):
        return None
    u = lambda i, n: int.from_bytes(content[i:i + n], "big")  # noqa: E731
    s = lambda i: int.from_bytes(content[i:i + 4], "big", signed=True) / 10  # noqa: E731
    return {"seq": u(0, 2), "t": u(2, 4), "char": u(6, 4), "ui": u(10, 2), "x": u(12, 2) / 65535 * 100,
            "y": u(14, 2) / 65535 * 100, "pos": [s(16), s(20), s(24)], "facing": content[28], "hp": content[29],
            "flags": content[30], "lvl": content[31], "deaths": u(32, 2)}


def render(lua) -> Image.Image:
    """Redesenha a faixa a partir das texturas do stub (posição, tamanho e cor de cada célula)."""
    frame = lua.globals().WowPilotPulse
    assert frame is not None and frame.shown, "faixa na tela"
    img = Image.new("RGB", (COLS * CELL + 10, ROWS * CELL + 6), (40, 90, 160))   # resto da tela: qualquer cor
    cells = [t for t in lua.globals().TEXLIST.values() if t.w == CELL and t.h == CELL and t.r is not None][-COLS * ROWS:]
    assert len(cells) == COLS * ROWS, len(cells)
    for t in cells:
        x, y = int(t.x), int(-t.y)
        for dy in range(CELL):
            for dx in range(CELL):
                img.putpixel((x + dx, y + dy), tuple(int(v * 255) for v in (t.r, t.g, t.b)))
    return img


def setup(lua, dead=False):
    lua.execute(f"""
        WorldFrame = {{}}
        C_Map = C_Map or {{}}
        C_Map.GetBestMapForUnit = function() return 1441 end
        C_Map.GetPlayerMapPosition = function() return {{ GetXY = function() return 0.4214, 0.338 end }} end
        UnitPosition = function() return -2287.5, -4958.2, -66.5, 1 end
        GetPlayerFacing = function() return 1.5 end
        UnitHealth = function() return 300 end
        UnitHealthMax = function() return 420 end
        UnitIsDeadOrGhost = function() return {str(dead).lower()} end
        UnitIsGhost = function() return {str(dead).lower()} end
        IsMounted = function() return true end
        UnitLevel = function() return 27 end
    """)


def main():
    fails = 0

    def check(name, cond, extra=""):
        nonlocal fails
        print(f"  {'ok   ' if cond else 'FALHA'} {name}{(' — ' + extra) if extra and not cond else ''}")
        fails += 0 if cond else 1

    lua = fresh("forever:pulso")
    setup(lua)
    lua.globals().fire("ADDON_LOADED", "WowPilot")
    lua.globals().fire("PLAYER_LOGIN")
    img = render(lua)
    d = decode(img)
    check("faixa decodifica (cabeçalho, tamanho, adler32)", d is not None)
    if d:
        me = lua.eval("NS.selfTarget()")
        check("personagem = adler32 de Nome-Reino", d["char"] == adler32(me.encode()), str(d["char"]))
        check("mapa e posição no mapa", d["ui"] == 1441 and abs(d["x"] - 42.14) < 0.01 and abs(d["y"] - 33.8) < 0.01, str(d))
        check("posição no mundo com sinal (jd × 10)", d["pos"] == [-2287.5, -4958.2, -66.5], str(d["pos"]))
        check("direção, vida %, nível", abs(d["facing"] / 256 * 2 * math.pi - 1.5) < 0.03 and d["hp"] == 71 and d["lvl"] == 27, str(d))
        check("estado: montado, direção e posição ok; vivo", d["flags"] == 32 + 64 + 128, str(d["flags"]))
        seq = d["seq"]
        lua.execute("NS.Pulse.tick()")
        check("parado: mesmo pacote (o cliente não reenvia)", decode(render(lua))["seq"] == seq)
        setup(lua, dead=True)
        lua.execute("NS.Pulse.tick()")
        d2 = decode(render(lua))
        check("morreu: novo seq e estado morto/fantasma", d2 and d2["seq"] == seq + 1 and d2["flags"] & 3 == 3, str(d2))
        lua.execute("SlashCmdList.WOWPILOT('pulso off')")
        check("/wpilot pulso off esconde a faixa", not lua.globals().WowPilotPulse.shown)

    exe = ROOT / "client" / "WowPilotSync.exe"
    if shutil.which("cmd.exe") and exe.exists():
        temp = subprocess.run(["cmd.exe", "/c", "echo %TEMP%"], capture_output=True, cwd="/mnt/c",
                              text=True, errors="replace").stdout.strip()
        wtemp = Path(subprocess.run(["wslpath", temp], capture_output=True, text=True).stdout.strip())
        with tempfile.TemporaryDirectory(dir=wtemp) as tmp:
            png = Path(tmp) / "pulso.png"
            img.save(png)
            win = subprocess.run(["wslpath", "-w", str(png)], capture_output=True, text=True).stdout.strip()
            r = subprocess.run([str(exe), "--pulse-png", win], capture_output=True, text=True, timeout=60)
            try:
                j = json.loads(r.stdout)
            except ValueError:
                j = None
            check("WowPilotSync.exe lê a faixa (mesmos valores)", j is not None and j["ui"] == 1441 and j["pos"] == [-2287.5, -4958.2, -66.5]
                  and j["hp"] == 71 and j["flags"] == 224 and j["deaths"] == 0 and abs(j["x"] - 42.14) < 0.01, r.stdout + r.stderr)
    else:
        print("  (sem client/WowPilotSync.exe ou cmd.exe: só o leitor de referência)")
    print("ok" if not fails else f"{fails} falha(s)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
