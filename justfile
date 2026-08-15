# sbx — a fleet manager for disposable exe.dev VMs.
#
# Installed ONCE PER MACHINE and run from inside whatever repo you are mounting.
# That is not a packaging preference: `reap` and `manage list` reason about a
# whole exe.dev + OpenRouter account, so a copy per repo would give you one
# partial view per repo and a key could hide in the gap.
#
# The repo being mounted is the CWD; this justfile's own directory is only where
# the machinery lives. `bin/sbx` keeps those two straight — it points just at
# this file while leaving the working directory alone. Run `just` directly from
# a target repo and you would get that repo's justfile instead, which is why the
# shim exists rather than a documented `just --justfile` incantation.

set positional-arguments

# list the commands
default:
    @just --list --justfile "{{justfile()}}"

# create → fill → setup → observe. NEVER teardown.
# `import`, not `mod`: mount is the entry point, so it must be `sbx mount <task>`
# rather than `sbx mount mount <task>`. An import shares this file's scope.
import 'just/mount.just'

# the six phases, individually callable
mod lifecycle 'just/lifecycle/mod.just'

# preflight, readback, fleet ops — nothing here is a phase
mod manage 'just/manage/mod.just'

# put work in / look inside
mod run 'just/run/mod.just'
