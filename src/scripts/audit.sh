#!/bin/bash
#
# Runs cargo audit over a Cargo.lock for the audit command, and writes its
# native JSON report, a SARIF report and, when asked, JUnit XML and a run
# record.
#
# cargo-audit exits 1 both when it finds vulnerabilities (or warnings that
# deny makes errors) and when it fails, so the exit code alone can't tell
# them apart. A scan that completes always prints its whole JSON report to
# stdout, and one that fails prints nothing there, which is what this script
# goes by: a failure stops the step even with report_only.

set -euo pipefail

if [[ -z "${SCRIPT_RUST_SECURITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_RUST_SECURITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_RUST_SECURITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOCKFILE=$(rs_subst "${PARAM_LOCKFILE}")
DB_PATH=$(rs_subst "${PARAM_DB_PATH}")
NO_FETCH=$(rs_bool no_fetch "${PARAM_NO_FETCH}")
ALLOW_STALE=$(rs_bool allow_stale "${PARAM_ALLOW_STALE}")
NO_YANKED=$(rs_bool no_yanked "${PARAM_NO_YANKED}")
SARIF=$(rs_bool sarif "${PARAM_SARIF}")
JUNIT=$(rs_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(rs_bool report_only "${PARAM_REPORT_ONLY}")
RUN_RECORD=$(rs_bool run_record "${PARAM_RUN_RECORD}")
EXTRA_ARGS=$(rs_subst "${PARAM_EXTRA_ARGS}")
rs_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${RS_WORDS[@]+"${RS_WORDS[@]}"})
rs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rs_require_jq
rs_tool cargo-audit

if [[ -z "${LOCKFILE}" ]]; then
    echo "ERROR: lockfile is empty. Name the Cargo.lock to audit." >&2
    exit 1
fi
if [[ ! -f "${LOCKFILE}" ]]; then
    echo "ERROR: ${LOCKFILE} does not exist (in $(pwd)). Commit Cargo.lock, or create it with cargo generate-lockfile" >&2
    echo "  in an earlier step, so the audit covers the dependency versions the build uses." >&2
    exit 1
fi
for word in ${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"}; do
    case "${word}" in
        --json | --format | --format=*)
            echo "ERROR: extra_args can't set ${word}: audit writes the JSON and SARIF reports itself." >&2
            exit 1
            ;;
    esac
done

# The database: db_path, else the one fetch_advisory_db exported, else
# cargo-audit's own default.
DB=${DB_PATH:-${RUSTSEC_ADVISORY_DB:-}}
RS_ARGS=(audit --file "${LOCKFILE}")
if [[ -n "${DB}" ]]; then
    RS_ARGS+=(--db "${DB}")
fi
RS_DB=${DB:-${CARGO_HOME:-${HOME:-}/.cargo}/advisory-db}
if [[ "${NO_FETCH}" == true ]]; then
    RS_ARGS+=(--no-fetch)
    rs_db_fresh "${RS_DB}" "${ALLOW_STALE}"
elif [[ "${ALLOW_STALE}" == true ]]; then
    RS_ARGS+=(--stale)
fi
DENIED=()
rs_list deny "$(rs_subst "${PARAM_DENY}")"
for kind in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
    case "${kind}" in
        warnings | unmaintained | unsound | yanked) ;;
        *)
            echo "ERROR: deny takes warnings, unmaintained, unsound and yanked, not '${kind}'." >&2
            exit 1
            ;;
    esac
    DENIED+=("${kind}")
    RS_ARGS+=(--deny "${kind}")
done
rs_list target_arch "$(rs_subst "${PARAM_TARGET_ARCH}")"
for value in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
    RS_ARGS+=(--target-arch "${value}")
done
rs_list target_os "$(rs_subst "${PARAM_TARGET_OS}")"
for value in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
    RS_ARGS+=(--target-os "${value}")
done
if [[ "${NO_YANKED}" == true ]]; then
    RS_ARGS+=(--no-yanked)
fi
RS_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})
RS_TOOL_VERSION=$("${RS_TOOL}" --version 2> /dev/null || true)
RS_INPUTS=("lockfile:${LOCKFILE}")
# cargo-audit reads .cargo/audit.toml in the working directory, or else the
# one in CARGO_HOME.
if [[ -f .cargo/audit.toml ]]; then
    RS_INPUTS+=("config:.cargo/audit.toml")
elif [[ -f "${CARGO_HOME:-${HOME:-}/.cargo}/audit.toml" ]]; then
    RS_INPUTS+=("config:${CARGO_HOME:-${HOME:-}/.cargo}/audit.toml")
fi
RS_REPORTS=()
JSON="${RS_BASE}.json"
LOG="${RS_BASE}.log"

