# ─── just/lifecycle/execute.just — PHASE 4: EXECUTE ─────────────────────────
# Out-of-sandbox orchestration. IMPORTED by the root justfile, so this file
# defines no `set` lines and no top-level variables: settings and variables are
# shared with the root and with the five sibling phase files, and a duplicate is
# either an error or a silent shadow. Everything below is local shell state.
#
# Three ways to drive a mounted sandbox:
#   sbx run cmd            — generic escape hatch, synchronous, prints output
#   sbx lifecycle execute  — the default: the manifest's kickoff, DETACHED,
#                            returns a PID
#   sbx run agent          — hand off to Claude Code and keep talking to it
#
# Nothing here ever destroys a VM. A failure reports and exits non-zero with the
# box left alive, because the evidence you need to diagnose it is on that box.
# Teardown is always a separate, explicit decision.
#
# OPENROUTER_PROVISIONING_KEY is never read in this file and must never be. Only
# the mint/revoke phases touch it, and it never leaves the host. We also never
# ask ssh to forward host env (no SendEnv), so nothing from .env leaks over.

# usage: sbx lifecycle execute <run-id> "add a word-count badge to the editor footer"
#        sbx lifecycle execute <run-id> prompts/06-redesign.md config/frontier.yaml
#
# WHAT runs is `kickoff.default` from the target repo's sandbox.yaml. This phase
# only fills its four placeholders and detaches the result, so every argument
# below is a placeholder value, not a claim about any particular factory.
#
# PROMPT -> {prompt}, passed through verbatim. Whether a path is read as a file
# or kept as inline text is the payload's decision (SSSF resolves it against the
# SANDBOX'S checkout). For fan-out a path is the better handle — every arm then
# provably runs the same bytes.
#
# CONFIG -> {config}, optional, and expands to a whole ` --config <path>` flag or
# to nothing at all. It has to travel as an argument: `ssh vm "cmd"` reads no
# profile and carries no environment, so an env-var route cannot reach the box.
#
# WORKFLOW -> {workflow}, which of the payload's entry points to run. It defaults
# to `sdlc` because that is what the SSSF kickoff template expects; a manifest
# whose template never mentions {workflow} simply ignores it. It is a separate
# argument rather than something smuggled into PROMPT because it lands where the
# template puts it, while the prompt is quoted as one word.
#
# EXTRA -> {extra}, appended verbatim, for the payload's own flags — for SSSF,
# most usefully `--adw-id <id>`, which rejoins an existing session. Interpolated
# as typed, like `run cmd`: these are flags, not prose, and re-quoting them would
# break --flag value pairs.

# the default: run the manifest's kickoff inside the sandbox, detached — returns a PID. CONFIG picks the roster, WORKFLOW the entry point
execute RUN_ID PROMPT CONFIG="" WORKFLOW="sdlc" *EXTRA:
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
    [ -n "$VM" ] || { echo "execute {{RUN_ID}}: no vm_name in the run record — is it mounted?" >&2; exit 1; }

    # WHAT to run inside the box is the target repo's answer; detaching it and
    # capturing the pid is ours. A repo whose factory is not SSSF changes one
    # line of sandbox.yaml and this phase does not notice.
    KICKOFF=$("$MF" get kickoff.default)
    # Optional in the manifest, required HERE: a repo can be worth mounting and
    # serving without having any work to kick off, and making it invent an
    # `echo {prompt}` to satisfy a field it never uses is a coupling, not a
    # check. So this phase — the only one that needs it — is where it is missed.
    [ -n "$KICKOFF" ] || { echo "execute {{RUN_ID}}: this manifest declares no kickoff.default, so there is nothing to run inside the box. Add one to $("$MF" path), or use 'sbx run cmd' / 'sbx run agent' instead." >&2; exit 1; }

    # quote() hands bash a correct single-quoted literal, so apostrophes in the
    # prompt survive hop 1 (just -> host bash). printf %q then survives hop 2
    # (host bash -> the remote login shell), which parses the ssh command string.
    PROMPT={{ quote(PROMPT) }}
    Q=$(printf '%q' "$PROMPT")

    # Same two-hop treatment for the roster path, and the whole flag collapses to
    # the empty string when no config was asked for — so the default call site
    # builds the exact command it built before this argument existed.
    CONFIG={{ quote(CONFIG) }}
    CFG_ARG=""
    if [ -n "$CONFIG" ]; then
        CFG_ARG=" --config $(printf '%q' "$CONFIG")"
        echo "→ roster: $CONFIG"
    fi

    # All three detachment pieces are mandatory or ssh never returns: nohup
    # (survive session end), the redirect (release stdout/stderr), < /dev/null
    # (release stdin). `echo $!` inside the subshell is what gives us the PID —
    # \$! so it is expanded by the REMOTE shell, not here.
    #
    # If the template carries `--shell bash --shell-arg -c`, that is the target
    # repo's business and not ours: a root justfile setting shell := ["zsh",
    # "-ic"] needs it, because zsh is not in the exeuntu image (installing it is
    # ~35s of apt for no benefit).
    #
    # Substitution is bash string replacement, in this order, so a prompt that
    # happens to contain the literal text {config} cannot inject a flag: the
    # placeholders are consumed before the prompt's own bytes are in the string.
    WORKFLOW={{ quote(WORKFLOW) }}
    # EXTRA stays raw, exactly as it was interpolated before: these are flags,
    # not prose, and re-quoting them would break --flag value pairs.
    EXTRA="{{ EXTRA }}"
    CMD="$KICKOFF"
    CMD="${CMD//\{workflow\}/$WORKFLOW}"
    CMD="${CMD//\{config\}/$CFG_ARG}"
    CMD="${CMD//\{extra\}/$EXTRA}"
    CMD="${CMD//\{prompt\}/$Q}"

    # NOTE: run.log is truncated on every execute — one detached kickoff per
    # sandbox at a time is the intended shape. Pull the old log first if you
    # care about it.
    echo "→ execute {{RUN_ID}} on $VM (detached): {{WORKFLOW}} $PROMPT"
    # tail -n 1: the PID is the last thing printed, so any stray remote stdout
    # (a shell rc that talks, an motd) does not corrupt the capture.
    # The trailing `< /dev/null` on the LOCAL ssh is separate from the one inside
    # the remote command, and both are needed. The inner one detaches the remote
    # kickoff from its stdin; this outer one stops ssh reading the CALLER's stdin.
    # Without it a `while read ... done < arms.map` loop around this recipe runs
    # exactly once — ssh eats the rest of the map and the loop sees EOF.
    PID=$(ssh "$VM".exe.xyz "cd app && ( nohup $CMD > run.log 2>&1 < /dev/null & echo \$! )" < /dev/null | tail -n 1)

    # A non-numeric answer means the remote shell printed an error where the PID
    # should be. Fail here rather than writing garbage into the record.
    case "$PID" in
        ''|*[!0-9]*) echo "execute {{RUN_ID}}: expected a PID, got: ${PID:-<empty>}" >&2; exit 1 ;;
    esac

    "$RR" set {{RUN_ID}} pid="$PID"
    echo "→ pid $PID recorded; the kickoff is running detached"
    echo "→ watch it:  sbx run cmd {{RUN_ID}} 'tail -f run.log'"
