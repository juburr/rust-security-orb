#!/bin/bash
#
# Runs cargo vet for the vet command: checks that every third-party crate is
# covered by an audit, an imported audit or an exemption in the project's
# supply-chain store. Writes cargo-vet's JSON report and, when asked, JUnit
# XML and a run record.
#
# cargo-vet exits 255 both when vetting fails and when it can't run (no
# store, a malformed one, cargo metadata failing), so the report's top-level
# key tells them apart: "conclusion" for a check that ran, "error" for one
# that didn't. An error stops the step even with report_only.
#
# The verified binary on the PATH runs directly, as "cargo-vet vet", with
# CARGO naming the job's cargo, which cargo vet would otherwise set.

set -euo pipefail

if [[ -z "${SCRIPT_RUST_SECURITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_RUST_SECURITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_RUST_SECURITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST_PATH=$(rs_subst "${PARAM_MANIFEST_PATH}")
STORE_PATH=$(rs_subst "${PARAM_STORE_PATH}")
FILTER_GRAPH=$(rs_subst "${PARAM_FILTER_GRAPH}")
LOCKED=$(rs_bool locked "${PARAM_LOCKED}")
FROZEN=$(rs_bool frozen "${PARAM_FROZEN}")
NO_DEFAULT_FEATURES=$(rs_bool no_default_features "${PARAM_NO_DEFAULT_FEATURES}")
NO_ALL_FEATURES=$(rs_bool no_all_features "${PARAM_NO_ALL_FEATURES}")
JUNIT=$(rs_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(rs_bool report_only "${PARAM_REPORT_ONLY}")
RUN_RECORD=$(rs_bool run_record "${PARAM_RUN_RECORD}")
EXTRA_ARGS=$(rs_subst "${PARAM_EXTRA_ARGS}")
rs_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${RS_WORDS[@]+"${RS_WORDS[@]}"})
rs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rs_require_jq
rs_tool cargo-vet
RS_TOOL_VERSION=$("${RS_TOOL}" --version 2> /dev/null || true)
if ! CARGO=$(command -v cargo); then
    echo "ERROR: cargo is not on the PATH, and cargo vet needs it. Use a Rust image such as cimg/rust." >&2
    exit 1
fi
for word in ${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"}; do
    case "${word}" in
        --output-format | --output-format=* | --output-file | --output-file=*)
            echo "ERROR: extra_args can't set ${word}: vet writes the JSON report itself." >&2
            exit 1
            ;;
        --store-path | --store-path=* | --manifest-path | --manifest-path=*)
            parameter=${word#--}
            parameter=${parameter%%=*}
            echo "ERROR: extra_args can't set ${word%%=*}: use the ${parameter//-/_} parameter, which the run record follows." >&2
            exit 1
            ;;
    esac
done

# Every option goes after the subcommand: cargo vet refuses them before it.
RS_ARGS=(vet check)
if [[ -n "${MANIFEST_PATH}" ]]; then
    RS_ARGS+=(--manifest-path "${MANIFEST_PATH}")
fi
if [[ -n "${STORE_PATH}" ]]; then
    RS_ARGS+=(--store-path "${STORE_PATH}")
fi
# --frozen requires --locked; with --locked cargo vet itself makes no network
# requests, and --frozen also keeps cargo metadata off the network.
if [[ "${LOCKED}" == true || "${FROZEN}" == true ]]; then
    RS_ARGS+=(--locked)
fi
if [[ "${FROZEN}" == true ]]; then
    RS_ARGS+=(--frozen)
fi
rs_list features "${PARAM_FEATURES}"
if [[ ${#RS_LIST[@]} -gt 0 ]]; then
    RS_ARGS+=(--features "${RS_LIST[*]}")
fi
if [[ "${NO_DEFAULT_FEATURES}" == true ]]; then
    RS_ARGS+=(--no-default-features)
fi
if [[ "${NO_ALL_FEATURES}" == true ]]; then
    RS_ARGS+=(--no-all-features)
fi
if [[ -n "${FILTER_GRAPH}" ]]; then
    RS_ARGS+=(--filter-graph "${FILTER_GRAPH}")
fi
RS_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})

# The workspace root, for the lockfile cargo vet's graph comes from, and the
# store cargo vet reads: store_path, or else the store path the root
# package's [package.metadata.vet] or else [workspace.metadata.vet] sets
# (relative to the directory cargo vet runs in), or else supply-chain in the
# workspace root. --no-deps resolves nothing, so it neither writes Cargo.lock
# nor uses the network.
MANIFEST_ARGS=()
if [[ -n "${MANIFEST_PATH}" ]]; then
    MANIFEST_ARGS+=(--manifest-path "${MANIFEST_PATH}")
fi
METADATA=$("${CARGO}" metadata --no-deps --format-version 1 ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} 2> /dev/null) || METADATA=""
ROOT=$(jq -r '.workspace_root // empty' <<< "${METADATA}" 2> /dev/null) || ROOT=""
STORE=${STORE_PATH}
if [[ -z "${STORE}" ]]; then
    # The root package is the one the manifest belongs to, as cargo resolves it.
    MANIFEST=$("${CARGO}" locate-project --message-format plain ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} 2> /dev/null) || MANIFEST=""
    # shellcheck disable=SC2016 # jq program, not shell
    STORE=$(jq -r --arg manifest "${MANIFEST}" '
        ([.packages[]? | select(.manifest_path == $manifest) | .metadata?.vet?.store?.path? | strings] | .[0])
            // (.metadata?.vet?.store?.path? | strings) // empty' <<< "${METADATA}" 2> /dev/null) || STORE=""
fi
STORE=${STORE:-${ROOT:-.}/supply-chain}
RS_INPUTS=()
if [[ -n "${ROOT}" && -f "${ROOT}/Cargo.lock" ]]; then
    RS_INPUTS+=("lockfile:${ROOT}/Cargo.lock")
fi
for file in config.toml audits.toml imports.lock; do
    if [[ -f "${STORE}/${file}" ]]; then
        RS_INPUTS+=("store:${STORE}/${file}")
    fi
done
JSON="${RS_BASE}.json"
RS_REPORTS=()

echo "Running cargo vet with ${RS_TOOL_VERSION:-cargo-vet}..."
# cargo vet opens the report only once it runs, so a report left by an
# earlier run must not be read as this one's.
rm -f "${JSON}"
RC=0
CARGO=${CARGO} "${RS_TOOL}" "${RS_ARGS[@]}" --output-format json --output-file "${JSON}" > "${RS_BASE}.log" 2>&1 || RC=$?
# A success must come with exit code 0; failed vetting exits 255.
# shellcheck disable=SC2016 # jq program, not shell
if ! rs_json_is "${JSON}" 'type == "object" and has("conclusion") and (.conclusion != "success" or $code == 0)' --argjson code "${RC}"; then
    echo "ERROR: cargo vet did not complete (exit code ${RC}), so there is no report." >&2
    jq -r '.error | "  \(.message)", (.causes[]? | "  caused by: \(.)")' "${JSON}" >&2 2> /dev/null \
        || sed 's/^/  /' "${RS_BASE}.log" | tail -n 40 >&2
    if [[ "${RUN_RECORD}" == true ]]; then
        RS_REPORTS+=("${RS_BASE}.log")
        if [[ -s "${JSON}" ]]; then
            RS_REPORTS+=("${JSON}")
        fi
        rs_run_record "${RS_BASE}.run-record.json" vet error "${RC}" "${STARTED}"
    fi
    exit 1
fi
RS_REPORTS+=("${JSON}")
rm -f "${RS_BASE}.log"
CONCLUSION=$(jq -r '.conclusion' "${JSON}")
# shellcheck disable=SC2034 # read by rs_run_record
RS_COUNTS=$(jq -c '{conclusion, vetted_fully: (.vetted_fully // [] | length), vetted_partially: (.vetted_partially // [] | length),
    vetted_with_exemptions: (.vetted_with_exemptions // [] | length), failures: (.failures // [] | length),
    violations: (.violations // {} | length)}' "${JSON}")
echo "cargo vet: ${CONCLUSION}"
jq -r '(.failures // [])[] | "  unvetted: \(.name) \(.version), missing \(.missing_criteria | join(", "))"' "${JSON}"
jq -r '(.violations // {}) | keys[] | "  violation: \(.)"' "${JSON}"

if [[ "${JUNIT}" == true ]]; then
    # shellcheck disable=SC2016 # jq program, not shell
    CASES=$(jq -c '[((.failures // [])[] | {classname: "cargo-vet.unvetted", name: "\(.name) \(.version)", status: "failed",
            message: "missing criteria: \(.missing_criteria | join(", "))"}),
        ((.violations // {}) | keys[] | {classname: "cargo-vet.violation", name: ., status: "failed",
            message: "an audit or policy declares a violation"})]' "${JSON}")
    rs_junit "${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "${PARAM_REPORT_NAME}" "${CASES}"
    RS_REPORTS+=("${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

FINDINGS=false
OUTCOME=passed
if [[ "${CONCLUSION}" != success ]]; then
    FINDINGS=true
    OUTCOME=findings
    if [[ "${REPORT_ONLY}" == true ]]; then
        OUTCOME=findings-reported
    fi
fi
if [[ "${RUN_RECORD}" == true ]]; then
    rs_run_record "${RS_BASE}.run-record.json" vet "${OUTCOME}" "${RC}" "${STARTED}"
fi
rs_gate "${FINDINGS}" "${REPORT_ONLY}" "cargo vet: ${CONCLUSION}."
