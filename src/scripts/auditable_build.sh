#!/bin/bash
#
# Runs cargo auditable build for the auditable_build command: a cargo build
# that embeds the resolved dependency list in every binary it links, for
# audit_bin and verify_auditable to read back from the shipped artifact.
# Every build option is passed through from extra_args; this script only
# makes sure the build is auditable.

set -euo pipefail

if [[ -z "${SCRIPT_RUST_SECURITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_RUST_SECURITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_RUST_SECURITY_LIB}"

SUBCOMMAND=${PARAM_SUBCOMMAND}
EXTRA_ARGS=$(rs_subst "${PARAM_EXTRA_ARGS}")
rs_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${RS_WORDS[@]+"${RS_WORDS[@]}"})
rs_tool cargo-auditable
if ! CARGO=$(command -v cargo); then
    echo "ERROR: cargo is not on the PATH. Use a Rust image such as cimg/rust, or install Rust in an earlier step." >&2
    exit 1
fi
case "${SUBCOMMAND}" in
    build | install | rustc) ;;
    *)
        echo "ERROR: subcommand must be build, install or rustc, not '${SUBCOMMAND}'." >&2
        exit 1
        ;;
esac

# cargo runs the first cargo-auditable on the PATH for "cargo auditable", and
# puts $CARGO_HOME/bin first when it isn't on the PATH, so say which one runs.
FOUND=${RS_TOOL}
CARGO_BIN="${CARGO_HOME:-${HOME:-}/.cargo}/bin"
if [[ ":${PATH}:" != *":${CARGO_BIN}:"* && -x "${CARGO_BIN}/cargo-auditable" ]]; then
    FOUND="${CARGO_BIN}/cargo-auditable"
fi
if [[ ! "${FOUND}" -ef "${RS_TOOL}" ]]; then
    echo "WARN: cargo will run ${FOUND}, not ${RS_TOOL}, since cargo searches \$CARGO_HOME/bin first when it isn't on the PATH." >&2
fi
echo "Running cargo auditable ${SUBCOMMAND} ${EXTRA_ARG_LIST[*]-} with $("${CARGO}" --version) and ${FOUND}..."
"${CARGO}" auditable "${SUBCOMMAND}" ${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"}
echo "Built with cargo auditable: the binaries carry their dependency list. Check the shipped files with verify_auditable."
