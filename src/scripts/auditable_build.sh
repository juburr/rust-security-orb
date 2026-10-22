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

# cargo would run an auditable alias from any config it reads in place of
# cargo-auditable, and searches $CARGO_HOME/bin before the PATH when it isn't
# on it. So the verified binary runs directly, as cargo runs it: with
# "auditable" first and CARGO naming cargo.
echo "Running cargo auditable ${SUBCOMMAND} ${EXTRA_ARG_LIST[*]-} with $("${CARGO}" --version) and ${RS_TOOL}..."
CARGO=${CARGO} "${RS_TOOL}" auditable "${SUBCOMMAND}" ${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"}
echo "Built with cargo auditable: the binaries carry their dependency list. Check the shipped files with verify_auditable."
