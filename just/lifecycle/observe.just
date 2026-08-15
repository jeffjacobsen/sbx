# ─── just/lifecycle/observe.just — PHASE 5 · OBSERVE ────────────────────────────
# Make a mounted sandbox watchable from outside without reaching in: start the
# app (4501) and the trace UI (4600), retarget the HTTPS proxy, print URLs.
#
# IMPORTED by the root justfile, not a module: no `set` lines here (the root
# already owns `set dotenv-load` / `set positional-arguments`, and a duplicate
# setting is a hard error), and the root's variable scope is shared.
#
# HOST-ONLY in practice: this phase touches the exe.dev control plane, which a
# sandbox has no credential for. It needs NO
# secrets at all — no OpenRouter key of either kind is read or forwarded here.
#
# NEVER destroys the VM. Every failure below reports and exits non-zero with the
# box still up, because the evidence you need lives on it. `sbx lifecycle teardown` stays
# an explicit, separate decision.

# Phase 5 · start both servers if down, expose 4501 anonymously, print the URLs
observe RUN_ID:
    #!/usr/bin/env bash
    set -euo pipefail
    # `just --working-directory` reaches ROOT recipes but NOT module recipes,
    # which resolve their own directory instead — measured, and a silent way to
    # mount the wrong repo. The shim exports the invocation directory and every
    # recipe returns to it, so "which repo" never depends on just's scoping.
    cd "${SBX_TARGET:?run sbx via bin/sbx, which exports it}"

    RR="{{justfile_directory()}}/lib/run_record.py"
    MF="{{justfile_directory()}}/lib/manifest.py"

    # The run record is the ONLY state shared across the six phases; nothing
    # else survives between them.
    VM=$("$RR" get {{RUN_ID}} vm_name)
    if [ -z "$VM" ]; then
        echo "observe: run record {{RUN_ID}} has no vm_name — run 'sbx lifecycle create' first" >&2
        exit 1
    fi
    HOST="$VM.exe.xyz"

    # WHAT to start, on which port, and which one is public are the target
    # repo's answers. This phase owns the mechanics they all share: the
    # idempotent start, the bind check, the proxy retarget, the verification.
    #
    # One TSV line per service rather than a `get` per field: seven calls to a
    # uv script to start two servers is silly, and the fixed field count makes
    # a missing optional field a dash instead of a misaligned `read`.
    SVC_LINES=$("$MF" services)
    [ -n "$SVC_LINES" ] || { echo "observe: sandbox.yaml declares no services — run: $MF check" >&2; exit 1; }

    echo "── observe {{RUN_ID}} · vm $VM ──────────────────────────────"

    # ── 0. reachability ──────────────────────────────────────────────────────
    # Proven up front so that every `ss` probe below can read a non-zero exit as
    # "not listening" rather than "ssh is broken". All *.exe.xyz share one host
    # key and a wildcard known_hosts entry is already installed, so this is
    # non-interactive.
    if ! ssh "$HOST" 'true' >/dev/null 2>&1; then
        echo "observe: cannot ssh $HOST — VM left up for debugging" >&2
        exit 1
    fi

    # ssh + one line per service + proxy + record + verify.
    N_SVC=$(printf '%s\n' "$SVC_LINES" | grep -c .)
    STEP=0
    TOTAL=$((4 + N_SVC))
    step() { STEP=$((STEP + 1)); printf '[%d/%d] %s\n' "$STEP" "$TOTAL" "$1"; }

    step "ssh ok — $HOST"

    # `ss -ltn` column 4 is Local Address:Port. bun binds 0.0.0.0 by default so
    # a live server shows as *:4501, which the :PORT suffix match catches. The
    # proxy cannot reach a 127.0.0.1 bind, so this doubles as a bind check.
    #
    # `< /dev/null` on every ssh below is load-bearing now that the services come
    # from a loop: ssh reads the caller's stdin by default, and the caller's
    # stdin IS the service list. Without it the first ssh swallows the remaining
    # services and the loop runs exactly once.
    listening() {
        ssh "$HOST" 'ss -ltn' < /dev/null 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"
    }

    # Poll rather than sleep-a-guess: bun is up in well under a second warm, but
    # a cold first read of dist/ is slower.
    wait_listen() {
        local port="$1" tries=0
        until listening "$port"; do
            tries=$((tries + 1))
            [ "$tries" -ge 20 ] && return 1
            sleep 1
        done
        return 0
    }

    # ── 1. start every declared service ──────────────────────────────────────
    # Idempotent: observe is safe to re-run, and `sbx mount` ends here, so a
    # second call must not stack a second server on the same port.
    #
    # Declaration order is start order, which is why manifest.py preserves it:
    # a service that needs another one's port up goes second in sandbox.yaml.
    N=0
    PRIMARY_SVC=""
    PRIMARY_PORT=""
    while IFS=$'\t' read -r SVC DIR CMD PORT PUBLIC REQ ENVS; do
        [ -n "$SVC" ] || continue
        S_NAME[$N]="$SVC"; S_PORT[$N]="$PORT"; S_PUBLIC[$N]="$PUBLIC"
        N=$((N + 1))
        [ "$PUBLIC" = "yes" ] && { PRIMARY_SVC="$SVC"; PRIMARY_PORT="$PORT"; }

        # The clone lands at `app` under the exedev user's home, so these are
        # /home/exedev/app/... on a stock VM. Built as a LITERAL $HOME here and
        # expanded by the remote shell — the host's $HOME is a different path.
        R_DIR='$HOME/app/'"$DIR"
        LOG='$HOME/'"$SVC.log"

        step "$SVC  :$PORT"

        # A declared prerequisite is checked BEFORE the start attempt, so the
        # error names the real cause instead of showing an empty port. This is
        # how the visualizer's missing sssf.db reports itself: it exits on the
        # spot when the db is absent, and `sbx mount` reaches observe before
        # any ADW has run.
        if [ "$REQ" != "-" ]; then
            for R in ${REQ//,/ }; do
                if ! ssh "$HOST" "test -e \$HOME/app/$R" < /dev/null; then
                    echo "observe: $SVC requires app/$R on $VM, and it is missing." >&2
                    echo "         SETUP is what creates it — re-run it:" >&2
                    echo "           sbx lifecycle setup {{RUN_ID}}" >&2
                    exit 1
                fi
            done
        fi

        if listening "$PORT"; then
            echo "       already listening — leaving it alone"
            continue
        fi

        # Any declared env goes BEFORE nohup, never after: `nohup VAR=x cmd`
        # makes nohup try to exec a program literally named "VAR=x". As a prefix
        # the assignment lands in nohup's environment and the server inherits it.
        PREFIX=""
        [ "$ENVS" != "-" ] && PREFIX="$ENVS "

        # All three detachment pieces are REQUIRED or ssh never returns: nohup
        # (survive session end), the redirect (release stdout/stderr), and the
        # inner < /dev/null (release stdin). Dropping any one hangs this recipe.
        # The OUTER < /dev/null is a different fix for a different bug: it stops
        # ssh eating the service list this loop is reading from.
        ssh "$HOST" "cd $R_DIR && ( ${PREFIX}nohup $CMD > $LOG 2>&1 < /dev/null & echo \$! )" < /dev/null \
            | sed 's/^/       started pid /'
        if ! wait_listen "$PORT"; then
            echo "observe: $SVC never bound :$PORT — tail of ~/$SVC.log:" >&2
            ssh "$HOST" "tail -n 40 $LOG" < /dev/null >&2 || true
            exit 1
        fi
        echo "       up"
    done <<< "$SVC_LINES"

    # `check` rejects a manifest with no public service, so this is a guard
    # against the manifest changing under a mounted run, not a normal path.
    [ -n "$PRIMARY_PORT" ] || { echo "observe: no service is marked public — nothing to expose" >&2; exit 1; }

    # ── 2. proxy ─────────────────────────────────────────────────────────────
    # MANDATORY. A fresh exeuntu VM proxies port 8000 (smallest EXPOSEd port
    # >= 1024); without this retarget https://$HOST/ hits nothing. set-public
    # applies to the primary port only — see the note printed at the end.
    step "proxy -> :$PRIMARY_PORT ($PRIMARY_SVC), public"
    ssh exe.dev share port "$VM" "$PRIMARY_PORT"
    ssh exe.dev share set-public "$VM"

    # ── 3. record ────────────────────────────────────────────────────────────
    # Built by manifest.py from the same lines the loop above started, so the
    # record can never disagree with what is actually running.
    step "recording ports"
    "$RR" set {{RUN_ID}} "ports=$("$MF" ports-json)"

    # ── 4. verify ────────────────────────────────────────────────────────────
    # curl with no auth of any kind — that is the whole point of the public
    # check. No -L: a redirect is a result here, not something to follow.
    step "verifying"
    code_of() {
        curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" || echo 000
    }

    for i in $(seq 0 $((N - 1))); do
        SVC="${S_NAME[$i]}"; PORT="${S_PORT[$i]}"
        if [ "${S_PUBLIC[$i]}" = "yes" ]; then
            # The public flag can lag the API call by a beat; retry before failing.
            CODE=000
            for _ in 1 2 3 4 5 6; do
                CODE=$(code_of "https://$HOST/")
                [ "$CODE" = "200" ] && break
                sleep 2
            done
            if [ "$CODE" != "200" ]; then
                echo "observe: $SVC returned $CODE anonymously at https://$HOST/ (want 200)" >&2
                echo "         VM left up. Check: ssh exe.dev share show $VM" >&2
                exit 1
            fi
            echo "       $SVC  200 anonymous"
        else
            # 307/401 anonymously is CORRECT for a non-primary port: alternate
            # ports stay auth-gated to users with VM access. Only a dead proxy
            # (000) or a 5xx is a real failure; anything else means the port is
            # reachable and gated.
            CODE=$(code_of "https://$HOST:$PORT/")
            if [ "$CODE" = "000" ] || [ "$CODE" -ge 500 ]; then
                echo "observe: $SVC unreachable at https://$HOST:$PORT/ (got $CODE)" >&2
                exit 1
            fi
            echo "       $SVC  $CODE anonymous — expected, it is owner-gated"
        fi
    done

    echo ""
    echo "════════════════════════════════════════════════════════════"
    for i in $(seq 0 $((N - 1))); do
        if [ "${S_PUBLIC[$i]}" = "yes" ]; then
            printf '  %-4s https://%s/\n' "${S_NAME[$i]}" "$HOST"
        else
            printf '  %-4s https://%s:%s/\n' "${S_NAME[$i]}" "$HOST" "${S_PORT[$i]}"
        fi
    done
    echo "════════════════════════════════════════════════════════════"
    echo "  The gated URLs open fine in a browser already signed in to exe.dev."
    echo "  Ports 3000-9999 are auto-forwarded by the proxy but auth-gated;"
    echo "  only ONE port can ever be anonymous, and that is $PRIMARY_PORT."
