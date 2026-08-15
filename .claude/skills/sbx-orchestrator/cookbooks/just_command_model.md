# The just command model

Two justfiles, two layers, and a boundary that is enforced by `just`'s own semantics. Since sbx was
split out of sandbox-factory the two layers live in two repos: `sbx` is installed once per machine
and reached through `bin/sbx`, while `just adw …` comes from whatever repo you are standing in. Read
this before you type any `just` command — the difference between `just adw sdlc "..."` and
`sbx lifecycle execute <run-id> "..."` is the difference between the factory running **on your laptop** and
the factory running **in a throwaway VM**, and the two commands look almost identical.

## The two layers

| | OUT-sandbox — orchestration | IN-sandbox — execution |
|---|---|---|
| Files | the sbx install: `just/` (`mount.just`, `lifecycle/`, `manage/`, `run/`) | `just/adws.just`, in the repo being mounted |
| Wired by | `mod lifecycle`/`manage`/`run` + `import 'just/mount.just'` in sbx's own root justfile, reached through `bin/sbx` | `mod adw 'just/adws.just'` |
| Namespace | flattened into the root: `sbx lifecycle create`, `sbx lifecycle fill`, `sbx lifecycle setup`, `sbx lifecycle execute`, `sbx run cmd`, `sbx run agent`, `sbx lifecycle observe`, `sbx lifecycle teardown`, `sbx manage reap` | prefixed: `just adw sdlc`, `just adw scout`, … |
| Runs where | your machine | the VM (and, dangerously, your machine too) |
| Credential | exe.dev account + `OPENROUTER_PROVISIONING_KEY` | the disposable runtime key in `app/.env` |

The boundary rule is one question: **what credential does it need?** Provisioning key or exe.dev
account means host-only. Runtime key only means it runs inside. Both halves ship to the sandbox —
the boundary is which credentials are present, not which files are.

## `mod` is not `import`, and that is the whole design

Verified on `just 1.57` (host) and `just 1.58` (VM).

| Behavior | `import` | `mod` |
|---|---|---|
| Recipe names | flattened into the root | namespaced under the module name |
| Parent **variables** | inherited | **NOT** inherited |
| Working directory | the root justfile's dir | **the module file's own dir** (`just/`) |
| Parent **settings** (`set …`) | inherited | **NOT** inherited |
| Setup cost | none | four `set` lines at the top of the module |

Both halves of that table are load-bearing here.

### Why each `mod.just` repeats its declarations

A `mod` inherits nothing, so `just/lifecycle/mod.just`, `just/manage/mod.just` and
`just/run/mod.just` each restate the same three lines:

```just
set working-directory := '../..'   # relative to THIS file's dir — the install root
set positional-arguments           # without it "$@" is EMPTY and every argument is dropped
set dotenv-load
```

- **`set working-directory`** — a module runs from *its own* directory, so the path is relative to
  the module file, not to the root justfile. It was `'../../..'` for a while, left over from when
  these lived one level deeper in sandbox-factory, which put every module a directory *above* the
  install root. Nothing caught it because no phase recipe depends on cwd (see below) — only the
  `default` listing recipes broke, and only when run.
- **`set positional-arguments`** — the nasty one, because it fails **silently**: without it `$@` is
  empty and a recipe that forwards `"$@"` runs with no arguments at all, which reads as a bad
  payload rather than a bad justfile.
- **`set dotenv-load`** — same non-inheritance. Note that `bin/sbx` does its own `.env` loading
  anyway, precisely because just resolves dotenv relative to the justfile and would look in the
  install dir instead of the repo you are mounting.

**No recipe here trusts the working directory.** Every one opens with
`cd "${SBX_TARGET:?run sbx via bin/sbx, which exports it}"`, because `just --working-directory`
reaches root recipes but **not** module recipes — measured, and a silent way to mount the wrong
repo. Paths into the install itself are absolute via `{{justfile_directory()}}`, which is how
`lib/run_record.py` and `lib/manifest.py` resolve.

### Why the phase files declare nothing

