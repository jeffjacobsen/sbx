# just/lifecycle/setup.just — PHASE 3 of 6: SETUP.
#
# Imported by the root justfile (not a module), so it shares the root's scope
# and settings. No `set` lines here on purpose: duplicating `dotenv-load` or
# `positional-arguments` is a hard error at parse time.
#
# What this phase does: push and run the base provisioner inside the sandbox,
# wait for its sentinel, then run the health gate. Nothing here creates or
# destroys a VM. On failure it prints how to get into the box and exits
# non-zero, because a gate that auto-destroys throws away the evidence.
#
# THE GATE IS ONE BUILTIN PLUS WHATEVER THE MANIFEST DECLARES. Assertion A —
# working tree clean, HEAD matching the recorded sha — is a claim about the
# MOUNT, so it lives here and always runs. The rest are claims about the
# PAYLOAD, so they live in the target repo's `health:` block and travel with it.
# A repo that declares none still gates on A.
#
# The OpenRouter PROVISIONING key never appears in this file. A gate that spends
# money uses the disposable RUNTIME key — which already lives on the VM in
# app/.env (written in FILL). That is why every declared assertion executes
# inside the sandbox: the key never has to travel, and the gate proves the
# sandbox's own egress works rather than the host's.

# CONFIG is forwarded to every `script` health assertion as $1 — for this repo
# that is which roster to ping. It has to be an ARGUMENT: the assertion used to
# read $SSSF_CONFIG out of the remote environment, but `ssh host 'cmd'` carries
# no environment at all, so that read always fell through to the default. On a
# fan-out where each arm runs a different roster, every arm was gated against
# models it would never call — the gate passed and told you nothing. Pass the
# same path here that you pass to `sbx lifecycle execute`.

