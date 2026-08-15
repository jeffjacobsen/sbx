#!/usr/bin/env -S uv run --quiet
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Read sandbox.yaml — the target repo's answer to "how do I run in a box?".

The six phases describe HOW to mount a repo; sandbox.yaml describes WHICH repo.
This is the only thing that reads it, so the phases stay shell and the parsing
stays in one place.

Usage:
    manifest.py get <dotted.path> [<dotted.path> ...]
    manifest.py check
    manifest.py services
    manifest.py secrets
    manifest.py toolchain
    manifest.py health
    manifest.py artifacts
    manifest.py ports-json
    manifest.py show
    manifest.py path

`get` prints one BARE value per line, in the order asked, so shell can capture
several in one call:

    { read -r REPO; read -r SCRIPT; } <<< "$(manifest.py get repo provision.script)"

A path that is absent prints an empty line and exits 0 — the same contract as
run_record.py, and the reason every caller tests for emptiness rather than
trusting an exit code. Absence is normal (optional fields); it is `check` that
makes a MISSING REQUIRED field loud, once, before a VM exists.

Unlike run_record.py this is not stdlib-only, because YAML is not in the
stdlib and the roster next door is already YAML. The rule it must not break:
nothing on the teardown path may need it. Teardown, harvest and reap work from
the run record alone, so a broken manifest can never strand a live key.

`artifacts` is the one thing teardown asks for, and it asks OPTIONALLY: teardown
falls back to ARTIFACTS_DEFAULT if this script is missing, unparseable, or slow.
Losing a log is recoverable; leaving a key spending is not. Keep it that way.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

import yaml

# The repo being mounted is the CWD, not this file's neighbourhood. The
# orchestrator is installed once per machine and run from inside a target
# checkout, so its own location says nothing about which repo it is mounting.
REPO_ROOT = Path.cwd()

# Where the clone lands inside the VM. The orchestrator's choice, not the
# project's, which is why it is here and not a manifest field. Emitted
# UNEXPANDED so the remote shell resolves $HOME -- the host has a different one.
APP_ROOT = "$HOME/app"

# The proxy auto-forwards this range; a port outside it is unreachable from a
# browser no matter what the service does. Measured, not guessed.
PORT_MIN, PORT_MAX = 3000, 9999

# The run id embeds this and becomes a DNS label capped at 63 characters, with
# -<task>-<YYYYMMDD>-<6 hex> still to come. 32 leaves room for a real task name.
NAME_MAX = 32
NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")

SERVICE_FIELDS = {"dir", "cmd", "port", "public", "requires", "env"}

# What the pushed base provisioner knows how to install, from a CDN, in about a
# second each. Kept small on purpose: this is the set whose install path has
# actually been measured here, and the answer to "please add cargo" is a project
# hook, not a fourth installer -- never apt, at ~35s per package from dal.
TOOLCHAIN = ("bun", "just", "uv")

# A health entry is a `cmd` with optional output assertions, or a `script` whose
# exit code is the verdict. expect_stdout/reject_stdout are case-insensitive
# plain substrings (`grep -qiF`), which is what assertion B used against pi's
# "No models available" -- a case-sensitive match would miss the capitalisation
# it exists to catch. Exactly one escape hatch per section, deliberately:
# the moment a manifest grows conditionals it is a DSL, and the answer to
# anything expressive is a repo-local script, not a new key.
HEALTH_FIELDS = {"name", "cmd", "script", "expect_stdout", "reject_stdout"}

EMPTY = "-"  # TSV placeholder: `read` drops trailing empty fields, a dash survives

# What TEARDOWN pulls off a box that declares no `artifacts:`. EXECUTE writes
# run.log itself, so this is the one path true for every repo — and the floor a
# broken manifest falls back to rather than harvesting nothing.
ARTIFACTS_DEFAULT = ("run.log",)


def manifest_path() -> Path:
    """$SBX_MANIFEST wins, so one checkout can mount a different repo's config.

    The override is a directory holding a sandbox.yaml, or the file itself —
    a directory per target keeps a fleet operator's manifests uniformly named,
    and pointing at one repo's checkout still reads that repo's own manifest.
    """
    override = os.environ.get("SBX_MANIFEST")
    if not override:
        return REPO_ROOT / "sandbox.yaml"
    target = Path(override).expanduser()
    return target / "sandbox.yaml" if target.is_dir() else target


