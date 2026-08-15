# just/lifecycle/mod.just — the six phases, in order.
#
# create -> fill -> setup -> execute -> observe -> teardown. `sbx mount`
# chains the first three plus observe; these exist for when you need one on its
# own — a re-run of setup after fixing a gate failure, a second execute, a
# teardown you decided on deliberately.
#
# A module inherits nothing, so the three settings are repeated here, relative to
# THIS file's directory — `../..` is the install root. No recipe here depends on
# it: every one opens by cd-ing to $SBX_TARGET, because the repo being mounted is
# never the install dir. The phase files are `import`ed, so they share this scope
# and define no settings and no top-level variables of their own — six files in
# one scope means a duplicate name is a hard error.
set working-directory := '../..'
set positional-arguments
set dotenv-load

import 'create.just'
import 'fill.just'
import 'setup.just'
import 'execute.just'
import 'observe.just'
import 'teardown.just'

# list the lifecycle phases
default:
    @just --justfile "{{justfile()}}" --list lifecycle
