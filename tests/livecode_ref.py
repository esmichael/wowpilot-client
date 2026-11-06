"""Decodifica o código de pixels que o WowPilotLive.lua desenha antes do Screenshot().

Layout (ver WowPilotLive.lua): num canto da imagem, células quadradas;
linha 0 e coluna 0 são padrões de tempo; bits em linhas, MSB primeiro, preto = 1.
Cabeçalho v1 (10 bytes): "WP" | 1 | colunas | tamanho (2) | adler32 (4)
Cabeçalho v2 (16 bytes): "WP" | 2 | colunas | tipo | flags | msg (2) | página | total | tamanho (2) | adler32 (4)
Cada imagem traz uma página; Assembler junta as páginas e descomprime (flags bit 0).
v3 (colorido): linha 1 = B em binário (células 1–8) + paleta de 2^B cores (células 9…), dados da linha 2
com B bits por célula; cada cor é classificada pela cor mais próxima da paleta medida na própria imagem
(resiste a gama/brilho/filtros do jogo).
"""
import re
import zlib
from pathlib import Path

from PIL import Image, ImageOps

HEADERS = {1: 10, 2: 16, 3: 16}
KIND_SUMMARY, KIND_GEAR, KIND_FULL, KIND_CALIB = 1, 2, 3, 4
VAULT_RE = re.compile(r"([^.,]+)\.([^.,]+)\.(\d+)/(\d+)\.(\d+)")
DARK = 128


