# just/mount.just — the phase chain.
#
# Lives here rather than inline in the root justfile so the whole `sbx` surface
# sits in one directory, split from the target repo's own in-sandbox layer by
# which credential it needs.
#
# Imported by the root justfile, so no `set` lines here.

# create -> fill -> setup -> observe. Stops at observe by design: teardown is
# ALWAYS an explicit separate decision, never chained.
mount RUN_ID *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    # `just --working-directory` reaches ROOT recipes but NOT module recipes,
    # which resolve their own directory instead — measured, and a silent way to
    # mount the wrong repo. The shim exports the invocation directory and every
    # recipe returns to it, so "which repo" never depends on just's scoping.
    cd "${SBX_TARGET:?run sbx via bin/sbx, which exports it}"
    # ALWAYS this justfile, never a bare `just`. A bare `sbx lifecycle ...`
    # resolves against whatever justfile the TARGET repo has — and a repo that
    # still carries its own copy of these recipes would silently run those
    # instead. That happened: the first keyless mount minted a $50 OpenRouter
    # key because the chain re-entered the old in-repo phases, which know
    # nothing about credential providers.
    # SBX_TARGET explicitly, not inherited — see teardown for why.
    SBX=(env SBX_TARGET="$PWD" just --justfile "{{justfile_directory()}}/justfile")
    "${SBX[@]}" lifecycle create "{{RUN_ID}}" {{FLAGS}}
    ID=$({{justfile_directory()}}/lib/run_record.py list | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["run_id"])')
    "${SBX[@]}" lifecycle fill    "$ID"
    "${SBX[@]}" lifecycle setup   "$ID"
    "${SBX[@]}" lifecycle observe "$ID"
    printf '\nmounted: %s\n  execute: sbx lifecycle execute %s "<prompt>"\n  agent:   sbx run agent %s "<prompt>"\n  harvest: sbx manage harvest %s\n  destroy: sbx lifecycle teardown %s\n' "$ID" "$ID" "$ID" "$ID" "$ID"

