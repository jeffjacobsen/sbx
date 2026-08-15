# Phase 6 — TEARDOWN. Host only, and only when we decide.
#
# IMPORTED into the root justfile (not a module): no `set` lines here, and the
# root's `set dotenv-load` is what puts OPENROUTER_PROVISIONING_KEY in scope.
# No file-level variables either — six imports share one scope, so a duplicate
# name across phase files is a hard error. Everything is a bash local instead.
#
# Order is load-bearing: spend captured -> artifacts out -> commits harvested ->
# key revoked -> VM destroyed. A crash between revoke and destroy leaves a dead
# key and a live VM (visible, cheap). The reverse leaves a live key nobody can
# find (invisible, spends). This is the ONLY file allowed to destroy a VM.
#
# Everything that READS the box runs before anything that destroys it, and the
# harvest failing ABORTS the whole teardown: destroying a VM whose commits were
# never pulled is the one irreversible mistake available in this file.
#
# IDEMPOTENT by construction: every step is individually guarded, because a run
# can die anywhere — VM but no key, key but no VM, a record with neither. A
# missing piece is the normal path, not an error.

# tear down one run: spend -> artifacts -> harvest -> revoke -> destroy -> close -> gate
teardown RUN_ID *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    # `just --working-directory` reaches ROOT recipes but NOT module recipes,
    # which resolve their own directory instead — measured, and a silent way to
    # mount the wrong repo. The shim exports the invocation directory and every
    # recipe returns to it, so "which repo" never depends on just's scoping.
    cd "${SBX_TARGET:?run sbx via bin/sbx, which exports it}"

    RR="{{justfile_directory()}}/lib/run_record.py"
    CRED="{{justfile_directory()}}/lib/credential.py"
    # Read ONCE, in step 2, and never trusted to succeed — see the note there.
    # Nothing else on this path may grow a dependency on it.
    MF="{{justfile_directory()}}/lib/manifest.py"
    RUN_ID="{{ RUN_ID }}"
    RUNS=$("$RR" dir "$RUN_ID")
    KEY_FILE="$RUNS/$RUN_ID.key"
    ART="$RUNS/$RUN_ID-artifacts"
    API="https://openrouter.ai/api/v1"

    # Through a variable, not straight into `for ... in`: interpolating an empty
    # variadic into the list is a syntax error, via a variable it is zero iterations.
    RAW_FLAGS="{{ FLAGS }}"
    HARVEST=1
    for a in $RAW_FLAGS; do
        case "$a" in
            --no-harvest) HARVEST=0 ;;
            *) echo "teardown: unknown flag $a (only --no-harvest)"; exit 2 ;;
        esac
    done
    # All *.exe.xyz share one host key and a wildcard known_hosts entry is already
    # installed, so no StrictHostKeyChecking games. BatchMode so a teardown never
    # sits at a password prompt; timeouts so it never hangs on a dead VM.
    SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)

    echo "── teardown $RUN_ID"

    # The record is the only handle on the key. Without it there is nothing to
    # revoke and nothing to close, so this is the one hard prerequisite.
    "$RR" get "$RUN_ID" > /dev/null || { echo "!! no run record for $RUN_ID — nothing to tear down"; exit 1; }
    VM=$("$RR" get "$RUN_ID" vm_name)
    KEY_HASH=$("$RR" get "$RUN_ID" key_hash)
    CLOSED=$("$RR" get "$RUN_ID" closed_at)
    [ -n "$CLOSED" ] && echo "   (record already closed at $CLOSED — re-running the remaining steps)"

    # ── does the VM still exist? -------------------------------------------------
    # Ask the control plane rather than probing ssh: authoritative, and the same
    # answer `reap` uses. Verified shape: {"vms":[{"vm_name":"...",...}]}
    VM_ALIVE=0
    if [ -n "$VM" ]; then
        VM_LIST=$(ssh "${SSH_OPTS[@]}" exe.dev ls --json 2>/dev/null || echo '{"vms":[]}')
        if printf '%s' "$VM_LIST" | VM="$VM" python3 -c \
            'import json,os,sys; sys.exit(0 if os.environ["VM"] in {v.get("vm_name") for v in json.load(sys.stdin).get("vms",[])} else 1)'
        then
            VM_ALIVE=1
        fi
    fi
    if [ "$VM_ALIVE" = 1 ]; then echo "   vm:  $VM (running)"; else echo "   vm:  ${VM:-<none>} (gone or never created)"; fi

    # ── 1. spend, BEFORE the key dies -------------------------------------------
    # This is what makes best-of-N comparable: same prompt, N models, cost beside
    # result. Read it now — after DELETE the number is unrecoverable.
    # NOTE: the runtime key is a SANDBOX secret; the provisioning key never leaves
    # this host and is never used for the per-key usage read.
    SPEND=""
    if [ -s "$KEY_FILE" ]; then
        RUNTIME_KEY=$(cat "$KEY_FILE")
        # The provider reads spend from the LIST — the same source revocation is
        # gated on, so the number and the verdict can never disagree. Read it
        # NOW: after the delete it is unrecoverable.
        SPEND=$("$CRED" spend "$KEY_HASH" 2>/dev/null || true)
    fi
    if [ -n "$SPEND" ]; then
        "$RR" set "$RUN_ID" spend="$SPEND"
        echo "   spend: \$$SPEND recorded"
    elif [ -z "$KEY_HASH" ]; then
        echo "   spend: n/a — no key was ever minted for this run"
    else
        echo "   spend: unavailable (key file gone, hash no longer listed) — leaving record as-is"
    fi

    # ── 2. artifacts ------------------------------------------------------------
    # WHAT to pull is the target repo's answer, declared as `artifacts:` in its
    # manifest. This list was hardcoded as `specs app_docs adws/adw_data/sssf.db
    # run.log` — three SSSF paths in a tool that mounts any repo, so every other
    # payload silently harvested nothing but the log.
    #
    # Asked for OPTIONALLY, and this is the one rule not to relax: teardown must
    # work from the run record alone, or a manifest that stopped parsing would
    # strand a live key. Every failure here — no manifest, bad YAML, uv missing,
    # a hang — falls back to run.log and proceeds to the revoke. Losing a log is
    # recoverable; a key that keeps spending is not.
    ARTS=$(timeout 10 "$MF" artifacts 2>/dev/null || true)
    [ -n "$ARTS" ] || ARTS="run.log"
    if [ "$VM_ALIVE" = 1 ]; then
        mkdir -p "$ART"
        TAR_TMP=$(mktemp -t "sbx-$RUN_ID")
        # One round trip, and `ls -d` filters to what actually exists so a run that
        # died before writing app_docs/ is not an error.
        # The ssh exit status is captured separately from tar emptiness on purpose:
        # a connection that never landed produces an empty tar too, and reporting
        # that as "none found" is silent data loss immediately before a destroy.
        #
        # $ARTS is spliced in unquoted ON PURPOSE — the remote `ls -d` needs it as
        # separate words. Entries are validated to hold no whitespace, so this
        # cannot silently become one path or three.
        ART_RC=0
        ssh "${SSH_OPTS[@]}" "$VM".exe.xyz \
            'cd app 2>/dev/null || exit 0; P=$(ls -d '"$ARTS"' 2>/dev/null); [ -z "$P" ] && exit 0; tar cf - $P' \
            > "$TAR_TMP" 2> "$TAR_TMP.err" || ART_RC=$?
        if [ "$ART_RC" -ne 0 ]; then
            echo "   artifacts: COULD NOT READ THE VM (ssh exit $ART_RC) — nothing harvested" >&2
            [ -s "$TAR_TMP.err" ] && sed 's/^/   artifacts: /' "$TAR_TMP.err" >&2
            echo "   artifacts: the vm is about to be destroyed; Ctrl-C now if it held work" >&2
            rmdir "$ART" 2> /dev/null || true
        elif [ -s "$TAR_TMP" ]; then
            tar xf "$TAR_TMP" -C "$ART"
            echo "   artifacts -> $ART"
        else
            echo "   artifacts: none found on the vm"
            rmdir "$ART" 2> /dev/null || true   # do not leave an empty dir implying we pulled something
        fi
        rm -f "$TAR_TMP" "$TAR_TMP.err"
    else
        echo "   artifacts: skipped (no vm)"
    fi

    # ── 3. harvest the commits --------------------------------------------------
    # File copies LOSE history, and SSSF commits plan, code and docs as separate
    # commits — the shape of the run is in the commit graph, not the files. The
    # bundling lives in harvest.just so it can also be run on its own, at any time,
    # without committing to a teardown. Default ON here so nobody loses a run's work
    # by forgetting; a failure STOPS before revoke and destroy.
    if [ "$HARVEST" != 1 ]; then
        echo "   harvest: skipped (--no-harvest)"
    elif [ "$VM_ALIVE" = 1 ]; then
        # This justfile, explicitly — same reason mount does it. `sbx` may not be
        # on PATH, and a bare `just` would resolve against the target repo.
        # SBX_TARGET is passed explicitly, not inherited: a nested `just` did not
        # carry it through, and the child then had no idea which repo it was in.
        SBX_TARGET="$PWD" just --justfile "{{justfile_directory()}}/justfile" manage harvest "$RUN_ID" || {
            echo "!! harvest FAILED — stopping before revoke and destroy. The VM is left alive."
            echo "!! diagnose, then re-run:      sbx lifecycle teardown $RUN_ID"
            echo "!! or skip it deliberately:    sbx lifecycle teardown $RUN_ID --no-harvest"
            exit 1
        }
    else
        echo "   harvest: skipped (no vm)"
    fi

    # ── 4. revoke the key -------------------------------------------------------
    if [ -z "$KEY_HASH" ]; then
        echo "   key: none minted for this run — nothing to revoke"
    elif [ -z "${OPENROUTER_PROVISIONING_KEY:-}" ]; then
        echo "!! key_hash $KEY_HASH is live but OPENROUTER_PROVISIONING_KEY is unset — cannot revoke."
        echo "!! set it in .env and re-run: a live key keeps spending. VM left alone."
        exit 1
    else
        # revoke-managed re-asserts the sbx- prefix AT THE POINT OF DELETION and
        # gates the result against the LIST, because a dead key still answers
        # 200 from the single-key GET. Both rules live in the provider so this
        # phase cannot skip one.
        RESULT=$("$CRED" revoke-managed "sbx-$RUN_ID" "$KEY_HASH") || {
            echo "!! revoke failed for $KEY_HASH — key may still be live. VM left alone."; exit 1; }
        case "$RESULT" in
            ok)           echo "   key: revoked ($KEY_HASH)" ;;
            already_gone) echo "   key: already gone ($KEY_HASH) — idempotent re-run" ;;
        esac
    fi

    # ── 5. destroy the vm -------------------------------------------------------
    if [ "$VM_ALIVE" = 1 ]; then
        ssh "${SSH_OPTS[@]}" exe.dev rm "$VM" > /dev/null
        echo "   vm: destroyed ($VM)"
    else
        echo "   vm: nothing to destroy"
    fi

    # ── 6. close the record, shred the key file ---------------------------------
    "$RR" close "$RUN_ID"
    if [ -e "$KEY_FILE" ]; then
        # shred where available, `rm -P` on macOS; -f last so a re-run never fails
        # on an already-removed file.
        if command -v shred > /dev/null 2>&1; then shred -u "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"
        else rm -Pf "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"; fi
        echo "   key file shredded"
    fi
    echo "   record closed"

    # ── 7. GATE: the key is ABSENT from the key LIST ----------------------------
    # MEASURED: right after a successful DELETE, GET /api/v1/key still returns 200
    # for the dead key. The LIST is the authoritative view. Never gate on /key.
    if [ -z "$KEY_HASH" ]; then
        echo "✓ teardown complete for $RUN_ID (no key was ever minted)"
        exit 0
    fi
    LIST=$(curl -sS --max-time 30 "$API/keys" -H "Authorization: Bearer $OPENROUTER_PROVISIONING_KEY") \
        || { echo "!! gate: could not read $API/keys — revocation UNVERIFIED"; exit 1; }
    if printf '%s' "$LIST" | KH="$KEY_HASH" python3 -c \
        'import json,os,sys; sys.exit(1 if os.environ["KH"] in {k.get("hash") for k in json.load(sys.stdin).get("data",[])} else 0)'
    then
        echo "✓ gate: key absent from $API/keys"
        echo "✓ teardown complete for $RUN_ID"
    else
        echo "!! gate FAILED: $KEY_HASH is still listed at $API/keys. The key is LIVE."
        echo "!! revoke it by hand: curl -X DELETE $API/keys/$KEY_HASH -H 'Authorization: Bearer \$OPENROUTER_PROVISIONING_KEY'"
        exit 1
    fi