# phase 3: provision the sandbox, then gate it (never destroys the VM). CONFIG reaches every script assertion as $1
setup RUN_ID CONFIG="":
    #!/usr/bin/env bash
    set -euo pipefail
    # `just --working-directory` reaches ROOT recipes but NOT module recipes,
    # which resolve their own directory instead — measured, and a silent way to
    # mount the wrong repo. The shim exports the invocation directory and every
    # recipe returns to it, so "which repo" never depends on just's scoping.
    cd "${SBX_TARGET:?run sbx via bin/sbx, which exports it}"

    RR="{{justfile_directory()}}/lib/run_record.py"
    MF="{{justfile_directory()}}/lib/manifest.py"
    VM=$("$RR" get {{RUN_ID}} vm_name)
    SHA=$("$RR" get {{RUN_ID}} commit_sha)

    # The provisioner is PUSHED, not required in the clone. SETUP used to run
    # `bash app/sandbox_mount/guest/provision.sh` — a host phase depending on a
    # file inside the cloned repo, which is why this system could only mount
    # repos that already carried it. Now the host scp's a base provisioner it
    # owns; the manifest says only which tools to install and which optional
    # project hook to run after. Both may be empty: a repo that declares neither
    # still mounts.
    BASE="{{justfile_directory()}}/lib/base_provision.sh"
    [ -f "$BASE" ] || { echo "[setup] missing ${BASE} — the orchestrator's own provisioner" >&2; exit 1; }
    TOOLCHAIN=$("$MF" toolchain)
    PROV=$("$MF" get provision.script)

    # run_record prints an empty line for an unset field, so emptiness is the
    # real check — a missing vm_name means CREATE never finished.
    [ -n "$VM" ]  || { echo "[setup] run record {{RUN_ID}} has no vm_name — run: sbx lifecycle create {{RUN_ID}}" >&2; exit 1; }
    [ -n "$SHA" ] || { echo "[setup] run record {{RUN_ID}} has no commit_sha — run: sbx lifecycle fill {{RUN_ID}}" >&2; exit 1; }

    HOST="$VM.exe.xyz"
    # ConnectTimeout only: every *.exe.xyz shares one host key and the wildcard
    # known_hosts entry is already installed, so ssh is non-interactive already.
    SSH=(ssh -o ConnectTimeout=15 "$HOST")

    echo "[setup] run {{RUN_ID}}  vm ${VM}  sha ${SHA}"

    # Every failure below routes through here: report, hand over the debug
    # command, exit non-zero. NEVER destroy — teardown stays an explicit choice.
    gate_fail() {
      echo ""
      echo "[setup] FAILED: $*" >&2
      echo "[setup] the VM is still running on purpose — the evidence is on the box:" >&2
      echo "[setup]   ssh ${HOST}" >&2
      echo "[setup]   ssh ${HOST} 'cd app && git status --porcelain'" >&2
      echo "[setup]   ssh ${HOST} 'pi --list-models'" >&2
      echo "[setup] tear it down only when you are done: sbx lifecycle teardown {{RUN_ID}}" >&2
      exit 1
    }

    # ── 1. provision ─────────────────────────────────────────────────────────
    # Clear the sentinel first: re-running setup on the same VM would otherwise
    # find the PREVIOUS run's sentinel and declare victory before provision ran.
    echo "[setup] 1/3 provisioning (toolchain: ${TOOLCHAIN:-none}, hook: ${PROV:-none})"
    "${SSH[@]}" 'rm -f /tmp/PROVISION_READY' < /dev/null \
      || gate_fail "cannot reach ${HOST} over ssh"
    # Pushed every run, never cached: the base provisioner is the orchestrator's
    # code, so the box must run THIS version of it, not whatever a previous mount
    # or a golden-VM snapshot left in /tmp.
    scp -q -o ConnectTimeout=15 "$BASE" "${HOST}:/tmp/sbx_base_provision.sh" < /dev/null \
      || gate_fail "could not copy ${BASE} to ${HOST}"
    # < /dev/null so ssh does not swallow this script's stdin; output streams live.
    # Both arguments are quoted even when empty: an unquoted empty TOOLCHAIN would
    # shift the hook into its place and the base would try to install it.
    "${SSH[@]}" "bash /tmp/sbx_base_provision.sh \"\$HOME/app\" '${TOOLCHAIN}' '${PROV}'" < /dev/null \
      || gate_fail "provisioning exited non-zero (its last '── step ──' line names the stage)"

    # ── 2. sentinel ──────────────────────────────────────────────────────────
    # the base provisioner touches /tmp/PROVISION_READY as its literal last line
    # — after the project hook has returned, so on
    # this synchronous path the file is already there and the loop exits on the
    # first probe. The poll is bounded anyway: it is the only completion signal
    # that stays correct if provision is ever backgrounded, and an unbounded
    # wait on a dead box is a hang, not a failure.
    echo "[setup] 2/3 waiting for /tmp/PROVISION_READY (max 60s)"
    ready=0
    for _ in $(seq 1 30); do
      if "${SSH[@]}" 'test -f /tmp/PROVISION_READY' < /dev/null; then ready=1; break; fi
      sleep 2
    done
    [ "$ready" -eq 1 ] || gate_fail "sentinel /tmp/PROVISION_READY never appeared"
    echo "[setup]     sentinel present"

    # ── 3. the gate ──────────────────────────────────────────────────────────
    N_HEALTH=$("$MF" health | grep -c . || true)
    echo "[setup] 3/3 health gate (A builtin + ${N_HEALTH} declared)"

    # A — git integrity. Content, not existence: an unsynced golden-VM clone
    # produced 5,641 zero-byte files and reported success, and truncation shows
    # up as ' M path'. Expected-vs-actual SHA is compared by prefix so a short
    # commit_sha in the record still matches a full HEAD.
    #
    # The tree must be CLEAN. Nothing legitimately dirties it: the sandbox
    # clones the repo and provisions around it, so any porcelain line at all
    # means something wrote where it should not have.
    echo "[gate] A git integrity"
    if "${SSH[@]}" 'bash -s' "$SHA" <<'REMOTE_A'; then
    set -uo pipefail
    cd "$HOME/app" || { echo "   no ~/app on this VM — FILL never ran"; exit 1; }
    want="${1:-}"
    head="$(git rev-parse HEAD)" || { echo "   git rev-parse failed — .git is damaged"; exit 1; }
    echo "   HEAD     ${head}"
    echo "   expected ${want}"
    case "$head" in
      "$want"*) ;;
      *) echo "   HEAD does not match the recorded commit_sha"; exit 1 ;;
    esac

    porcelain="$(git status --porcelain)"
    if [ -n "$porcelain" ]; then
      echo "   unexpected working-tree changes (the tree must be clean):"
      printf '%s\n' "$porcelain" | sed 's/^/     /'
      exit 1
    fi
    echo "   working tree clean"
    REMOTE_A
      echo "[gate] A PASS  git integrity"
    else
      gate_fail "assertion A — git integrity"
    fi

    # ── B onward: the PROJECT's assertions, declared in sandbox.yaml ─────────
    # These used to be four hardcoded blocks here. They are claims about the
    # payload ("an SSSF factory driven by pi over OpenRouter"), not about
    # sandboxes, so they belong with the repo that makes them. A repo that
    # declares no health block still gates on A above.
    #
    # < /dev/null on every ssh in this loop is load-bearing: ssh reads the
    # caller's stdin, and the caller's stdin IS the assertion list. Without it
    # the first ssh eats the rest and the loop runs exactly once.
    HEALTH=$("$MF" health)
    if [ -z "$HEALTH" ]; then
      echo "[gate] sandbox.yaml declares no health assertions — only A ran"
    else
      while IFS=$'\t' read -r H_NAME H_KIND H_VALUE H_EXPECT H_REJECT; do
        [ -n "$H_NAME" ] || continue
        echo "[gate] ${H_NAME}"
        if [ "$H_KIND" = "script" ]; then
          # The script's exit code is the verdict, and it is run in the clone so
          # a repo-relative path is all the manifest has to carry. CONFIG goes in
          # as a positional because `ssh host cmd` carries no environment.
          if "${SSH[@]}" "cd \$HOME/app && bash ${H_VALUE} $(printf '%q' "{{ CONFIG }}")" < /dev/null; then
            echo "[gate] PASS  ${H_NAME}"
          else
            rc=$?
            # Exit codes a script may use to say WHICH of its claims failed; the
            # per-line output above already named the model or the reading.
            case "$rc" in
              2) gate_fail "${H_NAME} — a roster model did not answer (exit 2)" ;;
              3) gate_fail "${H_NAME} — no reported cost and/or no rate table (exit 3)" ;;
              *) gate_fail "${H_NAME} — ${H_VALUE} exited ${rc}" ;;
            esac
          fi
        else
          # A cmd passes only if it exits 0 AND prints something AND does not
          # match reject_stdout. Emptiness is a failure on purpose: an assertion
          # that proves the payload healthy has something to say about it.
          OUT=$("${SSH[@]}" "cd \$HOME/app && ${H_VALUE}" < /dev/null 2>&1) || \
            gate_fail "${H_NAME} — \`${H_VALUE}\` exited non-zero: ${OUT}"
          [ -n "$OUT" ] || gate_fail "${H_NAME} — \`${H_VALUE}\` printed nothing"
          if [ "$H_REJECT" != "-" ] && printf '%s' "$OUT" | grep -qiF -- "$H_REJECT"; then
            gate_fail "${H_NAME} — output contains the rejected string: ${H_REJECT}"
          fi
          if [ "$H_EXPECT" != "-" ] && ! printf '%s' "$OUT" | grep -qiF -- "$H_EXPECT"; then
            gate_fail "${H_NAME} — output does not contain: ${H_EXPECT}"
          fi
          echo "   $(printf '%s\n' "$OUT" | grep -c . || true) line(s) of output"
          echo "[gate] PASS  ${H_NAME}"
        fi
      done <<< "$HEALTH"
    fi

    echo ""
    echo "[setup] GATE PASSED — {{RUN_ID}} is healthy on ${HOST}"
    echo "[setup] next: sbx lifecycle observe {{RUN_ID}}"
