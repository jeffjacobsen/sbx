#!/usr/bin/env python3
"""The disposable credential a sandbox spends, behind a four-operation interface.

    credential.py mint   <name> <limit>   -> writes the secret to <keyfile>, prints the hash
    credential.py spend  <hash>           -> dollars spent so far, or "" if unknown
    credential.py revoke <hash>           -> prints ok | already_gone
    credential.py list                    -> TSV: name hash usage
    credential.py list-json               -> {"data": [...]}, the shape reap joins on
    credential.py revoke-managed <name> <hash>  -> revoke, re-asserting the prefix

WHY AN INTERFACE. The transferable idea here is not "OpenRouter keys". It is a
credential that is disposable, capped, tied to one VM's lifetime, revocable by
hash, and reapable when its VM dies. OpenRouter is the first implementation; an
Anthropic workspace-key provider is a natural second; and `none` -- this box
needs no inference credential at all -- is what makes the tool useful to someone
who only wants disposable VMs. Mounting a static site proved that case is real:
it minted a $50 key, spent $0, and revoked it, for nothing.

TWO RULES LIVE ABOVE THE INTERFACE, in this file, because they are correctness
rather than provider detail:

  1. Revocation is gated against the LIST, never the single-key GET. A dead key
     still returns 200 from GET /api/v1/key, so "did the delete work?" cannot be
     asked that way -- it has to be "is it still in the list?".

  2. The managed prefix is re-asserted AT THE POINT OF DELETION, not only at
     selection. A prefix check that happens when a candidate is chosen, and not
     again when it is destroyed, is one refactor away from deleting a personal
     key. The engineer's own keys carry no prefix and are unrecoverable.

Stdlib only, like run_record.py: this sits on the teardown path, and a missing
dependency must never be the reason a live key cannot be revoked.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

# The prefix that separates keys this tool manages from the engineer's own.
# Load-bearing: it is the entire safety model for `reap`.
MANAGED_PREFIX = "sbx-"

OPENROUTER_API = "https://openrouter.ai/api/v1"


def _provider() -> str:
    """Which implementation. The manifest may set it; the env always wins."""
    return os.environ.get("SBX_CREDENTIAL_PROVIDER", "openrouter").strip() or "openrouter"


# ── openrouter ───────────────────────────────────────────────────────────────

def _or_key() -> str:
    key = os.environ.get("OPENROUTER_PROVISIONING_KEY", "")
    if not key:
        sys.exit("credential: OPENROUTER_PROVISIONING_KEY is unset — cannot manage keys")
    return key


def _or_call(method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
    req = urllib.request.Request(
        f"{OPENROUTER_API}{path}",
        method=method,
        headers={"Authorization": f"Bearer {_or_key()}", "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None,
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw) if raw.strip() else {}
        except ValueError:
            return e.code, {"error": raw}


def or_mint(name: str, limit: float, keyfile: str) -> str:
    status, data = _or_call("POST", "/keys", {"name": name, "limit": limit})
    if status not in (200, 201):
        sys.exit(f"credential: mint failed (HTTP {status}): {json.dumps(data)[:400]}")
    inner = data.get("data") if isinstance(data.get("data"), dict) else {}
    # Observed shape is key at top level, hash under .data — accept either place.
    key = data.get("key") or inner.get("key")
    key_hash = data.get("hash") or inner.get("hash")
    if not key or not key_hash:
        sys.exit(f"credential: mint response missing key/hash (fields: {', '.join(sorted(data))})")
    # Straight to a 0600 file. The secret never reaches stdout, a log, or argv.
    fd = os.open(keyfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(key + "\n")
    return key_hash


def or_list() -> list[dict]:
    status, data = _or_call("GET", "/keys")
    if status != 200:
        sys.exit(f"credential: list failed (HTTP {status})")
    return [k for k in (data.get("data") or []) if isinstance(k, dict)]


def or_spend(key_hash: str) -> str:
    """Dollars spent, read from the LIST — the same source revocation is gated on."""
    for k in or_list():
        if k.get("hash") == key_hash:
            return str(k.get("usage", 0))
    return ""


def or_revoke(key_hash: str) -> str:
    status, _ = _or_call("DELETE", f"/keys/{key_hash}")
    # 404 is the normal idempotent-re-run path, not an error.
    if status not in (200, 204, 404):
        sys.exit(f"credential: revoke failed (HTTP {status}) for {key_hash}")
    # RULE 1: ask the LIST, never the single-key GET, which answers 200 for a
    # key that is already dead.
    if any(k.get("hash") == key_hash for k in or_list()):
        sys.exit(f"credential: {key_hash} is STILL LISTED after delete — it may still spend")
    return "already_gone" if status == 404 else "ok"


# ── none ─────────────────────────────────────────────────────────────────────
# "This box needs no inference credential." Every operation succeeds and does
# nothing, so the phases need no conditionals: mounting a static site is the
# same code path as mounting a factory, minus a key that never existed.
#
# NAMED `none`, NOT `null`, and that is not cosmetic: YAML reads an unquoted
# `null` as the null VALUE, so `provider: null` reached the phases as an empty
# string and fell through to the openrouter default. A live mount of a static
# site minted a $50 key before anyone noticed. `none` has no YAML meaning.

def none_mint(name: str, limit: float, keyfile: str) -> str:
    open(keyfile, "w").close()
    os.chmod(keyfile, 0o600)
    return ""


# ── dispatch ─────────────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, args, prov = argv[0], argv[1:], _provider()
    if prov not in ("openrouter", "none"):
        sys.exit(f"credential: unknown provider {prov!r} (openrouter, none)")

    if cmd == "mint":
        if len(args) != 3:
            print("usage: credential.py mint <name> <limit> <keyfile>", file=sys.stderr)
            return 2
        name, limit, keyfile = args[0], float(args[1]), args[2]
        # RULE 2, first half: never mint without the prefix. reap can only tell
        # managed keys from personal ones by this string.
        if not name.startswith(MANAGED_PREFIX):
            sys.exit(f"credential: refusing to mint {name!r} without the {MANAGED_PREFIX!r} prefix")
        print(none_mint(name, limit, keyfile) if prov == "none" else or_mint(name, limit, keyfile))
        return 0

    if cmd == "spend":
        if len(args) != 1:
            print("usage: credential.py spend <hash>", file=sys.stderr)
            return 2
        print("" if prov == "none" or not args[0] else or_spend(args[0]))
        return 0

    if cmd == "revoke":
        if len(args) != 1:
            print("usage: credential.py revoke <hash>", file=sys.stderr)
            return 2
        print("already_gone" if prov == "none" or not args[0] else or_revoke(args[0]))
        return 0

    if cmd == "list":
        if prov == "none":
            return 0
        for k in or_list():
            name = k.get("name") or ""
            print("\t".join([name, k.get("hash") or "", str(k.get("usage", 0))]))
        return 0

    if cmd == "list-json":
        # The shape reap's three-way join already parses: {"data": [...]}.
        # A separate command from `list` because that one is TSV for shell.
        print(json.dumps({"data": [] if prov == "none" else or_list()}))
        return 0

    if cmd == "revoke-managed":
        # RULE 2, second half: the prefix is re-asserted HERE, at the point of
        # deletion, not only where the candidate was chosen. A selection-time
        # check that is not repeated at destruction is one refactor away from
        # deleting a key nobody can restore.
        if len(args) != 2:
            print("usage: credential.py revoke-managed <name> <hash>", file=sys.stderr)
            return 2
        name, key_hash = args
        if not name.startswith(MANAGED_PREFIX):
            sys.exit(f"credential: REFUSING to revoke {name!r} — no {MANAGED_PREFIX!r} prefix. "
                     "Personal keys are unrecoverable.")
        print("already_gone" if prov == "none" else or_revoke(key_hash))
        return 0

    print(f"credential: unknown command {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as e:
        print(f"credential: {e}", file=sys.stderr)
        sys.exit(1)