def describes_this_checkout() -> bool:
    """Does the manifest sit in the repo it describes?

    Every `script:` path in a manifest is relative to the CLONE. When the
    manifest is a repo's own `sandbox.yaml`, the checkout it sits in IS that
    repo, so the path can be verified before a VM exists — worth doing, since a
    renamed hook is otherwise a failure you pay a VM for. A manifest kept
    somewhere else (examples/, or a fleet operator's directory of targets)
    describes a repo that is not on this disk at all, and checking here would
    reject paths that are perfectly valid in the target.

    The test is the manifest's own name and neighbourhood, not the cwd: a file
    called sandbox.yaml living beside a .git is a repo's own manifest.
    Everything else is a description of somewhere else. The base provisioner and
    the gate re-check inside the clone either way, so nothing goes unverified —
    it just gets verified on the box instead of before it.
    """
    target = manifest_path()
    return target.name == "sandbox.yaml" and (target.parent / ".git").exists()


def load() -> dict:
    target = manifest_path()
    try:
        text = target.read_text()
    except FileNotFoundError:
        raise SystemExit(f"manifest: no sandbox.yaml at {target}")
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as e:
        raise SystemExit(f"manifest: {target} is not valid YAML: {e}")
    if not isinstance(data, dict):
        raise SystemExit(f"manifest: {target} must be a mapping at the top level")
    return data


def dig(data: dict, path: str):
    """Walk a dotted path. Anything missing is None, never an exception."""
    cur = data
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def expand_app(value: str) -> str:
    """{app} -> $HOME/app, left for the REMOTE shell to resolve."""
    return value.replace("{app}", APP_ROOT)


def services(data: dict) -> list[tuple[str, dict]]:
    """Declaration order preserved: it is the order OBSERVE starts them in."""
    svcs = data.get("services") or {}
    return list(svcs.items()) if isinstance(svcs, dict) else []


# ── validation ───────────────────────────────────────────────────────────────
# Every rule here is a failure someone would otherwise meet on a live VM, after
# paying for it. Ordered the way a reader would ask the questions.

