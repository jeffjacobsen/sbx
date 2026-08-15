# Gotchas

Every trap below was measured on live hardware, and each one cost a debugging cycle. They are
grouped by where they bite. The guard column is what is actually in the code today.

---

## The sandbox environment

| Symptom | Cause | Guard |
| --- | --- | --- |
| The runtime key is silently empty in every `ssh vm "cmd"` | `new --env KEY=VAL` writes `/etc/profile.d/exe-env.sh` as `export KEY='VAL'`. That is read by **interactive login shells only** — not by `ssh vm "cmd"` (how the orchestrator runs everything), not by the setup script, and it is not in `/etc/environment` | Never use `--env` for anything the mount needs. FILL writes `app/.env` post-clone; SSSF reads it via `set dotenv-load` |
| `bun: No such file or directory` from OBSERVE, right after provision used `bun` successfully | Each `ssh vm cmd` is a **fresh non-interactive shell that reads no rc file**. The bun installer only edits shell rc files, so a `PATH` export inside provision.sh dies with that script | The **base provisioner** symlinks `~/.bun/bin/bun` (and `bunx`) into `/usr/local/bin`. `just` avoids this by installing there already |
| A mount takes minutes instead of seconds | `apt` from the dal region is ~148 kB/s, **~35s per package** | **NEVER add apt**, to the base provisioner or a project hook. bun and just come from their own CDNs in ~1s combined |
| `command not found` for something you assumed was there | exeuntu ships `pi`, `claude`, `codex`, `uv`, `python3`, `git`, `gh`, `sqlite3`, `jq`, `docker`, `rg`, `ffmpeg`, headless Chrome. It does **not** ship `bun`, `just`, `node`/`npm`, or `zsh` | provision.sh installs bun + just. Nothing may depend on node or zsh |
| `Host key verification failed` on the first exec against every new VM | **Every `*.exe.xyz` VM shares ONE host key**, `SHA256:JJOP/lwiBGOMilfONPWZCXUrfK154cnJFXcqlsi6lPo`, identical to `exe.dev` itself | One wildcard `known_hosts` line, installed once. Every recipe then uses plain `ssh`/`BatchMode` with no `StrictHostKeyChecking` games |

---

## pi and cost reporting

