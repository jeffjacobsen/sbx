---
name: sbx-orchestrator
description: Drive the six-phase sandbox mount system from the host — mount throwaway exe.dev VMs, run the Super Simple Software Factory inside them, watch from outside, harvest the commits, tear down. Use when the user says mount a sandbox, run the factory in a sandbox, spin up N sandboxes, best-of-N, check on a run, harvest a run's commits, or tear down. Keywords - sandbox, mount, exe.dev VM, run id, fan out, best-of-N, harvest, bundle, teardown, reap.
argument-hint: "[mount|execute|agent|observe|harvest|teardown] [run-id or prompt]"
---

# SSSF Sandbox Orchestrator

Drives **sbx**, the standalone fleet manager: the phases under `just/` that
take a blank exe.dev VM to a health-checked, running factory in ~10s, run work inside it, expose it
to a browser, and — only when a human says so — tear it down.

## The one governing principle: THIN SKILL, FAT RECIPES

**Every action you take should be a `just` command a human could type.** The recipes hold the
knowledge; this skill holds the judgment about which one to run and how to read the result.

- Dropping to `ssh <vm>.exe.xyz '...'` or `curl` to **inspect** is fine and expected — that is what
  `sbx run cmd <id> '<cmd>'` exists for, and reading a log or a table needs no ceremony.
- Re-implementing what a recipe already does is not. Never hand-roll a key mint, a revoke, an
  `ssh exe.dev new`, a `share port`, or a detached `nohup` launch. Those encode measured facts
  (mint order, the revocation gate, the proxy retarget, the three detachment pieces) and a
  hand-rolled version drops one of them silently.
- If a recipe is wrong, **fix the recipe** and say so. Do not route around it.

## Dependencies

This skill **references** `/sandbox-exe-dev` rather than duplicating it: that skill owns the exe.dev
CLI surface, which moves without asking us, and a copy pasted here would be a second source of truth
that goes wrong quietly — a stale model id, a renamed flag. Read it; do not quote it.

The **payload** is the other repo's business. What runs inside the box comes from that repo's
`sandbox.yaml` and whatever skill documents its factory (for sandbox-factory, `/sssf` — the ADW
roster, the handoff contract, the trace-db schema). sbx neither ships nor requires it: a manifest
is the whole contract.

**Preflight is one command.** Run it before the first phase; any failure means report and stop,
never work around a missing prerequisite by hand.

```bash
sbx manage doctor
```

It checks everything in one pass: `ssh exe.dev` reachable, a trusted host key to verify VMs with,
`OPENROUTER_PROVISIONING_KEY` set (never printed) **and confirmed to be a management key rather than
an inference key**, the run-record helper runs and its store is writable, `sandbox.yaml` validates,
the base provisioner is present, and the credential provider resolves. A manifest that declares
`credential.provider: none` skips the two OpenRouter checks.
Green ends with `sbx doctor: OK`.

Two things it does **not** cover, so check them yourself:

| Check | Command | If it fails |
|---|---|---|
| The payload | `sbx run cmd <id> '<the manifest's own smoke test>'` | doctor validates the manifest, not what the manifest points at. A repo whose factory is broken still mounts and gates green. |
| VM skill | `test -f .claude/skills/sandbox-exe-dev/SKILL.md` | read it for exe.dev CLI detail instead of guessing flags. |

> **Listing a namespace is `sbx --list lifecycle`, not `sbx lifecycle --list`.** The flag goes
> **before** the module name; after it, `--list` is read as a recipe name and errors with
> ``justfile does not contain recipe `lifecycle --list` ``. A bare `sbx lifecycle` also works — it
> runs the namespace's `default`, which lists.

## Two layers, one credential boundary

| | Out-sandbox (you) | In-sandbox (the VM) |
|---|---|---|
| Lives in | the sbx install: `just/`, `lib/` | the target repo's own checkout, at `app/` on the VM |
| Entry point | `sbx mount`, `sbx lifecycle execute`, `sbx lifecycle teardown` | whatever `kickoff.default` names in its `sandbox.yaml` |
| Credential | exe.dev account + OpenRouter **provisioning** key | one disposable **runtime** key, $50 cap |

### The run store is per MACHINE, not per repo

Run records, runtime keys, bundles and artifacts live in
`${SBX_STATE_DIR:-${XDG_STATE_HOME:-~/.local/state}/sbx}/runs` — outside every checkout. `reap` and
`manage list` reason about a whole exe.dev + OpenRouter account, so a per-repo store would give you
one partial view per repo and a key could hide in the gap; and a runtime key inside a git working
tree is one `git add -A` away from being committed.

**Never build a path under it by hand** — `run_record.py dir [run-id]` and `path <run-id>` are what
the recipes ask, and everything for a run (`.key`, `.bundle`, `-artifacts`, `.agent-started`) sits
beside its record. Records from before the move still work where they are and are still listed;
`run_record.py migrate --yes` relocates them.

### `sandbox.yaml` — which repo, not how to mount one

