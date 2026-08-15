---
name: sandbox-exe-dev
description: "Operate exe.dev persistent VMs via SSH/HTTPS for safe code execution and file operations. Use when the user needs persistent dev environments, SSH-accessible Linux VMs, or web-exposed sandboxes. Keywords: exe.dev, persistent VM, SSH, code execution, sandbox, exedev."
---

# exe.dev VMs

This skill drives **exe.dev persistent VMs over SSH** through one CLI surface:
`exedev init`, `exedev exec`, `exedev files`, `exedev share`, `exedev browser`.

The defining property is in the name. An exe.dev VM is **persistent**: it has a
real disk, it survives reboots, and it lives until you `exedev vm kill` it —
which also means a forgotten one bills forever. In exchange you get live
`resize`, whole-VM `snapshot`, and an HTTPS proxy that is auth-gated by default.

## Variables

- **`EXEDEV_CLI_PATH`**: `.claude/skills/sandbox-exe-dev/exedev_cli/`
- **`LOCAL_WORKSPACE`**: `tmp/<workflow_id>/` — local staging for files to upload/download. Create when needed.
- **`WORKFLOW_ID`**: kebab-case identifier for the current task. Generate as `<task>-<YYYYMMDD>-<short-uuid>` if the user doesn't provide one (e.g. `todo-app-20260508-7f3a`). The VM name should derive from this.
- **`TIMEOUT_DURATION_IN_SECONDS`**: **N/A on exe.dev** — VMs are persistent and never auto-expire. Tear down with `exedev vm kill <name>` when truly done.

## Prerequisites

Before using this skill, **validate the environment**:

1. **Check SSH access to exe.dev**:
   ```bash
   cd EXEDEV_CLI_PATH
   uv run exedev doctor
   ```
   Expected output ends with `doctor: OK`. If it doesn't:
   - First-ever SSH? Verify the host-key fingerprint matches `SHA256:JJOP/lwiBGOMilfONPWZCXUrfK154cnJFXcqlsi6lPo` (source: `ai_docs/exedev_sandbox_mounting.md`).
   - Permission denied? Make sure your SSH public key is registered: `cat ~/.ssh/id_ed25519.pub | ssh exe.dev ssh-key add`.
   - Wrong key picked up? Add a stanza to `~/.ssh/config`:
     ```
     Host exe.dev *.exe.xyz
       IdentitiesOnly yes
       IdentityFile ~/.ssh/id_ed25519_exe
     ```

2. **Verify the CLI is installed**:
   ```bash
   cd EXEDEV_CLI_PATH
   uv sync --quiet
   uv run exedev --help
   ```

## Instructions

- **VMs are persistent.** An exe.dev VM lives until you `exedev vm kill <name>` it. Forgotten VMs continue billing — clean up.
- **Names matter.** A VM's name becomes its public URL: `<name>.exe.xyz`. Pick names that are unique to your workflow (`<workflow_id>-<short-uuid>`). Two agents using `myvm` will collide.
- **Track the VM name in *your* context** — not in shell variables, not in a file. Multi-agent safe.
- **Login user is `exedev`**, home is `/home/exedev`. Use `--root` (sudo) for system-level operations.
- **URLs are private by default.** `https://<name>.exe.xyz/` redirects unauthenticated users to exe.dev login. To make one anonymously reachable, run `exedev share set-public <name>`. (See `Step 5` of the workflow.)
- **Use SSH, not the HTTPS API.** The `POST https://exe.dev/exec` endpoint has a 30s timeout and 64KB body cap; this CLI deliberately avoids it. Direct SSH (`ssh <vm>.exe.xyz "<cmd>"`) has neither.
- **Don't create files locally** — write them on the VM with `exedev files write … --stdin` or `exedev exec … "cat > path" --stdin`. Use `LOCAL_WORKSPACE` only when you actually need a local artifact.

### CLI overview

The `exedev` CLI has **six core command groups** plus three top-level helpers:

1. **`exedev init`** — quick VM creation (mirrors `sbx init`).
2. **`exedev vm`** — lifecycle (list, info, stat, kill, restart, rename, resize, tag, comment, snapshot).
3. **`exedev exec`** — run a command on a VM (mirrors `sbx exec`).
4. **`exedev files`** — file ops (mirrors `sbx files`; transparent SSH/SCP/RSYNC).
5. **`exedev share`** — port exposure & access control (unique-to-exe.dev surface, plus `share get-host` for ergonomic parity with `sbx sandbox get-host`).
6. **`exedev browser`** — local Playwright + CDP browser automation.

Helpers:

- **`exedev doctor`** — smoke-test the SSH-to-exe.dev pipeline.
- **`exedev whoami`** — show your account + registered SSH keys.