echo "Auditing ${LOCKFILE} with ${RS_TOOL_VERSION:-cargo-audit}..."
RC=0
"${RS_TOOL}" "${RS_ARGS[@]}" --json > "${JSON}" 2> "${LOG}" || RC=$?
if ! jq -e 'type == "object" and (.vulnerabilities | type == "object")' "${JSON}" > /dev/null 2>&1; then
    echo "ERROR: cargo audit did not complete (exit code ${RC}), so there is no report. Its output:" >&2
    sed 's/^/  /' "${LOG}" | tail -n 40 >&2
    if [[ "${RUN_RECORD}" == true ]]; then
        RS_REPORTS=("${LOG}")
        rs_run_record "${RS_BASE}.run-record.json" audit error "${RC}" "${STARTED}"
    fi
    exit 1
fi
RS_REPORTS+=("${JSON}")
if [[ -s "${LOG}" ]]; then
    RS_REPORTS+=("${LOG}")
fi

if [[ "${SARIF}" == true ]]; then
    # The JSON pass fetched the database if it was going to, so this one
    # reads the same copy.
    SARIF_ARGS=("${RS_ARGS[@]}")
    if [[ "${NO_FETCH}" != true ]]; then
        SARIF_ARGS+=(--no-fetch)
    fi
    "${RS_TOOL}" "${SARIF_ARGS[@]}" --format sarif > "${RS_BASE}.sarif" 2>> "${LOG}" || true
    if ! jq -e '.version == "2.1.0" and (.runs | type == "array")' "${RS_BASE}.sarif" > /dev/null 2>&1; then
        echo "ERROR: cargo audit did not write a SARIF report. Its output:" >&2
        sed 's/^/  /' "${LOG}" | tail -n 20 >&2
        exit 1
    fi
    RS_REPORTS+=("${RS_BASE}.sarif")
fi

VULNERABILITIES=$(jq '.vulnerabilities.count' "${JSON}")
DENIED_JSON=$(printf '%s\n' ${DENIED[@]+"${DENIED[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))')
# The warnings deny turns into errors: every kind for "warnings".
RS_COUNTS=$(jq -c --argjson denied "${DENIED_JSON}" '{
    vulnerabilities: .vulnerabilities.count,
    warnings: (.warnings | map_values(length)),
    denied_warnings: ([.warnings | to_entries[] | select(($denied | index("warnings")) or ($denied | index(.key))) | .value | length] | add // 0)
}' "${JSON}")

echo "cargo audit scanned $(jq '.lockfile."dependency-count"' "${JSON}") crates against $(jq '.database."advisory-count"' "${JSON}") advisories."
# shellcheck disable=SC2016 # jq program, not shell
jq -r '
    (.vulnerabilities.list[] | "  vulnerability  \(.advisory.id)  \(.package.name) \(.package.version)  \(.advisory.title)"),
    (.warnings | to_entries[] | .value[] | "  \(.kind)  \(.advisory.id // "-")  \(.package.name) \(.package.version)\(if .advisory then "  " + .advisory.title else "" end)")
' "${JSON}"

if [[ "${JUNIT}" == true ]]; then
    # shellcheck disable=SC2016 # jq program, not shell
    CASES=$(jq -c --argjson denied "${DENIED_JSON}" '
        [(.vulnerabilities.list[] | {
            classname: "cargo-audit.vulnerability",
            name: "\(.advisory.id) \(.package.name) \(.package.version)",
            status: "failed",
            message: .advisory.title,
            detail: "\(.advisory.url // ("https://rustsec.org/advisories/" + .advisory.id))\nPatched: \((.versions.patched // []) | join(", ") | if . == "" then "none" else . end)"
        }),
        (.warnings | to_entries[] | .key as $kind | .value[] | {
            classname: "cargo-audit.\($kind)",
            name: "\(.advisory.id // $kind) \(.package.name) \(.package.version)",
            status: (if ($denied | index("warnings")) or ($denied | index($kind)) then "failed" else "skipped" end),
            message: (.advisory.title // "\($kind) crate"),
            detail: (.advisory.url // "")
        })]' "${JSON}")
    rs_junit "${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "${PARAM_REPORT_NAME}" "${CASES}"
    RS_REPORTS+=("${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

FINDINGS=false
OUTCOME=passed
if [[ "${RC}" -ne 0 ]]; then
    FINDINGS=true
    OUTCOME=findings
    if [[ "${REPORT_ONLY}" == true ]]; then
        OUTCOME=findings-reported
    fi
fi
if [[ "${RUN_RECORD}" == true ]]; then
    rs_run_record "${RS_BASE}.run-record.json" audit "${OUTCOME}" "${RC}" "${STARTED}"
fi
rs_gate "${FINDINGS}" "${REPORT_ONLY}" \
    "cargo audit found ${VULNERABILITIES} vulnerabilities and $(jq '.denied_warnings' <<< "${RS_COUNTS}") denied warnings in ${LOCKFILE}."