def problems(data: dict) -> list[str]:
    out: list[str] = []

    if data.get("version") != 1:
        out.append(f"version must be 1, got {data.get('version')!r}")

    name = data.get("name")
    if not isinstance(name, str) or not name:
        out.append("name is required (it becomes part of a hostname)")
    else:
        if not NAME_RE.match(name):
            out.append(f"name {name!r} is not a DNS label: lowercase letters, digits, hyphens")
        if len(name) > NAME_MAX:
            out.append(f"name {name!r} is {len(name)} chars; keep it under {NAME_MAX}"
                       " so the run id fits a 63-char hostname")

    repo = data.get("repo")
    if not isinstance(repo, str) or not repo:
        out.append("repo is required — FILL clones it")

    # OPTIONAL, both of them. The base provisioner is pushed by the host, so a
    # repo that declares neither still mounts -- it just gets the image's own
    # toolchain and no project step. That is the point of pushing rather than
    # requiring a provisioner in the clone.
    tools = dig(data, "provision.toolchain")
    if tools is not None:
        if not isinstance(tools, list) or any(not isinstance(t, str) for t in tools):
            out.append("provision.toolchain must be a list of tool names")
        else:
            unknown = [t for t in tools if t not in TOOLCHAIN]
            if unknown:
                out.append(
                    f"provision.toolchain has unsupported entr{'y' if len(unknown) == 1 else 'ies'}: "
                    f"{', '.join(unknown)}. The base provisioner installs {', '.join(TOOLCHAIN)}; "
                    "anything else belongs in provision.script"
                )

    local = describes_this_checkout()

    script = dig(data, "provision.script")
    if script is not None:
        if not isinstance(script, str):
            out.append("provision.script must be a path string")
        elif local and not (manifest_path().parent / script).is_file():
            out.append(f"provision.script {script!r} does not exist in this repo")

    # OPTIONAL. Assertion A — clean tree, HEAD matches the recorded sha — is
    # builtin in SETUP and always runs, because it is a claim about the mount
    # itself. Everything here is a claim about the PAYLOAD, so a repo that makes
    # no such claim declares nothing and still gates on A.
    health = data.get("health") or []
    if not isinstance(health, list):
        out.append("health must be a list")
    else:
        for i, h in enumerate(health):
            where = f"health[{i}]"
            if not isinstance(h, dict):
                out.append(f"{where} must be a mapping with name and cmd or script")
                continue
            unknown = set(h) - HEALTH_FIELDS
            if unknown:
                out.append(f"{where} has unknown field(s): {', '.join(sorted(unknown))}")
            if not isinstance(h.get("name"), str) or not h.get("name"):
                out.append(f"{where}.name is required — it is what the gate prints")
            has_cmd, has_script = "cmd" in h, "script" in h
            if has_cmd == has_script:
                out.append(f"{where} needs exactly one of cmd or script")
            if has_script:
                script = h.get("script")
                if not isinstance(script, str) or not script:
                    out.append(f"{where}.script must be a path string")
                elif local and not (manifest_path().parent / script).is_file():
                    out.append(f"{where}.script {script!r} does not exist in this repo")
                for k in ("expect_stdout", "reject_stdout"):
                    if k in h:
                        out.append(f"{where}.{k} only applies to cmd; a script's exit code is its verdict")
            if has_cmd and (not isinstance(h.get("cmd"), str) or not h.get("cmd")):
                out.append(f"{where}.cmd must be a non-empty string")
            for k in ("expect_stdout", "reject_stdout"):
                v = h.get(k)
                if k in h and (not isinstance(v, str) or not v):
                    out.append(f"{where}.{k} must be a non-empty string")
            # The TSV the gate loop reads is tab-delimited and line-oriented, so
            # a tab or newline in any field would silently become another column
            # or another assertion. Reject it here instead of on a live VM.
            for k in ("name", "cmd", "script", "expect_stdout", "reject_stdout"):
                v = h.get(k)
                if isinstance(v, str) and ("\t" in v or "\n" in v):
                    out.append(f"{where}.{k} must not contain a tab or a newline")

    secrets = data.get("secrets") or []
    if not isinstance(secrets, list):
        out.append("secrets must be a list")
    else:
        for i, s in enumerate(secrets):
            where = f"secrets[{i}]"
            if not isinstance(s, dict):
                out.append(f"{where} must be a mapping with dest and vars")
                continue
            dest = s.get("dest")
            if not isinstance(dest, str) or not dest:
                out.append(f"{where}.dest is required")
            elif dest.startswith("/") or ".." in Path(dest).parts:
                out.append(f"{where}.dest {dest!r} must be relative to the clone and not escape it")
            variables = s.get("vars")
            if not isinstance(variables, dict) or not variables:
                out.append(f"{where}.vars must be a non-empty mapping")
            else:
                for k, v in variables.items():
                    if not isinstance(v, str):
                        out.append(f"{where}.vars.{k} must be a string")
                    elif "\n" in v:
                        out.append(f"{where}.vars.{k} must be a single line")

    cred = data.get("credential")
    if isinstance(cred, dict) and "provider" in cred and cred["provider"] is None:
        # The trap this rule exists for: YAML reads an unquoted `null` as the
        # null value, so the field arrives empty and silently falls through to
        # the default. That mounted a static site with a live $50 key once.
        out.append("credential.provider is empty — write `none`, not `null`, "
                   "which YAML reads as a null value rather than the word")
    provider = dig(data, "credential.provider")
    if provider is not None and provider not in ("openrouter", "none"):
        out.append(f"credential.provider {provider!r} is not one of: openrouter, none")
    limit = dig(data, "credential.limit")
    if limit is not None and (isinstance(limit, bool) or not isinstance(limit, (int, float))):
        out.append("credential.limit must be a number (dollars)")

    svcs = services(data)
    if not svcs:
        out.append("services must declare at least one service — OBSERVE has nothing to start")
    seen_ports: dict[int, str] = {}
    public = []
    for svc, cfg in svcs:
        where = f"services.{svc}"
        if not isinstance(cfg, dict):
            out.append(f"{where} must be a mapping")
            continue
        unknown = set(cfg) - SERVICE_FIELDS
        if unknown:
            out.append(f"{where} has unknown field(s): {', '.join(sorted(unknown))}")
        if not isinstance(cfg.get("dir"), str) or not cfg.get("dir"):
            out.append(f"{where}.dir is required (relative to the clone root)")
        if not isinstance(cfg.get("cmd"), str) or not cfg.get("cmd"):
            out.append(f"{where}.cmd is required")
        port = cfg.get("port")
        if not isinstance(port, int) or isinstance(port, bool):
            out.append(f"{where}.port is required and must be an integer")
        elif not (PORT_MIN <= port <= PORT_MAX):
            out.append(f"{where}.port {port} is outside {PORT_MIN}-{PORT_MAX}, "
                       "the range the exe.dev proxy forwards")
        elif port in seen_ports:
            out.append(f"{where}.port {port} is already used by services.{seen_ports[port]}")
        else:
            seen_ports[port] = svc
        if cfg.get("public") is True:
            public.append(svc)
        requires = cfg.get("requires") or []
        if not isinstance(requires, list) or any(not isinstance(r, str) for r in requires):
            out.append(f"{where}.requires must be a list of repo-relative paths")
        else:
            # OBSERVE splits the comma-joined list on whitespace, so a path with
            # a space in it would silently become two prerequisites that both
            # fail. Reject it here rather than on a live VM.
            for r in requires:
                if r.split() != [r]:
                    out.append(f"{where}.requires entry {r!r} must not contain whitespace")
        env = cfg.get("env") or {}
        if not isinstance(env, dict) or any(not isinstance(v, str) for v in env.values()):
            out.append(f"{where}.env must be a mapping of string values")

    # Measured: "public" is a property of the ONE port the proxy targets, not of
    # the VM. Two public services is not stricter, it is a contradiction, and the
    # loser fails silently as a 307 nobody expected.
    if len(public) > 1:
        out.append(f"exactly one service may be public; got {len(public)}: {', '.join(public)}")
    elif svcs and not public:
        out.append("no service is public — nothing would be reachable anonymously")

    # OPTIONAL. A repo with no work to kick off — a static site, a service you
    # only want served — should not have to invent an `echo {prompt}` to satisfy
    # a field it will never use. Mounting mdn/beginner-html-site is what made
    # that obvious. EXECUTE is the phase that needs it, and EXECUTE says so.
    kick = dig(data, "kickoff.default")
    if kick is not None:
        if not isinstance(kick, str) or not kick:
            out.append("kickoff.default must be a non-empty string")
        elif "{prompt}" not in kick:
            out.append("kickoff.default must contain {prompt}")

    # OPTIONAL, and what TEARDOWN pulls off the box before destroying it. Absent
    # means ARTIFACTS_DEFAULT, which is `run.log` — the one artifact sbx itself
    # writes. This list used to be hardcoded as `specs app_docs
    # adws/adw_data/sssf.db run.log`: three SSSF paths baked into a tool that is
    # supposed to be repo-agnostic, so every other repo harvested nothing but the
    # log and never said so.
    arts = data.get("artifacts")
    if arts is not None:
        if not isinstance(arts, list) or any(not isinstance(a, str) for a in arts):
            out.append("artifacts must be a list of repo-relative paths")
        else:
            for a in arts:
                if not a:
                    out.append("artifacts entries must be non-empty")
                # TEARDOWN interpolates this list into `ls -d $P` inside a remote
                # shell, so whitespace would split one path into two that both
                # miss. Same reasoning as services.requires.
                elif a.split() != [a]:
                    out.append(f"artifacts entry {a!r} must not contain whitespace")
                elif a.startswith("/") or ".." in Path(a).parts:
                    out.append(f"artifacts entry {a!r} must be relative to the clone "
                               "and not escape it")

    return out


