# A worked example: one prompt, one throwaway VM, one shipped feature

On 2026-08-11 this system was pointed at a real task and left alone. It planned,
built, tested and committed a SQLite FTS5 full-text search feature into a Bun app
running on a disposable VM, and the human in the loop typed six commands.

This is the whole run, verbatim — including the two defects the machinery caught
before they could waste a phase, and how both were fixed at the source.

| | |
|---|---|
| **Task** | [`prompts/01-fts5-search.md`](https://github.com/jeffjacobsen/inkwell/blob/main/prompts/01-fts5-search.md) — replace a `LIKE '%term%'` filter with a ranked FTS5 index returning highlighted snippets |
| **Target** | [`jeffjacobsen/inkwell`](https://github.com/jeffjacobsen/inkwell) — a Bun + `bun:sqlite` blog app, cloned fresh onto a blank VM |
| **Result** | 5/5 phases green, 619 insertions, tests 30 → 39, committed `536701c` |
| **Cost** | **$1.96** and 4,304,843 tokens of model spend, plus about 6 minutes of VM |

---

## The Repos

| repo | owns | scoped to |
|---|---|---|
| [`sbx`](https://github.com/jeffjacobsen/sbx) | the VM lifecycle, credentials, the health gate | **one machine** — installed once, run from inside any repo |
| [`inkwell`](https://github.com/jeffjacobsen/inkwell) | the app, its prompts, and a `sandbox.yaml` saying how to run it | one project |

sbx is installed once:

```bash
git clone https://github.com/jeffjacobsen/sbx ~/code/sbx
ln -s ~/code/sbx/bin/sbx /usr/local/bin/sbx
```

Credentials live at `~/.config/sbx/env` for the same reason — an account-scoped
key does not belong in any one working tree, where a `git add -A` can reach it.

---

## Step 0 — Preflight, before anything is billable

```bash
cd ~/code/inkwell
sbx manage doctor
```

```
  ok    ssh exe.dev reachable
  ok    known_hosts can verify a vm
  ok    OPENROUTER_PROVISIONING_KEY set
  ok      ...and mints (management key)
  ok    run_record helper runs
  ok    run store writable
  ok    sandbox.yaml valid
  ok    base provisioner present
  ok    credential provider resolves
  sbx doctor: OK
```

Every one of those is a failure that otherwise shows up **after** a VM exists and
is charging. The management-key check is the sharpest: an OpenRouter *management*
key and an *inference* key are both `sk-or-v1-…`, so the prefix cannot tell you
which you pasted — doctor asks the API instead.

---

## Step 1 — Mount, and the first real catch

```bash
sbx mount fts5-search
```

`mount` chains **create → fill → setup → observe** and stops. It never tears
down: a VM left running is a bill, but a VM destroyed early is the evidence and
the artifacts, gone.

It did not pass:

```
[gate] A PASS  git integrity
[gate] PASS  pi model registry loaded
[gate] roster answers, cost is non-zero, credit remains
   FAIL  fireworks/accounts/fireworks/models/kimi-k3: … is not a valid model ID
   pass  google/gemini-3.6-flash
   pass  openai/gpt-5.6-luna
   pass  openai/gpt-5.6-terra

[setup] FAILED: … a roster model did not answer (exit 2)
[setup] the VM is still running on purpose — the evidence is on the box
```

**This is the gate working, not the system failing.** The roster pointed the
planner at a *Fireworks* provider path while every other agent used an OpenRouter
id, and OpenRouter does not serve it. The comment on that assertion says exactly
why it exists: *"a roster id that 404s fails the first agent call, 80s into a
run."* Catching it here cost one re-run of `setup`. Catching it later would have
cost a planner phase.

The failure left the VM alive on purpose and handed over the commands to
investigate it.

### Fixing it

```bash
# in inkwell: point the planner at a model the gate just proved answers
$EDITOR adws/adw_sssf_config/sssf.config.yaml
git commit -am "Fix the planner's model: a Fireworks path is not an OpenRouter id"
git push

# re-pin the box to the fix and re-gate — both phases are idempotent
sbx lifecycle fill  fts5-search-20260811-984a34 e54b109
sbx lifecycle setup fts5-search-20260811-984a34
```

```
[gate] PASS  roster answers, cost is non-zero, credit remains
[setup] GATE PASSED — fts5-search-20260811-984a34 is healthy
```

> **Since fixed.** The defect was in the factory's *template*
> (`.claude/skills/sssf/templates/sssf.config.yaml` in `sandbox-factory`), so
> every fresh `/sssf install` stamped the same dead id.
>
> The right id turned out to be `moonshotai/kimi-k3` — the model the roster
> always meant, already declared in `models.json.tmpl`, and served by OpenRouter.
> Only the *prefix* was ever wrong. The run below used `openai/gpt-5.6-terra`
> because the first fix substituted a different model on a bad reading of a
> truncated `pi --list-models`; checking the public models endpoint settled it.
> The lesson is smaller than it looked: not a missing model, a mistyped provider.

---

## Step 2 — Serve it

```bash
sbx lifecycle observe fts5-search-20260811-984a34
```

```
[2/5] app  :4501
       up
[3/5] proxy -> :4501 (app), public
[5/5] verifying
       app  200 anonymous

  app  https://fts5-search-20260811-984a34.exe.xyz/
```

Exactly one service may be `public: true`. Public is a property of the single
port the exe.dev proxy targets, so a second is not a stricter setting — it is a
contradiction, and the loser fails silently as a 307 nobody expected.

---

## Step 3 — Put the work in

```bash
sbx lifecycle execute fts5-search-20260811-984a34 "$(cat prompts/01-fts5-search.md)"
```

```
→ pid 926 recorded; SDLC is running detached
→ watch it:  sbx run cmd fts5-search-20260811-984a34 'tail -f run.log'
```

The prompt is a **file**, not a sentence typed at a terminal. It states where to
change things, seven numbered "done means" clauses, the constraints, and an
explicit out-of-scope list. That specificity is what makes the result checkable
later instead of a matter of taste.

The command is detached — `nohup`, redirected, `< /dev/null` — so the run
survives the ssh session closing.

---

## Step 4 — Watch it work

```bash
sbx run cmd fts5-search-20260811-984a34 'tail -20 run.log'
```

```
adw_id: d7153279   engineer exedev
▶ 01 request  engineer · exedev  Capture the incoming ask
  ✓ request 0.0s
▶ 02 plan  agent · planner  Turn the request into an implementable plan
  ▸ planner openai/gpt-5.6-terra  session sssf-d7153279-planner-73c2
  ✓ gate artifacts_exist 2 checked
  ✓ gate files_non_empty 2 checked
  ✓ PlanOutput Planned FTS5-backed, safely highlighted search with a LIKE
    fallback, UI rendering, migration support, and comprehensive tests.
  └ planner used 94,022 tokens · $0.0754
  ✓ plan 74.0s
▶ 03 build  agent · builder  Implement the plan exactly
  ▸ builder google/gemini-3.6-flash  session sssf-d7153279-builder-db84
  └ builder used 4,210,821 tokens · $1.8846
  ✓ build 305.9s
▶ 04 test_1  code · quality  Run the suite — a known command, so code runs it
  · quality tests: bun test apps/inkwell/server.test.ts
  · quality tests: passed (exit 0, 0.4s)
▶ 05 commit  code · git  Land the code only after the suite came back green
  · sha: 536701c
```

Three things are worth noticing in that log.

**Phases 04 and 05 are `code`, not `agent`.** A known command is code, not a
judgement call. An agent rediscovering `bun test` on every run once cost ~1M
tokens and 85 seconds; running it as code costs milliseconds. The commit phase is
gated on it — code lands *only* after the suite comes back green.

**The test command came from configuration, not from Python.** `bun test
apps/inkwell/server.test.ts` is an argv list in `sssf.config.yaml`. That is
deliberate: this project previously customised by *editing* the shared
`quality.py`, renaming `run_tests` to `run_inkwell_tests`, and three workflows
kept calling the old name — failing at the *tail* of each chain, after the
planner and builder had already spent, ~$0.96 a run. Function names are permanent
now; commands are data.

**Different models for different phases.** The planner is the expensive
reasoning model for 74 seconds; the builder is a cheap fast one for five minutes
of mechanical work. Swapping the whole roster is one flag: `--config
adws/adw_sssf_config/sssf.frontier.config.yaml`.

---

## Step 5 — Verify from outside the box

Green tests are the *floor*, not the proof. The app is on a public URL, so the
feature can be checked the way a user would:

```bash
U=https://fts5-search-20260811-984a34.exe.xyz

curl -sS -X POST "$U/api/posts" -H 'Content-Type: application/json' \
  -d '{"title":"Morning pages","content":"The quiet room is where the writing happens before the noise starts."}'

curl -sS "$U/api/posts?q=quiet"
```

```json
[{
  "id": 1,
  "title": "Morning pages",
  "status": "draft",
  "updated_at": "2026-08-11T22:19:27.006Z",
  "word_count": 12,
  "target_word_count": 0,
  "snippet": "The <mark>quiet</mark> room is where the writing happens before the noise starts.",
  "rank": -9.850746268656719e-07
}]
```

The post was created through the API *after* the feature shipped and came back
searchable with no reindex step — so the FTS5 triggers are live, not a one-time
backfill.

Every numbered clause in the prompt, checked against the running app:

| the prompt asked for | result |
|---|---|
| triggers keep the index current | ✅ new post searchable immediately |
| ranked best-match first | ✅ `rank` present and ordered |
| `snippet` + `rank`, `<mark>` around hits | ✅ shown above |
| **unfiltered shape unchanged** | ✅ exactly the 6 original keys, no leakage |
| multi-word AND, case-insensitive, `*` prefix | ✅ `quiet writing`, `QUIET`, `rollb*` |
| hostile input → 200 + array, never 500 | ✅ `"`, `AND`, `foo NEAR bar)`, `*` all 200 |
| no match → `[]` | ✅ |

That fourth row is the interesting one. The prompt deliberately included a
regression the existing suite already guards — *"server.test.ts already asserts
the exact key set of a summary row … and that assertion must still pass
untouched"* — so a builder that broke the contract to add its feature would fail
its own test phase. It did not.

---

## Step 6 — Bring the work home

```bash
sbx manage harvest fts5-search-20260811-984a34
```

```
   harvest: 1 commit(s) -> refs/sandbox/fts5-search-20260811-984a34
     bundle:  ~/.local/state/sbx/runs/fts5-search-20260811-984a34.bundle
     diff it: git diff e54b109..refs/sandbox/fts5-search-20260811-984a34
```

Harvest is **non-destructive and idempotent** — it reads the box and writes only
under `refs/sandbox/`, never your working tree, index, or any branch you own. Run
it the moment a run commits; do not wait for teardown. The commits arrive as a
*ranged* git bundle, which records "you must already have `<base>`" and refuses
to import disconnected history — a free integrity check on the return trip.

The result is a ref you review like any other:

```
536701c Implement SQLite FTS5 search with highlighted snippets and fallback

 apps/inkwell/public/app.js            |  30 +++++
 apps/inkwell/public/index.html        |   2 +-
 apps/inkwell/public/style.css         |  19 ++-
 apps/inkwell/server.test.ts           | 247 ++++++++++++++++++++++++++
 apps/inkwell/server.ts                | 245 +++++++++++++++++++++++---
 specs/d7153279_fts-search-snippets.md |  63 ++++++++
 7 files changed, 619 insertions(+), 17 deletions(-)
```

Nothing is on `main` until a human puts it there.

---

## Step 7 — Tear down

```bash
sbx lifecycle teardown fts5-search-20260811-984a34
```

Teardown is the **only** destructive recipe, and it is always an explicit
decision — nothing on the success path chains into it. The order is
`spend → artifacts → harvest → revoke → destroy → close`, and it matters: spend
is unrecoverable once the key is deleted, and revoking before destroying means a
crash in between leaves a dead key and a live VM, not the reverse.

The final gate asks the OpenRouter **key list** whether the key is gone, never
the single-key endpoint — a dead key still answers `200` there.

---

## What it cost

| | |
|---|---|
| planner | 94,022 tokens · $0.0754 · 74.0s |
| builder | 4,210,821 tokens · $1.8846 · 305.9s |
| test + commit | code, not agents · 0.4s |
| **total** | **4,304,843 tokens · $1.96** · ~6.5 min of workflow |

The runtime key was capped at **$50** and minted for this run alone. It is
revoked at teardown, so the blast radius of a runaway agent is bounded by a
number you chose before it started.

---

## What the machinery caught

Both defects in this run were found by checks, not by a failed feature:

1. **A dead model id in the roster** — caught by the health gate before any agent
   ran. Cost: one `setup` re-run.
2. **A wrong kickoff command** — the manifest was adapted from a repo whose
   justfile namespaces workflows behind `mod adw`, while a stamped justfile
   exposes them flat. `just adw sdlc` would have failed on the box *after* create,
   provision and gate — i.e. after the VM was paid for. Caught by reading the
   stamped recipe first.

Neither is a bug in the feature that shipped. Both are the kind of failure that,
uncaught, surfaces as a confusing agent error deep inside a paid run.

---

## Reproducing it

```bash
# sbx itself — see the README for the same three lines
ln -s "$PWD/bin/sbx" /usr/local/bin/sbx
printf 'OPENROUTER_PROVISIONING_KEY=sk-or-v1-…\n' > ~/.config/sbx/env && chmod 600 ~/.config/sbx/env

git clone https://github.com/jeffjacobsen/inkwell && cd inkwell
sbx manage doctor
sbx mount my-run
sbx lifecycle execute <run-id> "$(cat prompts/02-revision-history.md)"
sbx run cmd <run-id> 'tail -f run.log'
sbx manage harvest <run-id>
sbx lifecycle teardown <run-id>
```

`prompts/02` through `05`, `07` and `08` are all unapplied and self-contained.
`02-revision-history` is the closest sibling to the run above.