The phases carry no project constants. The clone URL, the toolchain, the optional project hook, the
secret files, the services and their ports, and the kickoff command all come from `sandbox.yaml` at
the repo root, read by `lib/manifest.py`. **If a mount is doing the wrong thing for
this project, the fix is usually one line there — not in a recipe.**

**The provisioner is PUSHED, not cloned.** SETUP `scp`s `lib/base_provision.sh` — the
orchestrator's own file — and it installs `provision.toolchain` (`bun`, `just`, `uv`; never apt) and
then runs `provision.script` if the repo declares one. Both are optional, so a repo that has never
heard of this system mounts with zero files added. The base owns `/tmp/PROVISION_READY` and writes it
after the hook returns; a hook must never touch it. Anything a project needs beyond those three tools
belongs in its hook, not in a fourth installer.

Two rules the manifest enforces, both from measurements: ports
must be in 3000-9999 (what the proxy forwards) and **exactly one** service may be `public: true`
(public is a property of the one port the proxy targets, so a second is a contradiction, not a
stricter setting). `sbx manage doctor` validates it before a VM exists.

```bash
lib/manifest.py check      # what doctor runs
lib/manifest.py show       # the whole thing as JSON
```

### Mounting a repo that is not this one

`$SBX_MANIFEST` points the phases at a different manifest — a directory holding a
`sandbox.yaml`, or a path to the file itself — so one checkout can mount any repo:

```bash
SBX_MANIFEST=examples/mdn-beginner-html-site sbx mount foreign-static
```

`examples/` holds a worked one, a directory per target. `provision`, `health` and `kickoff` are **all optional**, so a target
that has never heard of this system needs no files of its own — it gets the image's toolchain, gates
on git integrity, and gets its service served. Verified end to end against `mdn/beginner-html-site`.

Two things follow from the manifest describing a *different* repo. `script:` paths are relative to
the CLONE, so they are only checked against the host when the manifest is this repo's own
`sandbox.yaml`; for a foreign target the base provisioner and the gate check them on the box. And a
repo with no work to kick off simply omits `kickoff` — `execute` is the one phase that needs it and
the one that complains, while `run cmd` and `run agent` work regardless.

The whole repo ships to the sandbox, this skill included. **What a sandbox cannot do is USE the
out-sandbox half** — `sbx mount` there fails on a missing exe.dev account, and `create` fails on
a missing `OPENROUTER_PROVISIONING_KEY`. Neither credential ever leaves the host, and that, not file
absence, is what stops a sandbox from mounting sandboxes. Keep the credentials on the host.

## The drive surface

Three groups under `sbx`, plus `mount` at the top because it is the entry point, not a phase:

```
sbx
├── mount              the chain: create → fill → setup → observe
├── lifecycle          the six phases, for when you need one on its own
├── manage             preflight, readback, fleet ops — nothing here is a phase
└── run                put work in / look inside: `run cmd`, `run agent`
```

`sbx`, `sbx lifecycle`, `sbx manage` and `sbx run` each list their own
contents when run bare.

| Command | What it does |
|---|---|
| `sbx mount RUN_ID [--limit N]` | create → fill → setup → observe. **Never teardown.** Prints the resolved run id and both URLs. |
| `sbx lifecycle create RUN_ID [--limit N]` | mint `sbx-<run-id>` (\$50 default) + boot the VM, in record → VM → key order |
| `sbx lifecycle fill RUN_ID [SHA]` | public `git clone` (2.61s, no auth), optional SHA pin, write `.env` with the runtime key |
| `sbx lifecycle setup RUN_ID` | scp the base provisioner, run it (toolchain + optional hook), then the gate: git integrity builtin + the manifest's `health:` entries |
| `sbx lifecycle execute RUN_ID "PROMPT"` | full SDLC detached inside the box; returns a pid, records it |
| `sbx run cmd RUN_ID '<cmd>'` | generic escape hatch, synchronous, runs in `app/`. Your inspection tool. |
| `sbx run agent RUN_ID "PROMPT"` | Claude Code inside the box, resumable session — hand off, then keep talking |
| `sbx lifecycle observe RUN_ID` | start both servers, expose 4501, print URLs. Idempotent. |
| `sbx manage list` | every run record: state, VM alive, spend |
| `sbx manage harvest RUN_ID` | pull the run's commits home as a git bundle, fetched into `refs/sandbox/<run-id>`. Non-destructive, idempotent, run it any time. |
| `sbx lifecycle teardown RUN_ID [--no-harvest]` | spend → artifacts → **harvest** → revoke → destroy → close. **The only destructive recipe.** |
| `sbx manage reap [--yes]` | delete orphaned `sbx-*` keys. Dry run by default. Run it at the start of a session. |

The run id is the handle for every phase. `create` appends `-<date>-<6 hex>` if you did not, and
prints what it settled on — use that string, not the one you typed.