They are `import`s, so they share the root's scope, settings and working directory. That means:

- **No `set` lines in a phase file.** Duplicating `set dotenv-load` or `set positional-arguments`
  is a hard parse error, and it breaks *every* recipe in the repo, not just that file.
- **No file-level variables in a phase file.** Six imports share one namespace, so a `repo :=` in
  two of them collides. Everything is bash-local inside the recipe body instead.

## Discovery cheat-sheet

```bash
sbx                             # the top level: mount + the three groups
sbx --list lifecycle            # every phase inside a group
sbx --summary                   # names only, one line
sbx --show mount                # the body of one recipe, including its comments
sbx --show lifecycle::execute   # a module recipe's body (:: is the path separator)
sbx --evaluate                  # every variable the root justfile resolved
sbx --fmt --check --unstable    # does the justfile still parse
```

**`sbx lifecycle --list` is invalid syntax.** `--list` after a module name is read as a recipe name:

```
$ sbx lifecycle --list
error: justfile does not contain recipe `lifecycle --list`
```

The flag goes **before** the module: `sbx --list lifecycle`. (The module's own `default` recipe does
the same thing — a bare `sbx lifecycle` lists rather than silently running the first recipe in the
file.)

## The warning that matters most

> The target repo's own entry point — in sandbox-factory, `just adw sdlc "..."` — run on the host
> runs its full software factory **on your laptop**: your working tree, your git state, your ports,
> your files. That is the exact thing this system was built to prevent.

The payload is written to be *identical* whether it runs here or on a VM. That portability is also
the trap — nothing about the command tells you which machine it is about to modify. In-sandbox work
always goes through a phase recipe, which takes a **run id** as its first argument:

| You want | Type this | Not this |
|---|---|---|
| the factory, in a sandbox | `sbx lifecycle execute <run-id> "<prompt>"` | `just adw sdlc "<prompt>"` |
| one step of it, in a sandbox | `sbx run cmd <run-id> '<the repo's own command>'` | running that command here |
| the factory, here, on purpose | the repo's entry point, typed deliberately | — |

Rule of thumb: **if the command has no run id in it, it is running here.**

## Running `just` inside the sandbox

Any `just` invoked on the VM must be:

```bash
just --shell bash --shell-arg -c <recipe> …
```

The root justfile's `set shell := ["zsh", "-ic"]` is parsed on the VM too, and zsh is not in the
image. This is why `execute` launches
`nohup just --shell bash --shell-arg -c adw sdlc "$Q" > run.log 2>&1 < /dev/null &`.

Two related facts about remote invocation:

- Every `ssh vm 'cmd'` is a **fresh non-interactive shell that reads no rc file**. That is why
  `provision.sh` symlinks bun into `/usr/local/bin` (a `PATH` export inside provision dies with
  provision), and why `just` is installed to `/usr/local/bin` rather than a user dir.
- The sandbox's `sh` is dash, which does not understand `${@:2}` — another reason
  `--shell bash` is mandatory rather than cosmetic.

## Resolved: the strip used to break the imports

**Measured 2026-08-04 on the live e2e VM (`just 1.58`).** `import` is not optional in just: a
missing source file is a parse error that kills the whole justfile. While `provision.sh` deleted
`just/`, a correctly stripped sandbox could not parse its own root justfile, so
`just --shell bash --shell-arg -c adw sdlc "..."` — the exact command `execute` runs — died at
parse time.

**The strip is gone, so this cannot happen any more.** The whole repo ships intact and the
justfile always parses. One habit from that era is still worth keeping:

- **A recorded pid does not mean the SDLC is running.** `nohup … & echo $!` returns a pid for a
  process that exits one millisecond later. Always confirm against `run.log`.

## Recipe-body rule

**An unindented line inside a recipe body TERMINATES the recipe.** Everything after it is parsed as
new top-level justfile syntax, which usually produces a confusing error somewhere else in the file.
This is why the gate in `setup.just` computes cost with `jq` instead of a multi-line heredoc of
python: python needs unindented lines, jq does not, and jq ships in the exeuntu image.