Get help on any command:

```bash
cd EXEDEV_CLI_PATH
uv run exedev --help                # top-level
uv run exedev <group> --help        # e.g. uv run exedev vm --help
uv run exedev <group> <verb> --help # e.g. uv run exedev files write --help
```

### The command surface

| command | notes |
|---|---|
| `exedev init --name <vm>` | The name is required and becomes the public URL. There are no auto-generated ids. |
| `exedev exec <vm> "<cmd>"` | `--cwd`, `--env`, `--root`, `--shell`, `--stdin`, `--background`, `--timeout`. |
| `exedev files write/read/edit` | `--stdin` is the right choice for anything with quoting in it. `edit` matches literal strings, never regex. |
| `exedev files upload/download` | Via `scp`, so binary-safe. |
| `exedev files upload-dir/download-dir` | rsync with a standard exclude set. **No `--max-depth`** — rsync's filter language does not express it cleanly. For depth-bounded transfer run `find -maxdepth N` over SSH and pass the list to `scp`. |
| `exedev files rm` | File-only by default; `-r` for directories. A recursive delete should have to be asked for. |
| `exedev vm list [--json]` | |
| `exedev vm info <name>` | Composes `ls --json` (identity + URL) with `stat` (metrics). |
| `exedev vm kill <name>` | Destructive, no confirmation, and the persistent disk goes too. |
| `exedev vm snapshot <src> [name]` | Whole-VM clone, disk and config. |
| `exedev vm resize <name>` | Grows CPU/RAM/disk live. |
| `exedev vm restart/rename/tag/comment` | Persistent-VM affordances. |
| `exedev share get-host <vm> --port` | The URL is deterministic: `https://<vm>.exe.xyz[:<port>]/`. Whether it *answers* depends on `share` state. |
| `exedev share set-public/set-private` | Toggle anonymous access. Private is the default. |
| `exedev browser <verb>` | Local Playwright + CDP. See `cookbook/browser.md`. |

**Not available, because the platform has no such concept:** pausing a VM,
extending a lifetime (nothing expires), and a curated template registry —
`--image` takes any container image, so build your own.

## Workflow

### Step 1: Validate environment

```bash
cd EXEDEV_CLI_PATH
uv run exedev doctor
```

If `doctor: OK`, proceed. Otherwise see the Troubleshooting section.

### Step 2: Generate workflow_id and VM name

Pick a kebab-case workflow ID; derive the VM name from it. Both agents and humans should be able to read these.

```text
workflow_id = "todo-app-20260508-7f3a"
vm_name     = workflow_id   # name == public URL: https://todo-app-20260508-7f3a.exe.xyz/
```

### Step 3: Create the VM

```bash
cd EXEDEV_CLI_PATH
uv run exedev init --name <vm_name>
# Optional: --image ubuntu:22.04 --cpu 4 --memory 8GB --disk 20GB
# Optional: --tag <tag> --env KEY=VAL --no-shelley
```

Boot is ~2s. Capture the name in your context (the CLI prints it; you chose it).

```bash
# If you'll need local file staging:
mkdir -p tmp/<workflow_id>
```

### Step 4: Operate on the VM

**Run commands** (mirrors `sbx exec`):
```bash
uv run exedev exec <vm_name> "uname -a"
uv run exedev exec <vm_name> "pip install requests" --root --timeout 120
uv run exedev exec <vm_name> "ls" --cwd /home/exedev/project
uv run exedev exec <vm_name> "echo \$FOO" --env FOO=bar --shell
```

**Files**:
```bash
# Write (use --stdin for complex content with brackets/quotes/globs)
echo 'print("hello")' | uv run exedev files write <vm_name> /home/exedev/hello.py --stdin

# Read
uv run exedev files read <vm_name> /home/exedev/hello.py

# Literal-string edit — no regex
uv run exedev files edit <vm_name> /home/exedev/config.toml --old "debug = false" --new "debug = true"

# Binary upload/download (scp under the hood)
uv run exedev files upload <vm_name> tmp/<workflow_id>/image.png /home/exedev/image.png
uv run exedev files download <vm_name> /home/exedev/output.pdf tmp/<workflow_id>/output.pdf

# Recursive transfer (rsync; excludes .git/.venv/node_modules/etc. by default)
uv run exedev files upload-dir <vm_name> ./local-project /home/exedev/project
uv run exedev files download-dir <vm_name> /home/exedev/project tmp/<workflow_id>/project
```

**Long-running servers** (use `--background`; no `--timeout 0` needed because we detach with `nohup`):
```bash
uv run exedev exec <vm_name> "python -m http.server 5173 --bind 0.0.0.0" --background --cwd /home/exedev/project
# logs land at /tmp/exedev-bg.log on the VM
```

