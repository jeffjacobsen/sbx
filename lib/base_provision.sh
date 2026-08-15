#!/usr/bin/env bash
# base_provision.sh — the provisioner the ORCHESTRATOR owns and PUSHES.
#
#   scp base_provision.sh <vm>:/tmp/sbx_base_provision.sh
#   ssh <vm> 'bash /tmp/sbx_base_provision.sh <app-dir> <toolchain-csv> [hook]'
#
# WHY THIS EXISTS. SETUP used to run `bash app/sandbox_mount/guest/provision.sh`
# — a host phase depending on a file inside the cloned repo. That was the
# tightest coupling in the system and the reason this repo could only ever mount
# itself: a target repo had to already carry our provisioner to be mountable.
# Inverting it means a repo that has never heard of this system mounts with zero
# files added, and a repo that needs `uv sync` or `cargo build` declares a hook.
#
# The measured traps below now live in ONE place, under the orchestrator's
# version control, instead of being copy-pasted into every project that wants to
# be mounted — which is how they rot.
#
# This file is scp'd, never cloned. It must therefore assume NOTHING about the
# repo: not a layout, not a language, not even that the clone is a git checkout.
#
# NEVER add apt here. Measured from the dal region: ~148 kB/s and ~35s per
# package. bun and just come from their own CDNs in ~1s combined.
set -euo pipefail

STEP="startup"
# shellcheck disable=SC2154   # rc is assigned by the trap body itself
trap 'rc=$?; echo "" >&2; echo "[base] FAILED during: ${STEP} (line ${LINENO}, exit ${rc})" >&2; exit "$rc"' ERR

step() { STEP="$1"; echo ""; echo "── $1 ──────────────────────────────────"; }
say()  { echo "   $*"; }

APP_DIR="${1:-}"
TOOLCHAIN="${2:-}"          # comma-separated; empty means "install nothing"
HOOK="${3:-}"               # repo-relative path; empty means "no project hook"

[ -n "$APP_DIR" ] || { echo "[base] usage: base_provision.sh <app-dir> <toolchain-csv> [hook]" >&2; exit 2; }
[ -d "$APP_DIR" ] || { echo "[base] no clone at ${APP_DIR} — FILL never ran" >&2; exit 1; }
cd "$APP_DIR"

step "1/4 clone"
say "$(pwd)"
say "commit $(git rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout')"

# ── 2. toolchain ─────────────────────────────────────────────────────────────
# Every installer is skip-if-present, so re-running a mount is cheap and safe.
# An unknown tool is a HARD ERROR rather than a silent skip: a repo that asked
# for `cargo` and got a green provision would fail much later, inside a hook or
# a service, where the cause is no longer visible. The supported set is small on
# purpose — it is the set whose install path has actually been measured here.
step "2/4 toolchain"

install_bun() {
  if command -v bun >/dev/null 2>&1; then say "bun already installed: $(bun --version)"; return; fi
  curl -fsSL https://bun.sh/install | bash
  say "bun installed"
}

install_just() {
  # Anything that calls just later needs: just --shell bash --shell-arg -c
  # A repo's root justfile may set `zsh -ic`, and zsh is not in the exeuntu image.
  if command -v just >/dev/null 2>&1; then say "just already installed: $(just --version)"; return; fi
  curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
    | sudo bash -s -- --to /usr/local/bin
  say "just installed"
}

install_uv() {
  if command -v uv >/dev/null 2>&1; then say "uv already installed: $(uv --version)"; return; fi
  curl -LsSf https://astral.sh/uv/install.sh | sh
  [ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"
  say "uv installed"
}

if [ -z "$TOOLCHAIN" ]; then
  say "none declared — using only what the image ships"
else
  IFS=',' read -r -a TOOLS <<< "$TOOLCHAIN"
  for tool in "${TOOLS[@]}"; do
    tool="$(printf '%s' "$tool" | tr -d '[:space:]')"
    [ -n "$tool" ] || continue
    case "$tool" in
      bun)  install_bun  ;;
      just) install_just ;;
      uv)   install_uv   ;;
      *)
        echo "[base] unsupported toolchain entry: ${tool}" >&2
        echo "[base] supported: bun, just, uv. Anything else belongs in a project hook" >&2
        echo "[base] (provision.script) — and never in apt, which is ~35s per package here." >&2
        exit 1 ;;
    esac
  done
fi

# ── 3. put bun where every FUTURE ssh session will find it ───────────────────
# Each `ssh vm cmd` is a fresh non-interactive shell that reads no rc file, so
# the installer's rc edit is invisible and a PATH export here dies with this
# script. OBSERVE hit exactly that: it started a service with nohup and got
# `bun: No such file or directory` seconds after provision had used bun
# successfully. just installs to /usr/local/bin already, which is why it never
# had this problem; uv's ~/.local/bin is on the default PATH.
if [ -d "$HOME/.bun/bin" ]; then
  export PATH="$HOME/.bun/bin:$PATH"
fi
if [ -x "$HOME/.bun/bin/bun" ] && [ ! -e /usr/local/bin/bun ]; then
  sudo ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun
  sudo ln -sf "$HOME/.bun/bin/bunx" /usr/local/bin/bunx 2>/dev/null || true
  say "bun linked into /usr/local/bin for non-interactive ssh"
fi

# ── 4. the project hook ──────────────────────────────────────────────────────
# Everything repo-specific lives here: dependency installs, asset builds, schema
# initialisation. Optional by design — a repo with none still mounts, which is
# the whole point of pushing this file instead of requiring one in the clone.
step "3/4 project hook"
if [ -z "$HOOK" ]; then
  say "none declared — skipping"
elif [ ! -f "$HOOK" ]; then
  # Loud. The manifest named a file the clone does not have, which usually means
  # the hook was renamed without updating sandbox.yaml.
  echo "[base] provision.script ${HOOK} is not in the clone" >&2
  exit 1
else
  say "running ${HOOK}"
  echo ""
  bash "$HOOK"
fi

step "4/4 summary"
say "clone   $(pwd) @ $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
for t in bun just uv python3; do
  if command -v "$t" >/dev/null 2>&1; then
    say "$(printf '%-7s' "$t") $("$t" --version 2>/dev/null | head -1)"
  fi
done
echo ""
echo "[base] READY"

# The caller polls for this file — there is no other reliable completion signal.
# It must stay the LAST line, and the base must be the ONLY thing that writes it:
# a hook that touched it would report the sandbox ready while the base still had
# work to do after the hook returned.
touch /tmp/PROVISION_READY