| Symptom | Cause | Guard |
| --- | --- | --- |
| A naive health check passes, then the first agent call fails | `~/.pi/agent/models.json` does **not exist on a fresh VM**, and without it `pi --list-models` prints `No models available` and **EXITS 0** | Gate **B** asserts on the *output*, never `$?`, and rejects that exact string. `command -v pi` runs first, or a missing `pi` prints one line of "command not found" that a bare non-empty check calls a pass |
| `No models available` even though models.json exists and looks fine | pi's cost block needs **ALL FOUR** of `input`/`output`/`cacheRead`/`cacheWrite`. A partial block fails schema validation (`must have required properties cacheRead, cacheWrite`) and pi then drops **THE ENTIRE ROSTER**, not just that model | Every model in `models.json.tmpl` carries all four. Use `0.0` where a provider publishes no cache-write rate |
| Every run logs `$0.0000` while the bill goes up. Observed: a **463.6k-token run logged $0.0000** | Without a rate table pi defaults every rate to zero, and anything that reports spend by reading `usage.cost.total` out of pi (sandbox-factory's agent wrapper does) inherits the zero | Gate **D**, in two halves: a real pi call must report cost > 0, **and** every model in `models.json` must have a non-zero `cost.input`. Verified fixed: a 1,797-token run then reported $0.0081 |
| Gate D false-fails a perfectly healthy sandbox | The **wrong instrument**. An earlier version diffed `GET /api/v1/key` usage before and after the pings — four 250-token pings round to $0 there | Ask **pi**, not OpenRouter. One sentence on the cheapest roster model reports cost `4.3e-05`: small, unambiguously > 0 |
| Gate C reports FAIL for a model that clearly answered | Reasoning models return `content: null` with the text under `.reasoning` | The ping check accepts `content + reasoning` concatenated |
| Every agent invocation writes `reflection fetch failed: ... unrecognized reflection shape` to stderr | exe.dev ships a broken pi extension at `~/.pi/agent/extensions/exe-dev/`, wired to a reflection integration that is not attached | Cosmetic and exits 0 — but it pollutes stderr, which matters when the factory parses agent output |
| `User not found` on an inference call | The **provisioning key cannot do inference.** It mints and revokes only | Gate C/D/E ping with the minted **runtime** key, read out of `app/.env` on the VM |

---

## `just`, `mod`, and recipe syntax

| Symptom | Cause | Guard |
| --- | --- | --- |
| `could not find the shell: zsh` inside the sandbox | A target repo whose root justfile sets `shell := ["zsh", "-ic"]` (so the engineer's shell functions resolve on the host) carries that setting into the box too. zsh is **not in the exeuntu image**, and installing it is ~35s of apt for no benefit | The repo's own `kickoff.default` carries `just --shell bash --shell-arg -c …`. That is the manifest's job, not sbx's — EXECUTE runs the template as written |
| The recipe silently ends early, or `just` reports a syntax error in a heredoc | **An unindented line inside a just recipe body TERMINATES the recipe.** Multi-line python cannot survive it | Use `jq` (it ships in the image) for in-recipe JSON. Where python is unavoidable, keep the heredoc body indented |
| A `mod` recipe cannot see paths that work from the repo root | A `mod` runs with cwd set to the **module file's own directory**, and inherits no settings or variables from its parent | Every sbx recipe opens with `cd "${SBX_TARGET:?…}"` rather than trusting cwd — the repo being mounted is never the install dir. See `just_command_model.md` |
| The justfile fails to parse after adding a recipe file | Files pulled in by `import` share their **parent module's** scope, settings and working directory. A duplicate `set dotenv-load` / `set positional-arguments`, or a repeated top-level variable, is a hard error | `set` lines belong in a `mod.just` and nowhere else. Imported files carry no settings and no file-level variables — everything is a bash local |

---

## Detaching and long-running processes

| Symptom | Cause | Guard |
| --- | --- | --- |
| `sbx lifecycle execute` hangs forever and ssh never returns | Detaching needs **all three**: `nohup` (survive session end), the output redirect (release stdout/stderr), and `< /dev/null` (release stdin). Dropping any one hangs the recipe | `( nohup <cmd> > run.log 2>&1 < /dev/null & echo $! )` — verbatim, everywhere |
| `nohup: failed to run command 'SSSF_DB=...': No such file or directory` | `nohup VAR=x cmd` makes nohup try to exec a program literally named `VAR=x` | Put the assignment **before** `nohup`: `SSSF_DB=... nohup bun run ...` |
| The captured "PID" is not a number | Stray remote stdout (an motd, a chatty rc) landed ahead of it | `tail -n 1` on the capture, then a numeric check that fails loudly rather than writing garbage into the record |
| The previous run's log is gone | `run.log` is **truncated on every `sbx lifecycle execute`** — one detached SDLC per sandbox at a time is the intended shape | Pull the old log first if you care about it |
| `setup.just`'s own stdin gets eaten by ssh | ssh consumes the calling script's stdin by default | `< /dev/null` on every non-interactive `ssh` in the phase recipes |

---

## Ports, proxy, observability

| Symptom | Cause | Guard |
| --- | --- | --- |
| `https://<vm>.exe.xyz/` reaches nothing | A fresh exeuntu VM proxies **port 8000** (smallest `EXPOSE`d port ≥ 1024); Inkwell serves 4501 | `ssh exe.dev share port <vm> 4501` is **mandatory, not cosmetic**, then `share set-public` |
| The URL silently 502s | The server bound `127.0.0.1`; the proxy cannot reach it | Servers must bind `0.0.0.0`. Bun does by default — `ss -ltn` shows `*:4501` |
| The obs URL returns **307** anonymously and you file a bug | **Only ONE port can be anonymous**, whichever `share port` names. "Public" is a property of that port, not of the VM. Ports 3000-9999 are auto-forwarded but stay auth-gated to users with VM access | That is correct, not a bug. App 4501 is public; obs 4600 returns 307 anonymously and opens fine for the signed-in owner. OBSERVE only fails the obs check on `000` or `5xx` |
| A service starts and immediately exits | It needs a file that only exists once work has run, and `sbx mount` ends at observe — **before any kickoff**. sandbox-factory's visualizer is the worked case: it refuses to start without its trace db | Declare it as that service's `requires:` in `sandbox.yaml`. OBSERVE checks a declared prerequisite **before** the start attempt, so the error names the real cause instead of showing an empty port — and the repo's own provisioner is what creates the file |
| The visualizer serves the JSON API but the page 404s | `dist/` was never built | `provision.sh` step 7/10 runs `bunx vite build` — not `bun run build`, which also runs `vue-tsc`; type errors must not be able to fail a mount |
| Headless Chromium lands on the login page even with a valid VM token in the URL | Chromium **strips credentials** before sending, so `https://x:TOKEN@vm.exe.xyz:4600/` fails even though `curl -u` with the same token returns 200 | Send `X-Exedev-Authorization: Bearer <token>` as a header. The VM-scoped token is for automation only |

---

## Keys, teardown, and cleanup

| Symptom | Cause | Guard |
| --- | --- | --- |
| Revocation looks like it failed, or a dead key looks alive | **MEASURED:** right after a successful `DELETE`, `GET /api/v1/key` still returns **200** for the dead key while the authoritative list already shows it gone | Gate revocation against **`GET /api/v1/keys`** — the LIST. Never `/api/v1/key`. Both `teardown` and `reap` do this |
| A key spends forever after the sandbox is gone | OpenRouter keys have **no native TTL**. If teardown never runs, the key outlives the VM | `sbx manage reap` — dry run by default, `--yes` to act. Run it at the start of every session |
| A personal key is at risk during cleanup | The `sbx-` prefix is the **entire** safety model; personal keys carry no prefix and deleting one is unrecoverable | `reap` filters on the prefix at selection **and** re-asserts it at the point of deletion. Never mint a managed key without it |
| Teardown cannot find the key to revoke | The run record was lost | The record is written **first**, with `O_EXCL`, and every update is atomic. `run_record.py list` raises loudly on an unreadable record instead of skipping it — a silently dropped record is a key that silently keeps spending |
| Teardown errors on a run that only half-created | A run can die anywhere: VM but no key, key but no VM, a record with neither | Every teardown step is individually guarded; a missing piece is the normal path, not an error. `404` on DELETE is treated as "already gone"; `close()` is idempotent and first-close-wins |
| The spend number is gone | It is unrecoverable after `DELETE` | Read spend **before** revoking. On a re-run where the `.key` file was already shredded, fall back to the provisioning LIST, which still carries `usage` per hash |

---

## Mounting strategy

| Symptom | Cause | Guard |
| --- | --- | --- |
| **5,641 zero-byte files**, and every naive check passed: files existed, `just --list` exited 0 | An **unsynced `ssh exe.dev cp`** of a golden VM. It reports no error of any kind | `ssh <golden> 'sync'` before `cp` — mandatory. And gate **A** checks `git status --porcelain` content, not that files exist: truncation shows up as ` M path` |
| The setup script never receives the runtime key | `--setup-script` has three disqualifiers, all measured: a **10KiB cap**, it runs **async** via `exe-setup.service` so `new` returning means nothing, and it **cannot see `--env`** | Push code, then run `provision.sh` over ssh: synchronous, uncapped, debuggable, versioned with the repo |
| Waiting on `exe-setup.service` to go inactive never resolves | `inactive` is also the **pre-run** state | Poll a **sentinel file** the script touches as its literal last line. `provision.sh` touches `/tmp/PROVISION_READY`; SETUP clears it first, or a re-run finds the *previous* run's sentinel and declares victory before provision ran |
| A mounted copy fails at the commit step | The exedev wrapper's `upload-dir` excludes `.git` by default, and SSSF workflows **commit** their plan, code and docs separately | Not applicable now: FILL does a plain `git clone` of the public repo, which brings `.git` with it. No auth, no GitHub integration, 2.61s |
| Gate A fails with unexpected working-tree changes | Something wrote into the clone. There is no longer any legitimate dirty state — the strip that used to delete tracked paths is gone | Read the porcelain lines the gate prints. The tree must be **completely** clean |

---

## What a green mount does not prove

Every gate here is a claim about the **sandbox**, not about the payload. A mount can pass A–E and
still run a factory that is broken at its last phase — sandbox-factory once lost roughly **$0.96 of
spend** to a workflow that died after the planner and builder had already done all the work, because
the failure sat at the tail of a long, expensive chain where nothing upstream touches it.

The lesson that generalizes to any payload: **run the payload's cheapest chain first**, in the box,
before spending on its full pipeline. `sbx run cmd <id> '<cheap chain>'` costs one round trip and
catches the tail-phase breakage that no sandbox gate can see.

---

## Measured numbers, for reference

| Operation | Measured |
| --- | --- |
| VM boot to SSH-ready | **1.9s** |
| public `git clone` (216 files, no auth) | **2.61s** |
| bun + just from CDNs | **~1s** |
| `bun install` (54 pkgs, cold) | 0.40s |
| cold `uv` PEP-723 resolve (11 pkgs) | 3s |
| **Total cold mount, blank VM to running factory** | **~10-12s** |
| `ssh exe.dev cp` of a synced golden VM | 0.37s server-side, ~1s wall |
| Anything via `apt` | **+35s per package** — avoid |

A custom Docker image buys ~1s. A golden VM bills continuously while idle, because exe.dev VMs
are persistent and never expire. **The choice between mount strategies is about reproducibility,
not speed.**