### Step 5: Expose a frontend

Every VM gets `https://<vm>.exe.xyz/` for free — but it is **private by default** (visitors are redirected to exe.dev login).

#### 5.1: Start the server (port 5173 by convention)

```bash
uv run exedev exec <vm_name> "npm run dev -- --port 5173 --host 0.0.0.0" --background --cwd /home/exedev/project
# or: "python -m http.server 5173 --bind 0.0.0.0"
```

The server **must** bind `0.0.0.0` (not `127.0.0.1`) for the proxy to reach it.

#### 5.2: Set the proxy port and (if needed) make it public

```bash
# Tell the proxy which port to forward to (default heuristic = Dockerfile EXPOSE).
uv run exedev share port <vm_name> 5173

# Make it anonymously reachable:
uv run exedev share set-public <vm_name>

# OR: keep it private and grant specific people:
uv run exedev share add <vm_name> teammate@example.com
uv run exedev share add-link <vm_name>          # tokenized link anyone with it can use
```

#### 5.3: Get the URL

```bash
uv run exedev share get-host <vm_name>
# https://<vm_name>.exe.xyz/

uv run exedev share get-host <vm_name> --port 8080
# https://<vm_name>.exe.xyz:8080/   (alternate ports 3000-9999 stay auth-gated)
```

The URL is **deterministic** — `share get-host` composes it locally rather than asking a control plane.

#### 5.4: Verify

```bash
curl https://<vm_name>.exe.xyz/
# Or, if you set it public, validate visually:
uv run exedev browser nav https://<vm_name>.exe.xyz/
uv run exedev browser screenshot --path tmp/<workflow_id>/validation.png
```

### Step 6: Tear down (only when truly done)

```bash
uv run exedev vm kill <vm_name>
```

**This deletes the persistent disk too.** There is no undo. If you might want the state later, snapshot first:

```bash
uv run exedev vm snapshot <vm_name> <vm_name>-archive
```

## Cookbook

| Feature            | When to read                                                            | Documentation                              |
| ------------------ | ----------------------------------------------------------------------- | ------------------------------------------ |
| Browser Automation | When validating UIs, taking screenshots, or interacting with web pages  | [cookbook/browser.md](cookbook/browser.md) |
| Fleet download-all / restore | When archiving every VM locally (the pause/resume substitute — VMs bill until killed) or recreating a killed VM byte-for-byte at the same URL | [cookbook/fleet.md](cookbook/fleet.md) |

## Examples

| Example                     | When to read                                              | File                                           |
| --------------------------- | --------------------------------------------------------- | ---------------------------------------------- |
| 01 — Quickstart end-to-end  | First time using this skill; verify everything connects   | [examples/01_quickstart.md](examples/01_quickstart.md) |

## Reference

**Built-in CLI help**:
```bash
cd EXEDEV_CLI_PATH
uv run exedev --help                       # all groups
uv run exedev <group> --help               # group-level
uv run exedev <group> <verb> --help        # verb-level
```

For deeper context:
- `EXEDEV_CLI_PATH/README.md` — CLI overview and architecture.
- `ai_docs/exedev_sandbox_mounting.md` — every exe.dev fact measured on live VMs. Several obvious designs died to these measurements; do not re-derive them.

## Troubleshooting