# ── commands ─────────────────────────────────────────────────────────────────

def cmd_get(data: dict, paths: list[str]) -> int:
    for p in paths:
        value = dig(data, p)
        if value is None:
            print("")
        elif isinstance(value, bool):
            print("true" if value else "false")
        elif isinstance(value, (dict, list)):
            print(json.dumps(value))
        else:
            print(expand_app(str(value)))
    return 0


def cmd_services(data: dict) -> int:
    """TSV: name dir cmd port public requires env — one line per service.

    OBSERVE reads this in a `while IFS=$'\\t' read` loop, so the field count is
    fixed and every optional field falls back to a dash rather than an empty
    string: `read` silently drops trailing empties and the loop would misalign.
    """
    for svc, cfg in services(data):
        requires = ",".join(cfg.get("requires") or []) or EMPTY
        env = " ".join(f"{k}={expand_app(v)}" for k, v in (cfg.get("env") or {}).items()) or EMPTY
        print("\t".join([
            svc,
            cfg.get("dir", ""),
            cfg.get("cmd", ""),
            str(cfg.get("port", "")),
            "yes" if cfg.get("public") is True else "no",
            requires,
            env,
        ]))
    return 0


def cmd_secrets(data: dict) -> int:
    """TSV: dest var template — one line per variable, grouped by dest in order.

    The TEMPLATE is emitted, never a value: {runtime_key} is substituted by FILL
    in bash, so the key never passes through this process, its argv, or a pipe
    anything else can see.
    """
    for s in data.get("secrets") or []:
        for var, template in (s.get("vars") or {}).items():
            print("\t".join([s.get("dest", ""), var, template]))
    return 0


