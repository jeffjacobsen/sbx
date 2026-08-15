# exedev CLI

A streamlined command-line interface for managing **exe.dev persistent VMs**.

## Install

```bash
cd .claude/skills/sandbox-exe-dev/exedev_cli
uv sync
uv run exedev --help
```

Prerequisites:
- An exe.dev account with an SSH public key registered (`ssh exe.dev whoami` works).
- `ssh`, `scp`, `rsync` on your `$PATH` (every Linux/macOS host).
- Optional: `playwright` for the `browser` group (installed via `uv sync` dev deps).

## Smoke-test

```bash
uv run exedev doctor
```

If `doctor` is green, every other command should work.

## Quick reference

```text
exedev init     --name <vm>                       # create a VM
exedev exec     <vm> "<cmd>" [--cwd] [--env] [--root] [--shell] [--background] [--timeout]
exedev files    ls|read|write|edit|upload|download|upload-dir|download-dir|exists|info|mkdir|mv|rm
exedev vm       list|info|stat|kill|restart|rename|resize|tag|comment|snapshot
exedev share    show|port|set-public|set-private|add|remove|add-link|remove-link|get-host
exedev browser  init|start|status|nav|eval|screenshot|click|type|press|scroll|a11y|dom|cookies|pick|close
exedev whoami
exedev doctor
```

## Command groups

| group | verbs |
|---|---|
| `exedev init` | create a VM — a name is required, there are no auto-generated ids |
| `exedev exec` | run a command on a VM (`--cwd`, `--env`, `--root`) |
| `exedev files` | `write` / `read` / `edit` / `rm` / `upload-dir` / `download-dir`, over SSH, SCP and rsync |
| `exedev vm` | `list` / `info` / `kill` / `snapshot` / `resize` / `restart` / `rename` / `tag` |
| `exedev share` | `port` / `set-public` / `get-host` — a VM's URL is private until you say otherwise |
| `exedev browser` | `init` / `start` / `nav` / `eval` / `screenshot` / `close`, local Playwright + CDP |

exe.dev VMs are **persistent**: they live until `exedev vm kill <name>`, and a
forgotten one keeps billing. There is no expiry and nothing to extend.

## Architecture

Every command resolves to one of three SSH idioms:

1. **Control plane** — `ssh exe.dev <verb> [--json]` → handled by `modules.ssh_runner.control_plane`.
2. **Data plane** — `ssh <vm>.exe.xyz "<cmd>"` → `modules.ssh_runner.vm_exec` (with `--cwd`, `--env`, `sudo`, `bash -c`, `nohup`, `--stdin` translation).
3. **File transfer** — `scp` (single file) or `rsync -avz --exclude=...` (directory) → `vm_scp` / `vm_rsync`.

We deliberately **never** use the HTTPS API (`POST https://exe.dev/exec`) — it has a 30s ceiling and a 64KB body cap. SSH has neither.

## Multi-agent safety

exe.dev VMs are named rather than carrying an opaque generated id. Pick names like `<workflow-id>-<short-uuid>` (e.g. `todo-app-20260508-7f3a`) so concurrent agents don't collide. Capture the name in *your* context, not in shell variables.

## See also

- `../SKILL.md` — the parent skill with workflow/troubleshooting/cookbook pointers.
- `../cookbook/browser.md` — browser automation usage.
- `ai_docs/exedev_sandbox_mounting.md` (repo root) — exe.dev facts measured on live VMs.