**`doctor` fails on step 1 (`ssh exe.dev whoami`)**:
- First-time connection? Verify host-key fingerprint matches `SHA256:JJOP/lwiBGOMilfONPWZCXUrfK154cnJFXcqlsi6lPo`.
- "Permission denied (publickey)" → register your key: `cat ~/.ssh/id_ed25519.pub | ssh exe.dev ssh-key add` (you'll need a working SSH session at least once for this; do it on a machine that already has access, or follow the exe.dev signup flow).
- Wrong key being picked up? Add the SSH config stanza shown in Prerequisites.

**`exedev exec <vm> "..."` hangs**:
- The VM may still be booting. Wait 5-10s and retry; `exedev vm info <vm>` should show `status: running`.
- Long-running command? Pass `--timeout 0` (or omit `--timeout`) for unbounded execs. The 30s ceiling only applies to the HTTPS API, which this CLI doesn't use.
- **First-ever SSH to a fresh VM fails with "Host key verification failed"** — the VM's host key isn't in your `~/.ssh/known_hosts` yet. Accept it once with:
  ```bash
  ssh -o StrictHostKeyChecking=accept-new <vm>.exe.xyz "echo READY"
  ```
  After that all `exedev` commands targeting that VM will work. (We don't auto-`accept-new` inside the wrapper because it's a security-sensitive default.)

**`exedev exec --background "python -m http.server ..."` hangs the terminal**:
- This was a real bug fixed in the runner: `--background` now wraps the remote command as `( nohup CMD > /tmp/exedev-bg.log 2>&1 < /dev/null & )` so SSH closes immediately. If you see this hang on an older copy, pull the latest `src/modules/ssh_runner.py`.
- Symptom while it's broken: the server actually starts on the VM, but the local `exedev exec` call never returns and you have to Ctrl-C. The fix (`< /dev/null` to close stdin + subshell to fork) ensures SSH returns the moment the remote child is detached.
- General rule for any "start a listener and return" workflow: always pass `--background`, never run `python -m http.server` etc. without it from inside `exedev exec` — the SSH session would stay alive for the lifetime of the server.

**`https://<vm>.exe.xyz/` returns 502 / "no upstream"**:
- Server not bound to `0.0.0.0`? Bind to `0.0.0.0`, not `127.0.0.1` or `localhost`.
- Wrong port? Check `exedev share show <vm>` for the current proxy target; set it with `exedev share port <vm> <p>`.

**`https://<vm>.exe.xyz/` redirects me to exe.dev login**:
- That's the default (private mode). Run `exedev share set-public <vm>` for anonymous access, or `share add <email>` to grant a specific user.

**`exedev files edit` fails with "String not found"**:
- The `--old` string is matched literally. Check whitespace, line endings, quoting. Use `exedev files read <vm> <path> | grep -F '...'` to confirm the string is actually there.

**`exedev browser` issues**:
- See `cookbook/browser.md`.

**A VM I don't recognize shows up in `exedev vm list`**:
- exe.dev VMs persist forever until `vm kill`. You may have created it from another agent or session. Check `comment` and `tags`. If it's truly unwanted: `exedev vm kill <name>`.

## What this skill explicitly does NOT do

These are absent on purpose — either the platform has no such concept, or the
wrapper made a deliberate safety call:

- **`pause` / `extend-lifetime`** — exe.dev VMs are persistent. There is no expiry to extend, and pause-to-save-money is not a feature.
- **Curated template registry** — exe.dev `--image` accepts any container image. Build your own and reference it.
- **`POST /exec` HTTPS API** — capped at 30s and 64KB. We always use direct SSH, which has neither limit. If you specifically need HTTPS-API access (signed `exe0` tokens etc.), consult the exe.dev docs and call out directly with `curl`.
- **Automatic teardown** — you must `exedev vm kill <name>` to stop billing. Set yourself a reminder.
- **Shell-feature gating** — SSH runs remote commands through the user's login shell, so pipes and globs work whether or not you pass `--shell`.
- **`--max-depth` on `files upload-dir` / `files download-dir`** — rsync's filter language doesn't express it cleanly, and the simple translations have edge cases. If you need depth-bounded transfer, do `find -maxdepth N` over SSH first and pass the file list to `scp`. The dir-transfer parity status reflects this in the mapping table above.

What it does add, beyond running commands: `vm snapshot` (whole-VM clone), `vm resize` (live), `vm restart/rename/tag/comment`, and `share set-public/set-private`.

## Phase recipes (just)

Sandbox operations split one-per-phase, so each runs alone or chained.

```
just/
  mount.just
  lifecycle/  create.just fill.just setup.just execute.just observe.just teardown.just
  manage/     list.just harvest.just reap.just
  run/        mod.just
```

They live in the standalone **sbx** repo, whose root justfile wires them up:

```just
import 'just/mount.just'            # the entry point, so it is `sbx mount`, not `sbx mount mount`
mod lifecycle 'just/lifecycle/mod.just'
mod manage 'just/manage/mod.just'
mod run 'just/run/mod.just'
```

Run one phase (`sbx lifecycle setup my-run`) or the chain (`sbx mount my-run`). Always through
`bin/sbx`: it points `just` at the install dir while leaving the working directory on the repo you
are mounting, and exports `SBX_TARGET`, which every recipe body `cd`s to.

- `import` flattens recipe names into the root namespace — that is why `mount` is imported and the
  groups are `mod`s, so you get `sbx mount` but `sbx lifecycle create`.
- Imported files inherit the root justfile's settings, including `shell`; `mod`s inherit nothing and
  restate their own. sbx's root sets no `shell` at all, so nothing here depends on zsh — but a repo
  whose root sets `shell := ["zsh", "-ic"]` still has that apply to its own imported recipes.
- These recipes are **host-only orchestration** — they need the exe.dev account and
  `OPENROUTER_PROVISIONING_KEY`, neither of which ever reaches a VM. That absence, not the absence
  of the files, is why a sandbox cannot mount sandboxes.
