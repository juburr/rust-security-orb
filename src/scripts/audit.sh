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
SARIF=$(rs_bool sarif "${PARAM_SARIF}")
JUNIT=$(rs_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(rs_bool report_only "${PARAM_REPORT_ONLY}")
RUN_RECORD=$(rs_bool run_record "${PARAM_RUN_RECORD}")
rs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rs_audit_extra_args
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
rs_audit_options
RS_ARGS=(audit --file "${LOCKFILE}" ${RS_AUDIT_OPTS[@]+"${RS_AUDIT_OPTS[@]}"} ${RS_EXTRA[@]+"${RS_EXTRA[@]}"})
RS_TOOL_VERSION=$("${RS_TOOL}" --version 2> /dev/null || true)
RS_INPUTS=("lockfile:${LOCKFILE}")
# cargo audit reads .cargo/audit.toml in the working directory, or else the
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
# cargo audit reads any TOML file without a package list as a lockfile with
# no packages, and passes it. A Cargo.lock lists at least the project itself.
if [[ "$(jq '.lockfile["dependency-count"] // 0' "${JSON}")" -eq 0 ]]; then
    echo "ERROR: cargo audit found no packages in ${LOCKFILE}, so it is not a Cargo.lock and nothing was audited." >&2
    if [[ "${RUN_RECORD}" == true ]]; then
        RS_REPORTS=("${JSON}")
        rs_run_record "${RS_BASE}.run-record.json" audit error "${RC}" "${STARTED}"
    fi
    exit 1
fi
RS_REPORTS+=("${JSON}")
if [[ -s "${LOG}" ]]; then
    RS_REPORTS+=("${LOG}")
fi

if [[ "${SARIF}" == true ]]; then
    # The JSON pass fetched the database if it was going to, so this pass
    # reads that same copy.
    SARIF_ARGS=("${RS_ARGS[@]}")
    if [[ "${RS_NO_FETCH}" != true ]]; then
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

# shellcheck disable=SC2034 # read by rs_run_record
RS_COUNTS=$(rs_audit_counts "${JSON}")
echo "cargo audit checked $(jq '.lockfile."dependency-count"' "${JSON}") crates against $(jq '.database."advisory-count"' "${JSON}") advisories."
rs_audit_summary "${JSON}" "  "

if [[ "${JUNIT}" == true ]]; then
    rs_junit "${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "${PARAM_REPORT_NAME}" "$(rs_audit_cases "${JSON}" cargo-audit)"
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
    "cargo audit found $(jq '.vulnerabilities' <<< "${RS_COUNTS}") vulnerabilities and $(jq '.denied_warnings' <<< "${RS_COUNTS}") denied warnings in ${LOCKFILE}."
