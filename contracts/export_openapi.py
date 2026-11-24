#!/usr/bin/env python3
"""Export every Jarvis service's OpenAPI spec into contracts/openapi/, or check that the committed copies are current.

    python3 contracts/export_openapi.py            # regenerate the files (then review the git diff and commit it)
    python3 contracts/export_openapi.py --check    # exit 1 if a spec on disk no longer matches its service's code

The spec is what a service's own FastAPI app says about itself (`app.openapi()`), produced by importing the app in
that service's virtualenv: nothing is started and no database or broker is contacted. Committing the output turns
every API change into a visible diff, in the same PR as the code that caused it, for whoever works on a caller.

--check also names what changed and marks the changes that can break a caller (BREAKING): a removed endpoint, a
removed or retyped field, a field or parameter that became required. It is a quick screen, not a full compatibility
proof: it compares field names, types and required lists, not enums, formats or constraints.

Expects the repos side by side (jarvis-deploy, jarvis-backend, ...) each with a `.venv`, as in the workspace.
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[1]
OUT = HERE / "openapi"

# name -> (repo directory, extra environment its settings need just to be imported)
SERVICES = {
    "backend": ("jarvis-backend", {"OPENROUTER_API_KEY": "contract-export"}),
    "conversation-service": ("jarvis-conversation-service", {}),
    "file-service": ("jarvis-file-service", {}),
}
BASE_ENV = {"DATABASE_URL": "postgresql://contract:export@localhost/contract"}

_DUMP = (
    "import json, sys\n"
    "from app.main import app\n"
    "open(sys.argv[1], 'w').write(json.dumps(app.openapi(), indent=2, sort_keys=True, ensure_ascii=False) + '\\n')\n"
)
METHODS = {"get", "put", "post", "delete", "options", "head", "patch", "trace"}


def generate(name: str) -> dict:
    repo, extra = SERVICES[name]
    cwd = WORKSPACE / repo
    python = cwd / ".venv" / "bin" / "python"
    if not python.exists():
        sys.exit(f"{name}: no virtualenv at {python} (run `make install` in {repo})")
    import os

    env = {**os.environ, **BASE_ENV, **extra}
    with tempfile.NamedTemporaryFile("r", suffix=".json") as tmp:
        result = subprocess.run([str(python), "-c", _DUMP, tmp.name], cwd=cwd, env=env, capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(f"{name}: could not import the app\n{result.stderr[-1500:]}")
        return json.load(tmp)


def operations(spec: dict) -> dict:
    return {(p, m): op for p, item in spec.get("paths", {}).items() for m, op in item.items() if m in METHODS}


def _type(prop: dict) -> str:
    return json.dumps({k: prop[k] for k in ("type", "$ref", "anyOf", "oneOf", "allOf", "items", "enum") if k in prop}, sort_keys=True)


def diff(old: dict, new: dict) -> list[tuple[bool, str]]:
    """(is_breaking, message) for every difference worth a human's attention."""
    out: list[tuple[bool, str]] = []
    oo, no = operations(old), operations(new)
    for key in sorted(set(oo) - set(no)):
        out.append((True, f"endpoint removed: {key[1].upper()} {key[0]}"))
    for key in sorted(set(no) - set(oo)):
        out.append((False, f"endpoint added: {key[1].upper()} {key[0]}"))
    for key in sorted(set(oo) & set(no)):
        label = f"{key[1].upper()} {key[0]}"
        op_old = {(p["in"], p["name"]): p for p in oo[key].get("parameters", [])}
        op_new = {(p["in"], p["name"]): p for p in no[key].get("parameters", [])}
        for pk in sorted(set(op_old) - set(op_new)):
            out.append((False, f"{label}: parameter removed: {pk[1]} ({pk[0]})"))
        for pk in sorted(set(op_new) - set(op_old)):
            out.append((op_new[pk].get("required", False), f"{label}: parameter added: {pk[1]} ({pk[0]})"
                        + (" REQUIRED" if op_new[pk].get("required") else "")))
        for pk in sorted(set(op_old) & set(op_new)):
            if not op_old[pk].get("required") and op_new[pk].get("required"):
                out.append((True, f"{label}: parameter became required: {pk[1]}"))
        if ("requestBody" in no[key]) != ("requestBody" in oo[key]):
            out.append((True, f"{label}: request body {'added' if 'requestBody' in no[key] else 'removed'}"))
    so, sn = old.get("components", {}).get("schemas", {}), new.get("components", {}).get("schemas", {})
    for name in sorted(set(so) - set(sn)):
        out.append((True, f"schema removed: {name}"))
    for name in sorted(set(sn) - set(so)):
        out.append((False, f"schema added: {name}"))
    for name in sorted(set(so) & set(sn)):
        po, pn = so[name].get("properties", {}), sn[name].get("properties", {})
        for prop in sorted(set(po) - set(pn)):
            out.append((True, f"{name}.{prop}: field removed"))
        for prop in sorted(set(pn) - set(po)):
            out.append((False, f"{name}.{prop}: field added"))
        for prop in sorted(set(po) & set(pn)):
            if _type(po[prop]) != _type(pn[prop]):
                out.append((True, f"{name}.{prop}: type changed"))
        ro, rn = set(so[name].get("required", [])), set(sn[name].get("required", []))
        for prop in sorted(rn - ro):
            out.append((True, f"{name}.{prop}: became required"))
        for prop in sorted(ro - rn):
            out.append((False, f"{name}.{prop}: no longer required"))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true", help="do not write; exit 1 if a committed spec is out of date")
    ap.add_argument("only", nargs="*", choices=list(SERVICES), help="limit to these services")
    args = ap.parse_args()
    names = args.only or list(SERVICES)
    stale = False
    for name in names:
        new = generate(name)
        path = OUT / f"{name}.json"
        text = json.dumps(new, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
        old = json.loads(path.read_text()) if path.exists() else None
        if old is not None and path.read_text() == text:
            print(f"ok       {name}: {len(operations(new))} operations, up to date")
            continue
        if args.check:
            stale = True
            print(f"STALE    {name}: {path.relative_to(WORKSPACE)} does not match the code")
            for breaking, msg in diff(old or {}, new) if old else [(False, "no committed spec yet")]:
                print(f"   {'BREAKING' if breaking else 'change  '}  {msg}")
        else:
            path.write_text(text)
            print(f"written  {name}: {len(operations(new))} operations -> {path.relative_to(WORKSPACE)}")
            if old is not None:
                for breaking, msg in diff(old, new):
                    print(f"   {'BREAKING' if breaking else 'change  '}  {msg}")
    if stale:
        print("\nRun `python3 jarvis-deploy/contracts/export_openapi.py` and commit the result (review any BREAKING lines first).")
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
