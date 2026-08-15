# Observe a sandbox and report on it

`sbx lifecycle observe <run-id>` makes a mounted sandbox watchable from **outside**, without reaching in.
`sbx mount` ends here.

```bash
sbx lifecycle observe <run-id>
```

Six steps, all idempotent — a server already listening is left alone, so re-running never stacks a
second bun on the same port:

```
── observe <run-id> · vm <vm> ──────────────────────────────
[1/6] ssh ok — <vm>.exe.xyz
[2/6] app  :4501
       started pid <pid>
       up
[3/6] obs  :4600
       started pid <pid>
       up
[4/6] proxy -> :4501, public
[5/6] recording ports
[6/6] verifying
       app  200 anonymous
       obs  307 anonymous — expected, it is owner-gated

════════════════════════════════════════════════════════════
  app  https://<vm>.exe.xyz/
  obs  https://<vm>.exe.xyz:4600/
════════════════════════════════════════════════════════════
```

The proxy retarget in step 4 is **mandatory**: a fresh exeuntu VM proxies port 8000 (the smallest
`EXPOSE`d port ≥1024), so without `ssh exe.dev share port <vm> 4501` the bare hostname hits nothing.
Servers must bind `0.0.0.0`; bun does by default, which `ss -ltn` confirms as `*:4501`.

## The two URLs

| | URL | Anonymous | Serves |
|---|---|---|---|
| app | `https://<vm>.exe.xyz/` | **200** | Inkwell, the app under development, port 4501 |
| obs | `https://<vm>.exe.xyz:4600/` | **307** | the SSSF trace UI: sessions, phases, events, cost |

Measured live on the e2e VM, 2026-08-04: `app 200`, `obs 307`.

## The 307 is correct, not a bug

**Only ONE port on a VM can ever be anonymous** — whichever one `ssh exe.dev share port` names.
`share set-public` applies to that primary port only. Ports 3000–9999 are transparently forwarded by
the proxy, but the alternates stay **auth-gated to users with VM access**. So:

- anonymous request to `:4600` → **307**, a redirect into exe.dev's login;
- the same URL in a browser already signed in as the VM's owner → **opens fine**.

`observe` treats it that way: it only fails the obs check on `000` (dead proxy) or a 5xx. Anything
else means the port is reachable and gated, which is the intended posture — the app is for showing
people, the trace UI is yours.

Do not try to "fix" it by making 4600 public. You cannot have both, and swapping the primary port
would take the app offline.

## What to tell the user

Say the two URLs, say which one is which, and pre-empt the 307 in one clause:

> `<run-id>` is up.
> App: `https://<vm>.exe.xyz/` — public, anyone can open it.
> Trace UI: `https://<vm>.exe.xyz:4600/` — opens for you in a browser signed in to exe.dev; it
> redirects (307) for anyone else, which is expected: only one port per VM can be anonymous.

If a run is in flight, add the one-line status from the trace db (below) rather than pasting a log.

## Reading progress from inside the box

**sbx has no idea what progress looks like.** It knows the box is up, which ports answer, and what
`run.log` contains; anything richer is the payload's own instrumentation, queried through the same
escape hatch as everything else:

```bash
sbx run cmd <run-id> '<the payload's own status command>'
sbx run cmd <run-id> 'tail -40 run.log'          # always available — EXECUTE writes it
```

For **sandbox-factory** that instrumentation is a WAL sqlite trace db at `app/adws/adw_data/sssf.db`
— WAL, so reads never block the running writers, and you can poll it as often as you like. Its
schema (`sessions`, `phases`, `events`, `gate_results`, `processes`), the queries worth running, and
what each column means live with the factory, in `/sssf`'s `references/observability.md`. The one
worth memorising is the whole report in a row:

```bash
sbx run cmd <run-id> 'sqlite3 adws/adw_data/sssf.db "select adw_id,status,total_tokens,round(total_cost,4) from sessions order by started_at desc limit 5;"'
# 84b6551f|success|902831|0.528
```

Nested quoting gets ugly fast. When it does, collapse to a single hop:

```bash
ssh <vm>.exe.xyz "cd app && sqlite3 adws/adw_data/sssf.db \"select adw_id,status from sessions;\""
```

> **A repo's own observability recipes read its LOCAL db**, from runs that happened on your laptop.
> They know nothing about a sandbox. For a mounted run, always go through
> `sbx run cmd <run-id> '…'`.

## When a server is not there

| Symptom | Cause | Fix |
|---|---|---|
| a service never bound its port | it needs a file that does not exist yet — the file it declared in `requires:` | re-run `sbx lifecycle setup <run-id>`; the repo's provisioner is what creates it |
| `bun: No such file or directory` in `~/inkwell-app.log` | each `ssh vm cmd` is a fresh non-interactive shell that reads no rc file | provision symlinks bun into `/usr/local/bin` — re-run setup |
| obs page 404s but the API answers | `dist/` was never built | provision step 7 runs `bunx vite build` — re-run setup |

The logs are on the VM at `~/inkwell-app.log` and `~/visualizer.log`; `observe` tails them for you
on failure, and `sbx run cmd <run-id> 'tail -40 ~/visualizer.log'` gets them any time.

## Reporting a finished run

1. **Status and cost** — the `sessions` row above, or the panel at the end of `run.log`:
   `status ✓ success · phases 5/5 passed · tokens 902,831 · cost $0.5280 · adw_id 84b6551f`.
2. **What landed** — `sbx run cmd <run-id> 'git log --oneline -5'`. SSSF commits the plan, the code
   and the docs **separately**, so the shape of the run is in the commit graph, not the diff.
3. **Artifacts** — `specs/<adw_id>_*.md` and `app_docs/<adw_id>_*.md` on the VM.
4. **Spend** — recorded into the run record by `teardown` (read from the runtime key *before* it is
   revoked; after the DELETE the number is unrecoverable). Note this is the **OpenRouter** spend:
   `sbx run agent` work goes through exe.dev's key-free gateway and does not appear there.

Everything above stays on the VM until teardown pulls it: `teardown` copies `specs/`, `app_docs/`,
`adws/adw_data/sssf.db` and `run.log` into `~/.local/state/sbx/runs/<run-id>-artifacts/`, plus a
`git bundle` of every commit at `~/.local/state/sbx/runs/<run-id>.bundle` — which you inspect locally with:

```bash
sbx manage harvest <run-id>
git log --oneline --graph <commit_sha>..refs/sandbox/<run-id>
```

> `harvest` does the bundling, the verification and the fetch. Do not hand-roll `git bundle` — the
> recipe ranges from the recorded `commit_sha` so the bundle stays small and refuses to import
> history that does not descend from the pin.
