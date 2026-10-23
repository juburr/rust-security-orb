# shellcheck shell=bash
# cargo-auditable has no version option: run on its own, it says how it must
# be invoked and exits 1, which its smoke test looks for.
fixture_binary() {
    printf "#!/bin/sh\necho \"'cargo auditable' should be invoked through Cargo (stand-in for %s)\"\nexit 1\n" "$1"
}
