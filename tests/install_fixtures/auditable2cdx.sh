# shellcheck shell=bash
# auditable2cdx has no version option: run without arguments, it panics
# saying no input file was given, which its smoke test looks for.
fixture_binary() {
    printf '#!/bin/sh\necho "thread main panicked: No input file specified! (stand-in for %s)" >&2\nexit 101\n' "$1"
}