def cmd_toolchain(data: dict) -> int:
    """Comma-separated, on ONE line — the shape the base provisioner takes.

    One argument rather than a list because it crosses `ssh vm 'bash script a b c'`,
    where a multi-word argument would have to survive two levels of shell quoting.
    Tool names are single words from a closed set, so a comma join is lossless.
    """
    tools = dig(data, "provision.toolchain") or []
    print(",".join(t for t in tools if isinstance(t, str)))
    return 0


def cmd_health(data: dict) -> int:
    """TSV: name kind value expect reject — one line per assertion, in order.

    Same fixed-field discipline as `services`: SETUP reads this in a
    `while IFS=$'\\t' read` loop and `read` drops trailing empty fields, so an
    optional field falls back to a dash rather than an empty string. Order is
    declaration order — assertions run in the order the repo wrote them.
    """
    for h in data.get("health") or []:
        kind = "script" if "script" in h else "cmd"
        print("\t".join([
            h.get("name", ""),
            kind,
            str(h.get(kind, "")),
            h.get("expect_stdout") or EMPTY,
            h.get("reject_stdout") or EMPTY,
        ]))
    return 0


def cmd_artifacts(data: dict) -> int:
    """Space-separated, on ONE line — the shape `ls -d` takes in TEARDOWN.

    Entries are validated to contain no whitespace, so a space join is lossless
    and the remote shell's own word splitting reassembles the list.

    Absent OR empty yields ARTIFACTS_DEFAULT. There is deliberately no way to
    harvest NOTHING: teardown cannot tell an empty answer from a failed one — it
    treats both as "fall back to the default" so a broken manifest still gets to
    the revoke — so an `artifacts: []` that meant "nothing" would be a promise
    only one of the two callers could keep. run.log is a few KB and sbx wrote it.
    """
    arts = data.get("artifacts") or ARTIFACTS_DEFAULT
    print(" ".join(a for a in arts if isinstance(a, str) and a))
    return 0


def cmd_ports_json(data: dict) -> int:
    """The `ports` field of the run record, built from the same source of truth.

    Compact separators: this crosses a shell as one word, and a space in it
    would split into two arguments the moment a caller forgot the quotes.
    """
    print(json.dumps({svc: cfg.get("port") for svc, cfg in services(data)},
                     separators=(",", ":")))
    return 0


def cmd_check(data: dict) -> int:
    found = problems(data)
    if found:
        print(f"manifest: {manifest_path()} has {len(found)} problem(s)", file=sys.stderr)
        for p in found:
            print(f"  - {p}", file=sys.stderr)
        return 1
    svcs = services(data)
    public = next((s for s, c in svcs if c.get("public") is True), "?")
    print(f"manifest ok: {data.get('name')} — {len(svcs)} service(s), public: {public}")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]

    if cmd == "path":
        print(manifest_path())
        return 0

    data = load()

    if cmd == "get":
        if not args:
            print("usage: manifest.py get <dotted.path> [...]", file=sys.stderr)
            return 2
        return cmd_get(data, args)
    if cmd == "check":
        return cmd_check(data)
    if cmd == "services":
        return cmd_services(data)
    if cmd == "secrets":
        return cmd_secrets(data)
    if cmd == "toolchain":
        return cmd_toolchain(data)
    if cmd == "health":
        return cmd_health(data)
    if cmd == "artifacts":
        return cmd_artifacts(data)
    if cmd == "ports-json":
        return cmd_ports_json(data)
    if cmd == "show":
        print(json.dumps(data, indent=2))
        return 0

    print(f"manifest: unknown command {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
