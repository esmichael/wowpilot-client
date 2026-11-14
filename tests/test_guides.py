"""WowPilotGuides.lua: sem o RXP não faz nada; com ele, registra o guia da pesca com a missão 6607 e os quatro peixes."""
import re
from pathlib import Path

import lupa

SRC = (Path(__file__).resolve().parent.parent / "WowPilotGuides.lua").read_text(encoding="utf-8")


def run(with_rxp):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    if with_rxp:
        lua.execute("GUIDES = {}; RXPGuides = { RegisterGuide = function(t) table.insert(GUIDES, t) end }")
    else:
        lua.execute("GUIDES = {}")
    lua.execute(SRC)
    return [lua.globals().GUIDES[i] for i in range(1, len(lua.globals().GUIDES) + 1)]


def main():
    assert run(False) == [], "sem RXP não registra nada"
    g = run(True)
    assert len(g) == 1, g
    text = g[0]
    for tag in ("#classic", "#forever", "#name ", "#group +WowPilot", ".accept 6607", ".turnin 6607", ".train 18248"):
        assert tag in text, tag
    fish = set(re.findall(r"\.collect (\d+),1,6607", text))
    assert fish == {"16967", "16968", "16969", "16970"}, fish
    zones = set(re.findall(r"\.goto ([^,]+),", text))
    assert zones <= {"Dustwallow Marsh", "Desolace", "Feralas", "Stranglethorn Vale", "Swamp of Sorrows"}, zones
    for x, y in re.findall(r"\.goto [^,]+,([\d.]+),([\d.]+)", text):
        assert 0 < float(x) < 100 and 0 < float(y) < 100, (x, y)
    assert all(l.startswith(("step", "    ", "#", "<<")) for l in text.strip().splitlines() if l.strip()), "linha fora de um passo"
    print("guides OK")


if __name__ == "__main__":
    main()
