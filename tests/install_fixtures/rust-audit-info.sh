# rust-audit-info has no version option: run without arguments, it prints its
# usage and exits 1, which its smoke test looks for.
fixture_binary() {
    printf '#!/bin/sh\necho "Usage: rust-audit-info FILE [INPUT_SIZE_LIMIT] [OUTPUT_SIZE_LIMIT] (stand-in for %s)"\nexit 1\n' "$1"
}
