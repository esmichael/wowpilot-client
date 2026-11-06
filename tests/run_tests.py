"""Roda os testes do WowPilot fora do jogo, com um stub da API do WoW.

Requisito:  pip install lupa
Uso:        python3 tests/run_tests.py        (a partir da pasta do addon)

Cada teste roda num Lua novo: stub -> WowPilot.lua -> teste.
O lupa usa Lua 5.4/5.5; o WoW usa Lua 5.1. Evite sintaxe nova (goto, //, <const>)
no addon — o teste não pegaria, mas o jogo quebraria.
"""
import sys
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent
STUB = (ROOT / "tests" / "wow_stub.lua").read_text(encoding="utf-8")
ADDON_FILES = ["WowPilot.lua", "WowPilotLive.lua"]  # mesma ordem do .toc
TESTS = "\n".join((ROOT / "tests" / n).read_text(encoding="utf-8").rstrip().removesuffix("return T")
                  for n in ("test_wowpilot.lua", "test_live.lua")) + "\nreturn T\n"


def fresh(name=""):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    if name.startswith("forever:"):  # cliente do WoW: Forever (interface 16xxx), decidido ao carregar o addon
        lua.execute("STUB_BUILD = 16001")
    lua.execute(STUB)
    load = lua.eval("""function(src, name)
        NS = NS or {}
        local f = assert((loadstring or load)(src, name)); f('WowPilot', NS)
    end""")
    for name in ADDON_FILES:
        load((ROOT / name).read_text(encoding="utf-8"), "@" + name)
    return lua


def main():
    names = list(fresh().execute(TESTS).keys())
    failed = 0
    for name in sorted(names):
        lua = fresh(name)
        test = lua.execute(TESTS)[name]
        try:
            test()
            print(f"  ok    {name}")
        except lupa.LuaError as e:
            failed += 1
            print(f"  FALHA {name}\n        {str(e).splitlines()[0]}")
    print(f"\n{len(names) - failed}/{len(names)} passaram")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
