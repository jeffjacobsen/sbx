# just/manage/reap.just — the fleet-wide backstop.
#
# No RUN_ID on `reap`: it is the fleet-wide backstop, not a per-run step.
# OpenRouter keys have no native TTL, so a teardown that never ran leaves a key
# spending forever.
#
# The sbx- prefix is the entire safety model. The engineer's personal keys carry
# NO prefix (verified: mac-mini-agent, OAuth: localhost, m4 global, benchy) and
# deleting one is unrecoverable. Nothing without that prefix is ever considered.

# revoke orphaned sbx- keys — dry run by default; pass --yes to actually delete
reap *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    # `just --working-directory` reaches ROOT recipes but NOT module recipes,
    # which resolve their own directory instead — measured, and a silent way to
    # mount the wrong repo. The shim exports the invocation directory and every
    # recipe returns to it, so "which repo" never depends on just's scoping.
    cd "${SBX_TARGET:?run sbx via bin/sbx, which exports it}"

    API="https://openrouter.ai/api/v1"
    PREFIX="sbx-"
    CRED="{{justfile_directory()}}/lib/credential.py"
    RR="{{justfile_directory()}}/lib/run_record.py"
    SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)

    # Interpolating the variadic straight into a `for ... in` list is a syntax
    # error when no flags were passed; through a variable an empty expansion is
    # simply zero iterations.
    RAW_FLAGS="{{ FLAGS }}"
    APPLY=0
    for a in $RAW_FLAGS; do
        case "$a" in
            --yes) APPLY=1 ;;
            *) echo "reap: unknown flag $a (only --yes)"; exit 2 ;;
        esac
    done

    [ -n "${OPENROUTER_PROVISIONING_KEY:-}" ] || { echo "!! OPENROUTER_PROVISIONING_KEY unset — cannot list or delete keys"; exit 1; }

    umask 077   # these temp files hold key hashes; not secrets, but not public either
    TMPD=$(mktemp -d -t sbx-reap)
    trap 'rm -rf "$TMPD"' EXIT

    # UNVERIFIED: whether GET /keys paginates past some page size. Observed 4 keys
    # in one response with no pagination envelope. If a fleet ever exceeds that,
    # this needs an `offset` loop.
    "$CRED" list-json > "$TMPD/keys.json" \
        || { echo "!! could not list keys"; exit 1; }
    ssh "${SSH_OPTS[@]}" exe.dev ls --json > "$TMPD/vms.json" 2>/dev/null || echo '{"vms":[]}' > "$TMPD/vms.json"

    # Records come from `run_record.py list`, never from globbing a directory.
    # This join is the reason the store moved out of the repo: it reasons about
    # the whole ACCOUNT, so it has to see every record on the machine, including
    # any still in a repo's legacy .sandbox/runs. A record this cannot see reads
    # as "no record left" below — and the fallback would then judge a live run
    # by its VM alone. `list` unions both stores and exits non-zero on an
    # unreadable record, which under `set -e` stops the reap: an unaccountable
    # key must never be silently skipped.
    "$RR" list > "$TMPD/runs.json"

    # Selection in python (stdlib, same reason run_record.py is): three-way join of
    # key list x vm list x run records is not a thing to write in jq.
    PREFIX="$PREFIX" python3 - "$TMPD/keys.json" "$TMPD/vms.json" "$TMPD/runs.json" > "$TMPD/plan.tsv" <<'PY'
    import json, os, sys
    from pathlib import Path

    keys = json.loads(Path(sys.argv[1]).read_text()).get("data", [])
    live_vms = {v.get("vm_name") for v in json.loads(Path(sys.argv[2]).read_text()).get("vms", [])}
    records = {r.get("run_id"): r for r in json.loads(Path(sys.argv[3]).read_text())}
    prefix = os.environ["PREFIX"]

    for k in keys:
        name = k.get("name") or ""
        if not name.startswith(prefix):
            continue  # personal key. Never considered, never printed as a candidate.
        run_id = name[len(prefix):]
        # No record left? Fall back to the run id: create.just passes it as --name,
        # so vm_name == run_id unless the record says otherwise.
        rec = records.get(run_id)
        closed, vm = None, run_id
        if rec is not None:
            closed = rec.get("closed_at")
            vm = rec.get("vm_name") or run_id

        if closed:
            reason = f"record closed {closed}"
        elif vm not in live_vms:
            reason = f"vm {vm} no longer exists"
        else:
            continue  # live run: vm up and record open. Leave it alone.
        print("\t".join([name, k.get("hash") or "", f'{k.get("usage", 0)}', reason]))
    PY

    if [ ! -s "$TMPD/plan.tsv" ]; then
        echo "reap: no orphaned ${PREFIX}* keys"
        exit 0
    fi

    echo "reap: orphaned ${PREFIX}* keys"
    printf '  %-38s %-8s %s\n' "NAME" "SPEND" "WHY"
    while IFS=$'\t' read -r name hash usage reason; do
        printf '  %-38s $%-7s %s\n' "$name" "$usage" "$reason"
    done < "$TMPD/plan.tsv"

    if [ "$APPLY" != 1 ]; then
        echo
        echo "dry run — nothing deleted. To actually revoke these:  sbx manage reap --yes"
        exit 0
    fi

    echo
    while IFS=$'\t' read -r name hash usage reason; do
        # Defence in depth: re-assert the prefix at the point of deletion, not just
        # at selection. A bug upstream must not be able to reach a personal key.
        case "$name" in
            "$PREFIX"?*) ;;
            *) echo "!! refusing to delete '$name' — no $PREFIX prefix"; exit 1 ;;
        esac
        [ -n "$hash" ] || { echo "!! $name has no hash — skipping"; continue; }
        # The provider re-asserts the prefix a THIRD time inside revoke-managed
        # and gates the delete against the LIST. Three checks, one of them in the
        # single place every caller must pass through.
        RESULT=$("$CRED" revoke-managed "$name" "$hash") \
            || { echo "  !! $name: revoke failed — still live"; exit 1; }
        case "$RESULT" in
            ok)           echo "  ✗ revoked $name" ;;
            already_gone) echo "  · $name already gone" ;;
        esac
    done < "$TMPD/plan.tsv"

    # Same gate as teardown, for the same measured reason: the LIST is authoritative.
    "$CRED" list-json > "$TMPD/after.json" \
        || { echo "!! could not re-list keys — revocation UNVERIFIED"; exit 1; }
    if python3 - "$TMPD/after.json" "$TMPD/plan.tsv" <<'PY'
    import json, sys
    from pathlib import Path
    live = {k.get("hash") for k in json.loads(Path(sys.argv[1]).read_text()).get("data", [])}
    still = [l.split("\t")[0] for l in Path(sys.argv[2]).read_text().splitlines() if l and l.split("\t")[1] in live]
    if still:
        print("!! still listed after DELETE: " + ", ".join(still), file=sys.stderr)
        sys.exit(1)
    PY
    then
        echo "✓ gate: every reaped key is absent from the provider key list"
    else
        exit 1
    fi