**The gate is one builtin plus whatever the manifest declares.** Builtin and always run:
**git integrity** — `status --porcelain` clean and HEAD matching the recorded sha. That one is a
claim about the MOUNT, and it is what caught 5,641 zero-byte files from an unsynced golden clone.

Everything else lives in the target repo's `health:` block, because "pi is healthy and the roster
answers" is a claim about the PAYLOAD. Each entry is a `cmd` (fails on non-zero exit, on empty
output, or on a `reject_stdout` match — `pi --list-models` **exits 0 while printing "No models
available"**, which is exactly what `reject_stdout` is for) or a `script` whose exit code is the
verdict and which receives `CONFIG` as `$1`. Both output matches are **case-insensitive plain
substrings** — so `expect_stdout: LISTENING` also matches the word "listening" inside a failure
message. Choose sentinels that cannot appear in the failure case. This repo declares two: the pi registry, and one script
covering roster ping + non-zero cost + remaining credit — together because all three need the
runtime key already in the clone's `.env`, so the key never crosses the wire.

A repo that declares no `health:` block still gates on git integrity. A failure **reports, stops,
and leaves the VM alive**.

## Cookbooks (lazy-load the one the request calls for)

| Activity | When to read | File |
|---|---|---|
| Understand the recipes before running any | first time, or when a recipe surprises you | [cookbooks/just_command_model.md](cookbooks/just_command_model.md) |
| Stand up one sandbox end to end | "mount a sandbox", "run this in a sandbox" | [cookbooks/mount_one.md](cookbooks/mount_one.md) |
| Put work into a mounted box | "build X in there", "ask the agent", picking `run cmd` vs `lifecycle execute` vs `run agent` | [cookbooks/execute_work.md](cookbooks/execute_work.md) |
| Watch a run and report it back | "check on the run", "is it done", "show me the URLs" | [cookbooks/observe_and_report.md](cookbooks/observe_and_report.md) |
| Give the user access to a running box | "get me into the sandbox", a shell in there, talk to the in-box agent | [cookbooks/access_a_running_sandbox.md](cookbooks/access_a_running_sandbox.md) |
| A gate assertion failed | `setup` exited non-zero, or the box looks wrong | [cookbooks/debug_a_failed_gate.md](cookbooks/debug_a_failed_gate.md) |
| Spin up N and pick a winner | "best-of-N", "three variants", "diff the runs" | [cookbooks/fan_out_n.md](cookbooks/fan_out_n.md) |
| Shut a run down, clean up keys | the human decided to tear down; orphaned `sbx-` keys | [cookbooks/teardown_and_reap.md](cookbooks/teardown_and_reap.md) |

## References (deep specs, read on demand)

| Reference | Covers |
|---|---|
| [references/phases.md](references/phases.md) | what each of the six phases does, in order, and why the order is that order |
| [references/kickoff_paths.md](references/kickoff_paths.md) | the two ways work enters a box: direct (`lifecycle execute`, a command) vs agent-mediated (`run agent`, a delegation) |
| [references/run_record.md](references/run_record.md) | `~/.local/state/sbx/runs/<id>.json` — the closed schema, who writes each field, who reads it |
| [references/credentials.md](references/credentials.md) | minting and revoking, provisioning vs runtime key, the ZDR account setting. **The mounted repo owns its own roster and model registry** — for sandbox-factory that is `/sssf`'s `references/models.md` |
| [references/gotchas.md](references/gotchas.md) | every trap that cost a debugging cycle, with the symptom it produces |

## Hard rules

1. **Never decide teardown.** Report what the run produced, what it cost, and recommend — the human
   decides. `mount` stops at `observe` on purpose and nothing chains into `teardown`. A VM left
   running is a bill; a VM destroyed early is the evidence and the artifacts, gone. **`harvest` is
   the exception you may run freely** — it only reads the box and only writes `refs/sandbox/`, so
   run it as soon as a run commits rather than letting the commits wait on a teardown decision.
2. **Never run the payload's factory on the host.** The target repo's own entry point — for
   sandbox-factory that is `just adw sdlc "..."` — runs it on the engineer's laptop, the exact
   collision this system exists to remove. Work goes in through `sbx lifecycle execute` /
   `sbx run agent`, always. Rule of thumb: **if the command has no run id in it, it is running
   here.**
3. **A gate failure means STOP and diagnose, never destroy.** The VM is left alive deliberately.
   Read the failing assertion, `sbx run cmd <id> '...'` your way to the cause, fix it, re-run
   `sbx lifecycle setup`. Re-running setup is safe.
4. **Never touch a key.** The runtime key lives at `~/.local/state/sbx/runs/<id>.key` (0600) and inside the
   VM's `app/.env`. Never print it, never copy it, never pass it over ssh — `setup`'s gate spends it
   from inside the box for exactly that reason. The provisioning key never leaves the host.
5. **Never mint outside `create`.** The `sbx-` prefix is the entire safety model for `reap`; the
   engineer's personal keys carry no prefix and deleting one is unrecoverable.
6. **Report the run id every time.** It is the only handle the next phase, the next session, and
   `teardown` have.
