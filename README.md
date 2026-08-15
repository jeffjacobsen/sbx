# sbx

A fleet manager for disposable [exe.dev](https://exe.dev) VMs. Give it a repo and a
one-page manifest; it boots a VM, clones the repo, provisions it, health-gates it,
serves it on a public URL, and — only when you say so — destroys it and revokes
whatever credential it minted.

The primary way to drive it is from Claude Code. This repo ships an
[`sbx-orchestrator`](.claude/skills/sbx-orchestrator/SKILL.md) skill that
carries the whole lifecycle, so you work in plain language:

```
cd ~/code/sbx && claude
> mount a sandbox for the mdn example
> open the site
> put Claude to work in it: "add dark mode"
> how's it going?
> harvest it and tear it down
```

Every action the skill takes is an `sbx` command you could type yourself, and
[running it manually](#running-it-manually) is a supported alternative:

```bash
cd any-repo
sbx mount my-task          # boot, clone, provision, gate, serve. Never teardown.
sbx run agent my-task-20260811-a1b2c3 "add dark mode"   # Claude Code in the box
sbx manage list            # every run on this machine: state, VM alive, spend
sbx lifecycle teardown my-task-20260811-a1b2c3
```

It knows nothing about what is inside the repo. That is the design.

**[EXAMPLE.md](EXAMPLE.md) is the whole thing on one real task**: a blank VM, a
prompt file, and 6.5 minutes later a SQLite FTS5 search feature — planned, built,
tested and committed — for $1.96. Every command and every number in it is
verbatim from that run, including the two defects the health gate caught before
they could waste a phase.

## Install

```bash
git clone https://github.com/jeffjacobsen/sbx ~/code/sbx
cd ~/code/sbx
sbx manage doctor          # run this before the first mount
```

Needs `just`, `python3`, and an exe.dev account. Credentials go in
`~/.config/sbx/env` (a target repo's `.env` also works, and anything already in
your environment wins over both).

## Quickstart

The target repo does not need to have heard of this tool. `$SBX_MANIFEST`
points the phases at any manifest — a directory holding a `sandbox.yaml`, or a
path to the file itself — so one sbx checkout can mount any repo.
[`examples/mdn-beginner-html-site/`](examples/mdn-beginner-html-site/) is a
worked one, verified end to end against `mdn/beginner-html-site`.

Open Claude Code in the sbx checkout and ask for what you want; the
`sbx-orchestrator` skill picks the right commands and reads back the results:

```
cd ~/code/sbx && claude
> mount a sandbox for the mdn example
```

It runs the preflight, mounts with the example manifest, and reports the run id
and public URL. From there, keep talking: *"look inside"*, *"put Claude to work
on adding a footer"*, *"harvest its commits"*, *"tear it down"*.

Prefer to type the commands yourself? The same ramp-up by hand:

```bash
cd ~/code/sbx
sbx manage doctor
SBX_MANIFEST=examples/mdn-beginner-html-site sbx mount quickstart
```

`mount` boots the VM, clones the repo, provisions and health-gates it, serves
it, and stops — never teardown. It prints the resolved run id (`create`
appends `-<date>-<6 hex>` to the name you gave; use the printed string from
here on) and the public URL. From there:

```bash
sbx run cmd <run-id> 'ls -la'          # look inside — synchronous, runs in app/
sbx run agent <run-id> "add a footer"  # put Claude Code to work in the box
sbx manage harvest <run-id>            # pull its commits home as a git bundle
sbx lifecycle teardown <run-id>        # destroy the VM, revoke its key
```

**Installed once per machine, not once per repo.** `reap` and `manage list`
reason about a whole exe.dev account: a copy per repo gives you one partial view
per repo, and a key can hide in the gap. Run records and minted keys live in
`$SBX_STATE_DIR` (default `~/.local/state/sbx/runs`), never inside a checkout —
a live key one `git add -A` away from a commit is not a risk worth carrying.

```bash
ln -s ~/code/sbx/bin/sbx /usr/local/bin/sbx
```

## The manifest

A repo describes how to run in a box with one `sandbox.yaml` at its root:

```yaml
version: 1
name: my-app
repo: https://github.com/you/my-app.git

provision:
  toolchain: [bun]                       # installed from CDNs, never apt
  script: scripts/sandbox_setup.sh       # optional project hook

credential:
  provider: openrouter                   # or `none` — see below
  limit: 50

health:                                  # optional; git integrity is builtin
  - name: deps resolve
    cmd: bun pm ls
    reject_stdout: "missing"

services:
  app: { dir: ., cmd: bun run server.ts, port: 3000, public: true }

kickoff:
  default: "npm run agent -- {prompt}"   # optional

artifacts: [dist, run.log]               # optional; what teardown pulls home
```

**Every block except `name`, `repo` and `services` is optional.** A repo that has
never heard of this tool needs no files of its own — see
[`examples/`](examples/) for a static site mounted with nothing but a manifest
kept outside it.

Two rules the manifest enforces, both measured: ports must sit in 3000-9999 (what
the exe.dev proxy forwards), and exactly one service may be `public: true` —
public is a property of the one port the proxy targets, so a second is a
contradiction rather than a stricter setting.

## Credentials

A sandbox gets a **disposable** credential: capped, tied to one VM's lifetime,
revocable by hash, and reapable when its VM dies. That shape is the transferable
idea, not any one vendor, so it sits behind four operations —
`mint` / `spend` / `revoke` / `list` — in `lib/credential.py`.

| provider | what it does |
|---|---|
| `openrouter` | mints a spend-capped key, injected into the clone by `fill` |
| `none` | mints nothing. For a box that never calls a model. |

Write `none`, never `null`: YAML reads an unquoted `null` as a null *value*, so
the field arrives empty and falls through to the default. That mounted a static
site with a live $50 key once, which is why `manage doctor` now rejects it.

Two rules live above the provider interface because they are correctness rather
than vendor detail. **Revocation is gated against the LIST**, never the
single-key GET — a dead key still answers 200 from the latter. And **the managed
`sbx-` prefix is re-asserted at the point of deletion**, not only at selection: a
check that happens when a candidate is chosen and not again when it is destroyed
is one refactor away from deleting a personal key.

## The phases

| | |
|---|---|
| `create` | record → VM → credential, in that order. A crash after the record always leaves teardown a handle; a failed mint orphans a cheap visible VM rather than a key that spends invisibly. |
| `fill` | public `git clone`, optional SHA pin, writes declared secrets into the clone |
| `setup` | pushes the base provisioner, runs it, then the gate: builtin git integrity plus the manifest's `health:` entries |
| `observe` | starts the services, points the proxy at the public one, prints URLs |
| `execute` | detaches the manifest's `kickoff` command inside the box |
| `teardown` | spend → artifacts → harvest → revoke → destroy → close. **The only destructive recipe.** Artifacts are the manifest's `artifacts:` list, defaulting to `run.log`; a manifest that fails to parse falls back to that default rather than blocking the revoke. |

`mount` chains create → fill → setup → observe and stops. Teardown is always a
separate, explicit decision: a VM left running is a bill, and a VM destroyed
early is the evidence and the artifacts, gone.

## Driving it from Claude — the primary interface

`.claude/skills/sbx-orchestrator/` carries the operating knowledge: which recipe
to run for a given intent, and how to read what comes back. Open Claude Code in
this checkout and the skill loads on demand — say what you want (*"mount a
sandbox"*, *"spin up three and fan out this prompt"*, *"check on the run"*,
*"harvest and tear down"*) and it drives the phases, watches from outside the
box, and reports run ids, URLs, and spend back to you.

Thin skill, fat recipes — every action it takes is an `sbx` command you could
type yourself, so nothing below is agent-only.
`.claude/skills/sandbox-exe-dev/` is the layer underneath, wrapping the exe.dev
control plane directly for the cases the phases do not cover.

## Running it manually

The alternative: the same surface the skill drives, typed by hand. Four groups
under `sbx`: `mount` at the top because it is the entry point, then
`run` (put work in, look inside), `manage` (preflight, readback, fleet ops) and
`lifecycle` (the phases, for when you need one on its own). Each lists its own
contents when run bare; to list a namespace with the flag, it goes *before* the
module name — `sbx --list lifecycle`, not `sbx lifecycle --list`.

| Command | What it does |
|---|---|
| `sbx mount RUN_ID [--limit N]` | the whole ramp-up: boot, clone, provision, gate, serve. **Never teardown.** Prints the resolved run id and both URLs. |
| `sbx run cmd RUN_ID '<cmd>'` | generic escape hatch — synchronous, runs in `app/` on the box. Your inspection tool. |
| `sbx run agent RUN_ID "PROMPT"` | Claude Code inside the box, resumable session — hand off, then keep talking |
| `sbx lifecycle execute RUN_ID "PROMPT"` | detaches the manifest's `kickoff` command inside the box; returns a pid, records it |
| `sbx manage list` | every run on this machine: state, VM alive, spend |
| `sbx manage harvest RUN_ID` | pull the run's commits home as a git bundle, fetched into `refs/sandbox/<run-id>` |
| `sbx lifecycle teardown RUN_ID [--no-harvest]` | spend → artifacts → harvest → revoke → destroy → close. **The only destructive command.** |
| `sbx manage reap [--yes]` | revoke orphaned `sbx-*` keys. Dry run by default. |
| `sbx manage doctor` | preflight everything in one pass. Run it before the first mount. |

The run id is the handle for everything; report it, keep it. `harvest` is
non-destructive and idempotent — it reads the box and writes only under
`refs/sandbox/`, never your working tree, index, or any branch you own. Run
it the moment a run commits rather than waiting for teardown.

### Looking at what came back

`harvest` must run inside a clone of the **target** repo — it verifies this, so
running it from the sbx checkout fails on purpose. It fetches the run's commits
into `refs/sandbox/<run-id>` there and drops a durable bundle at
`~/.local/state/sbx/runs/<run-id>.bundle`. To read the change:

```bash
git log --oneline main..refs/sandbox/<run-id>   # what the run committed
git diff main refs/sandbox/<run-id>             # the whole change
git show refs/sandbox/<run-id>:index.html       # one file, nothing checked out
```

To see the result *running* — open the produced HTML in a browser, serve the
built site — materialize the ref in a worktree so your own working tree and
branches stay untouched:

```bash
git worktree add ../preview refs/sandbox/<run-id> --detach
open ../preview/index.html                      # macOS; xdg-open on Linux
git worktree remove ../preview                  # when done
```

The ref outlives the VM, and the bundle outlives the ref: it carries the same
commits (on `sbx/<run-id>`, the branch the in-box agent commits to), so it can
be fetched into any clone of the target repo, on any machine, any time later:

```bash
git fetch ~/.local/state/sbx/runs/<run-id>.bundle "sbx/<run-id>:refs/sandbox/<run-id>"
```

The full operating detail — cookbooks for mounting, executing work, watching a
run, debugging a failed gate, fan-out, teardown — lives in
[`.claude/skills/sbx-orchestrator/SKILL.md`](.claude/skills/sbx-orchestrator/SKILL.md).

## Where it can still fail

Measured on live hardware, each at the cost of a debugging cycle:

- **A just module inherits nothing.** Not variables, not settings, not the
  working directory. Every module re-declares what it needs, and each missing
  line fails in a different silent way. `--working-directory` is the sharp
  example: it reaches root recipes but not module recipes, which resolve their
  own directory — so a mount can silently target the wrong repo. That is why
  `bin/sbx` exports the invocation directory and every recipe returns to it.
- **Never `apt` in the mount path.** About 35s per package from the `dal`
  region, against ~1s each for bun and just from their own CDNs. The base
  provisioner installs from CDNs only, and an unsupported toolchain entry is a
  hard error rather than a silent skip.
- **An unsynced golden-VM clone produced 5,641 zero-byte files** and every naive
  check passed. That is why the builtin gate asserts `git status --porcelain` is
  clean and HEAD matches the recorded sha — content, not existence.
- **A dead key still answers 200 from `GET /api/v1/key`.** Revocation is gated
  against the key *list*, never the single-key endpoint, or teardown would
  report success over a key that still spends.
- **`ssh` reads the caller's stdin.** In a loop fed by a list, the first `ssh`
  eats the rest and the loop runs once. Every `ssh` inside a loop takes
  `< /dev/null`.

## Fan-out

Nothing about the phases is single-box. One prompt, N manifests or N rosters, N
VMs: `create` is the only non-idempotent phase, and run ids are unique by
construction because the id becomes the VM name and the VM name becomes a public
hostname. Drive the phases per id rather than calling `mount` concurrently —
`mount` learns its generated id by reading the newest record, so two overlapping
mounts would hand the second run's id to the first run's `fill`.

Harvest never merges. Each run's commits land at `refs/sandbox/<run-id>`, parked
for a human to compare and pick a winner — the same
[readback commands](#looking-at-what-came-back), once per run id.

## Where this came from

Extracted from
[inkwell-agent-sandboxes-and-software-factory](https://github.com/disler/inkwell-agent-sandboxes-and-software-factory)
by **IndyDevDan** ([@disler](https://github.com/disler)). The six-phase mount
model, the credential boundary, and the run record all originate there.