def _cell_size(img) -> float | None:
    """Mede a célula pelas transições do padrão de tempo da linha 0."""
    w, h = img.size
    px = img.load()
    if w < 64 or h < 4 or px[0, 0] >= DARK:
        return None
    # primeira célula (preta) dá a estimativa inicial; depois mede ~64 transições no meio da linha
    first = 0  # 1ª célula preta da linha 0 (só a linha 0: com célula de 1 px a linha y=1 já é outra célula)
    while first < min(w, 64) and px[first, 0] < DARK:
        first += 1
    if not 1 <= first <= 32:
        return None
    y = min(h - 1, first // 2)
    # mede pelas transições do padrão de tempo inteiro (até 254): com 255 colunas, um erro pequeno
    # na célula se acumula até a última coluna; para quando o padrão acaba (cena do jogo)
    edges, prev = [], px[0, y] < DARK
    for x in range(1, min(w, first * 320)):
        cur = px[x, y] < DARK
        if cur != prev:
            prev = cur
            c = edges[-1] / len(edges) if edges else first
            if abs(x - (len(edges) + 1) * c) > max(c * 0.5, 1.0):
                break
            edges.append(x)
            if len(edges) >= 254:  # 255 células = 254 transições: o resto já é a cena do jogo
                break
    if len(edges) < 16:
        return None
    c = edges[-1] / len(edges)
    # o addon desenha 1 unidade = 1 pixel físico: célula inteira (bordas falsas da cena puxavam p/ 2,99)
    return float(round(c)) if abs(c - round(c)) < 0.05 else c


def _reader(img, c):
    px = img.load()
    w, h = img.size
    r = max(0, int(c / 3))  # média de uma pequena janela no centro (resiste a JPEG)

    def bit(row, col):
        cx, cy = int((col + 0.5) * c), int((row + 0.5) * c)
        if cx >= w or cy >= h:
            raise IndexError
        total = n = 0
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                total += px[min(w - 1, max(0, cx + dx)), min(h - 1, max(0, cy + dy))]
                n += 1
        return 1 if total / n < DARK else 0
    return bit


def _read_bytes(bit, cols, start, count):
    width = cols - 1
    out = bytearray()
    for i in range(start, start + count):
        b = 0
        for k in range(8):
            idx = i * 8 + k
            row, col = 1 + idx // width, 1 + idx % width
            b = (b << 1) | bit(row, col)
        out.append(b)
    return bytes(out)


def _color_reader(rgb, c, bpc, cols):
    """Lê a paleta da linha 1 e devolve read_bits(start_bit, count) para os dados (linha 2 em diante)."""
    px = rgb.load()
    w, h = rgb.size
    r = max(0, int(c / 4))

    def sample(row, col):
        cx, cy = int((col + 0.5) * c), int((row + 0.5) * c)
        if cx >= w or cy >= h:
            raise IndexError
        acc = [0, 0, 0]
        n = 0
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                p = px[min(w - 1, max(0, cx + dx)), min(h - 1, max(0, cy + dy))]
                acc[0] += p[0]; acc[1] += p[1]; acc[2] += p[2]
                n += 1
        return acc[0] / n, acc[1] / n, acc[2] / n

    cache = {}
    if bpc <= 6:  # paleta inteira na linha 1: cor mais próxima
        palette = [sample(1, 9 + i) for i in range(2 ** bpc)]

        def classify(p):
            k = (int(p[0]) >> 2, int(p[1]) >> 2, int(p[2]) >> 2)
            if k not in cache:
                cache[k] = min(range(len(palette)), key=lambda i: (p[0] - palette[i][0]) ** 2
                               + (p[1] - palette[i][1]) ** 2 + (p[2] - palette[i][2]) ** 2)
            return cache[k]
    else:  # níveis de cada canal na linha 1: classifica R, G e B separadamente
        L, k = 2 ** (bpc // 3), bpc // 3
        levels = [[sample(1, 9 + ch * L + lv)[ch] for lv in range(L)] for ch in range(3)]

        def nearest(ch, v):
            return min(range(L), key=lambda lv: abs(v - levels[ch][lv]))

        def classify(p):
            key = (int(p[0]), int(p[1]), int(p[2]))
            if key not in cache:
                cache[key] = (nearest(0, p[0]) << (2 * k)) | (nearest(1, p[1]) << k) | nearest(2, p[2])
            return cache[key]

    width = cols - 1
    cells = {}

    def cell(idx):
        if idx not in cells:
            cells[idx] = classify(sample(2 + idx // width, 1 + idx % width))
        return cells[idx]

    def read_bytes(start, count):
        out = bytearray()
        for i in range(start, start + count):
            b = 0
            for k in range(8):
                bitpos = i * 8 + k
                v = cell(bitpos // bpc)
                b = (b << 1) | ((v >> (bpc - 1 - bitpos % bpc)) & 1)
            out.append(b)
        return bytes(out)
    return read_bytes


def _decode_color(rgb, c, bpc):
    try:
        head = _color_reader(rgb, c, bpc, 255)(0, 4)  # 4 bytes cabem na 1ª linha de dados
        if head[:2] != b"WP" or head[2] != 3:
            return None
        cols = head[3]
        read = _color_reader(rgb, c, bpc, cols)
        head = read(0, 16)
        f = {"kind": head[4], "flags": head[5], "msg": int.from_bytes(head[6:8], "big"),
             "page": head[8], "total": head[9], "bits": bpc}
        size = int.from_bytes(head[10:12], "big")
        checksum = int.from_bytes(head[12:16], "big")
        chunk = read(16, size)
    except IndexError:
        return None
    if zlib.adler32(chunk) != checksum or f["page"] >= max(1, f["total"]):
        return None
    f["chunk"] = chunk
    return f


def decode_image(img: Image.Image) -> dict | None:
    """Uma página: {kind, flags, msg, page, total, chunk} ou None se não houver código válido."""
    rgb = img.convert("RGB")
    img = img.convert("L")
    c = _cell_size(img)
    if not c:
        return None
    bit = _reader(img, c)
    try:
        mode = _read_bytes(bit, 255, 0, 1)[0]  # v2: "W" (0x57); v3: bits por célula (3 ou 6)
    except IndexError:
        return None
    if mode in (3, 6, 9, 12):
        return _decode_color(rgb, c, mode)
    try:
        # o cabeçalho cabe nas primeiras linhas; lê com largura provisória e confirma pelas colunas gravadas
        head = _read_bytes(bit, 128, 0, 4)
        if head[:2] != b"WP" or head[2] not in HEADERS:
            return None
        ver, cols, size_h = head[2], head[3], HEADERS[head[2]]
        head = _read_bytes(bit, cols, 0, size_h)
        if ver == 1:
            f = {"kind": KIND_SUMMARY, "flags": 0, "msg": None, "page": 0, "total": 1}
        else:
            f = {"kind": head[4], "flags": head[5], "msg": int.from_bytes(head[6:8], "big"),
                 "page": head[8], "total": head[9]}
        size = int.from_bytes(head[size_h - 6:size_h - 4], "big")
        checksum = int.from_bytes(head[size_h - 4:size_h], "big")
        chunk = _read_bytes(bit, cols, size_h, size)
    except IndexError:
        return None
    if zlib.adler32(chunk) != checksum or f["page"] >= max(1, f["total"]):
        return None
    f["chunk"] = chunk
    f["cell"] = c
    f["rows"] = 1 + -(-((size_h + size) * 8) // (cols - 1))
    return f


def analyze_calib(path, f) -> dict:
    """Teste de cor (/wpilot live testecor): mede o desvio de cada nível e se células de 1 px sobrevivem.

    Retorna o erro por canal, quantos níveis por canal são distinguíveis com folga e a recomendação
    de bits por célula (3 × log2(níveis)) e de tamanho de célula.
    """
    import json as _json
    import math
    layout = _json.loads(f["chunk"].decode())
    c = int(round(f["cell"]))
    with Image.open(path) as im:
        img = im.convert("RGB")
    px = img.load()
    y0 = (f["rows"] + 2) * c
    rw, rh, step = layout["ramp"]["w"], layout["ramp"]["h"], layout["ramp"]["step"]
    ramps, noise = [], []
    for k in range(4):
        vals = []
        for i in range(256):
            pix = [px[i * rw + dx, y0 + k * step + dy] for dx in range(rw) for dy in range(1, rh - 1)]
            ch = [p[k] if k < 3 else sum(p) / 3 for p in pix]
            vals.append(sum(ch) / len(ch))
            noise.append(max(ch) - min(ch))
        ramps.append(vals)
    err = [max(abs(v - i) for i, v in enumerate(r)) for r in ramps]
    mono = all(all(r[i + 1] >= r[i] for i in range(255)) for r in ramps)
    nz = max(noise)

    def safe(levels):
        idx = [round(j * 255 / (levels - 1)) for j in range(levels)]
        gaps = [ramps[k][idx[j + 1]] - ramps[k][idx[j]] for k in range(3) for j in range(levels - 1)]
        return min(gaps) >= max(6, 3 * nz), min(gaps)
    levels = {L: safe(L) for L in (2, 4, 8, 16, 32, 64, 128, 256)}
    best = max([L for L, (ok, _) in levels.items() if ok] or [2])
    # células de 1 px
    y1 = y0 + 4 * step + 3
    stripes = sum(1 for x in range(256) for y in range(y1, y1 + layout["px"]["stripes"])
                  if (sum(px[x, y]) / 3 < 128) != (x % 2 == 0))
    y2 = y1 + 11
    lines = sum(1 for y in range(layout["px"]["lines"]) for x in range(64)
                if (sum(px[x, y2 + y]) / 3 < 128) != (y % 2 == 0))
    y3 = y2 + 19
    colored = 0
    for x in range(256):
        i = x % 64
        exp = ((i >> 4) * 85, ((i >> 2) & 3) * 85, (i & 3) * 85)
        got = px[x, y3 + 1]
        colored += max(abs(a - b) for a, b in zip(exp, got)) > 30
    one_px = stripes == 0 and lines == 0 and colored == 0
    return {"t": None, "cell": f["cell"], "maxError": dict(zip(("R", "G", "B", "cinza"), [round(e, 1) for e in err])),
            "monotonic": mono, "noise": nz,
            "levels": {L: {"ok": ok, "minGap": round(g, 1)} for L, (ok, g) in levels.items()},
            "bestLevels": best, "bitsPerCell": int(3 * math.log2(best)),
            "onePixel": {"ok": one_px, "stripeErrors": stripes, "lineErrors": lines, "colorErrors": colored}}


def decompress(data: bytes) -> bytes:
    """zlib, deflate cru ou gzip — aceita o que o C_EncodingUtil devolver."""
    for wbits in (15, -15, 31):
        try:
            return zlib.decompress(data, wbits)
        except zlib.error:
            continue
    raise ValueError("dados comprimidos inválidos")


class Assembler:
    """Junta páginas por número de mensagem; devolve (kind, texto) quando completa."""

    def __init__(self, ttl=180):
        self.partial: dict[int, dict] = {}
        self.ttl = ttl

    def add(self, f: dict, now: float):
        for k in [k for k, v in self.partial.items() if now - v["at"] > self.ttl]:
            del self.partial[k]  # mensagem que nunca completou
        if f["total"] <= 1:
            pages, key = {0: f["chunk"]}, None
        else:
            key = (f["msg"], f["kind"], f["total"], f["flags"])
            entry = self.partial.setdefault(key, {"at": now, "pages": {}})
            entry["pages"][f["page"]] = f["chunk"]
            if len(entry["pages"]) < f["total"]:
                return None
            pages = self.partial.pop(key)["pages"]
        data = b"".join(pages[i] for i in range(f["total"] or 1))
        if f["flags"] & 1:
            data = decompress(data)
        return f["kind"], data.decode("utf-8", errors="replace")


# canto da tela → (caixa a recortar, espelhar na horizontal, espelhar na vertical)
def _corners(w, h, cw=2400, ch=1200):
    cw, ch = min(w, cw), min(h, ch)  # 255 colunas × célula 8 px = 2040 px
    return [((0, 0, cw, ch), False, False), ((w - cw, 0, w, ch), True, False),
            ((0, h - ch, cw, h), False, True), ((w - cw, h - ch, w, h), True, True)]


def decode_file(path: Path) -> dict | None:
    """Tenta os 4 cantos; o WowPilotLive espelha o código para o canto escolhido."""
    try:
        with Image.open(path) as img:
            full = img.convert("RGB")
            for box, fx, fy in _corners(*full.size):
                part = full.crop(box)
                if fx:
                    part = ImageOps.mirror(part)
                if fy:
                    part = ImageOps.flip(part)
                f = decode_image(part)
                if f is not None:
                    f["corner"] = f"{'BOTTOM' if fy else 'TOP'}{'RIGHT' if fx else 'LEFT'}"
                    return f
    except (OSError, ValueError, Image.DecompressionBombError):
        return None
    return None


# ---------------------------------------------------------------- payload
def parse_payload(text: str) -> dict:
    """`k=v;k=v` (mesmo formato do campo raw) + eq/cr/vault expandidos."""
    d = {}
    for pair in text.split(";"):
        if "=" in pair:
            k, v = pair.split("=", 1)
            for conv in (int, float):
                try:
                    v = conv(v)
                    break
                except ValueError:
                    pass
            d[k] = v
    if isinstance(d.get("vault"), str):
        d["vault"] = [{"type": int(m[1]) if m[1].isdigit() else m[1], "index": int(m[2]),
                       "progress": int(m[3]), "threshold": int(m[4]), "level": int(m[5])}
                      for m in VAULT_RE.finditer(d["vault"])]
    eq = {}
    for item in str(d.get("eq") or "").split(","):
        p = item.split(".")
        if len(p) == 4:
            eq[p[0]] = {"id": int(p[1]), "ilvl": int(p[2]), "enchant": int(p[3]) or None}
    # nome/qualidade dos itens trocados desde o último sync: n_<slot>=<qualidade>~<nome>
    for k in [k for k in d if k.startswith("n_")]:
        quality, _, name = str(d.pop(k)).partition("~")
        if k[2:] in eq and name:
            eq[k[2:]].update(name=name, quality=int(quality) if quality.isdigit() else None)
    d["eq"] = eq
    cr = {}
    for item in str(d.get("cr") or "").split(","):
        p = item.split(".")
        if len(p) == 3:
            cr[int(p[0])] = {"qty": int(p[1]), "weekly": int(p[2])}
    d["cr"] = cr
    return d
