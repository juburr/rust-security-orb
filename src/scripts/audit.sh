#!/bin/bash
#
# Runs cargo audit over a Cargo.lock for the audit command, and writes its
# native JSON report, a SARIF report and, when asked, JUnit XML and a run
# record. With lockfiles, it audits each lockfile on its own, with its own
# reports (<report_name>-<slug>.json, .sarif, .log), lists them in an index,
# <report_name>.json, and fails the step only once every one is audited.
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

# One lockfile, whose reports are <report_name>.*, or several, each with
# reports of its own, <report_name>-<slug>.*.
rs_list_lines lockfiles "${PARAM_LOCKFILES}"
MULTI=false
if [[ ${#RS_LIST[@]} -gt 0 ]]; then
    if [[ -n "${LOCKFILE}" ]]; then
        echo "ERROR: lockfile and lockfiles are both set. Name one Cargo.lock in lockfile, or several in lockfiles." >&2
        exit 1
    fi
    MULTI=true
    rs_files lockfiles
    LOCKFILES=("${RS_FILES[@]}")
else
    LOCKFILE=${LOCKFILE:-Cargo.lock}
    if [[ ! -f "${LOCKFILE}" ]]; then
        echo "ERROR: ${LOCKFILE} does not exist (in $(pwd)). Commit Cargo.lock, or create it with cargo generate-lockfile" >&2
        echo "  in an earlier step, so the audit covers the dependency versions the build uses." >&2
        exit 1
    fi
    LOCKFILES=("${LOCKFILE}")
fi
BASES=()
SLUG_LIST=()
declare -A SLUGS=()
for lockfile in "${LOCKFILES[@]}"; do
    if [[ "${MULTI}" == true ]]; then
        rs_slug "${lockfile}" Cargo.lock
        if [[ -n "${SLUGS[${RS_SLUG}]:-}" ]]; then
            echo "ERROR: lockfiles names ${SLUGS[${RS_SLUG}]} and ${lockfile}, whose reports would both be named ${PARAM_REPORT_NAME}-${RS_SLUG}." >&2
            exit 1
        fi
        SLUGS[${RS_SLUG}]=${lockfile}
        SLUG_LIST+=("${RS_SLUG}")
        BASES+=("${RS_BASE}-${RS_SLUG}")
    else
        SLUG_LIST+=("")
        BASES+=("${RS_BASE}")
    fi
done

rs_audit_options
# The arguments every lockfile's audit shares, for the run record; with one
# lockfile, its --file too.
# shellcheck disable=SC2034 # read by rs_run_record
if [[ "${MULTI}" == true ]]; then
    RS_ARGS=(audit ${RS_AUDIT_OPTS[@]+"${RS_AUDIT_OPTS[@]}"} ${RS_EXTRA[@]+"${RS_EXTRA[@]}"})
else
    RS_ARGS=(audit --file "${LOCKFILE}" ${RS_AUDIT_OPTS[@]+"${RS_AUDIT_OPTS[@]}"} ${RS_EXTRA[@]+"${RS_EXTRA[@]}"})
fi
RS_TOOL_VERSION=$("${RS_TOOL}" --version 2> /dev/null || true)
RS_INPUTS=()
for lockfile in "${LOCKFILES[@]}"; do
    RS_INPUTS+=("lockfile:${lockfile}")
done
if [[ -n "${RS_AUDIT_CONFIG}" ]]; then
    RS_INPUTS+=("config:${RS_AUDIT_CONFIG}")
fi
RS_REPORTS=()

# audit_error CODE: stops the step for a cargo audit that didn't complete,
# with an error run record.
audit_error() {
    if [[ "${RUN_RECORD}" == true ]]; then
        rs_run_record "${RS_BASE}.run-record.json" audit error "$1" "${STARTED}"
    fi
    exit 1
}

INDEX="[]"
SUITES="[]"
FAILED_CODE=0
for ((i = 0; i < ${#LOCKFILES[@]}; i++)); do
    lockfile=${LOCKFILES[i]}
    base=${BASES[i]}
    # Only the first audit may fetch the database; the others read that copy.
    ARGS=(audit --file "${lockfile}" ${RS_AUDIT_OPTS[@]+"${RS_AUDIT_OPTS[@]}"})
    if [[ "${RS_NO_FETCH}" != true && "${i}" -gt 0 ]]; then
        ARGS+=(--no-fetch)
    fi
    ARGS+=(${RS_EXTRA[@]+"${RS_EXTRA[@]}"})
    echo "Auditing ${lockfile} with ${RS_TOOL_VERSION:-cargo-audit}..."
    rs_show_command "${RS_TOOL##*/}" "${ARGS[@]}" --json
    rc=0
    "${RS_TOOL}" "${ARGS[@]}" --json > "${base}.json" 2> "${base}.log" || rc=$?
    if ! rs_json_is "${base}.json" 'type == "object" and (.vulnerabilities | type == "object")'; then
        echo "ERROR: cargo audit did not complete (exit code ${rc}), so there is no report. Its output:" >&2
        sed 's/^/  /' "${base}.log" | tail -n 40 >&2
        RS_REPORTS+=("${base}.log")
        audit_error "${rc}"
    fi
    # cargo audit reads any TOML file without a package list as a lockfile
    # with no packages, and passes it. A Cargo.lock lists at least the
    # project itself.
    if [[ "$(jq '.lockfile["dependency-count"] // 0' "${base}.json")" -eq 0 ]]; then
        echo "ERROR: cargo audit found no packages in ${lockfile}, so it is not a Cargo.lock and nothing was audited." >&2
        RS_REPORTS+=("${base}.json")
        audit_error "${rc}"
    fi
    RS_REPORTS+=("${base}.json")
    if [[ -s "${base}.log" ]]; then
        RS_REPORTS+=("${base}.log")
    fi
    if ! rs_audit_check "${base}.log" "${base}.json" "${rc}"; then
        audit_error "${rc}"
    fi

    if [[ "${SARIF}" == true ]]; then
        # The JSON pass fetched the database if it was going to, so this pass
        # reads that same copy.
        SARIF_ARGS=("${ARGS[@]}")
        if [[ "${RS_NO_FETCH}" != true && "${i}" -eq 0 ]]; then
            SARIF_ARGS+=(--no-fetch)
        fi
        sarif_rc=0
        "${RS_TOOL}" "${SARIF_ARGS[@]}" --format sarif > "${base}.sarif" 2>> "${base}.log" || sarif_rc=$?
        if ! rs_json_is "${base}.sarif" '.version == "2.1.0" and (.runs | type == "array")'; then
            echo "ERROR: cargo audit did not write a SARIF report. Its output:" >&2
            sed 's/^/  /' "${base}.log" | tail -n 20 >&2
            RS_REPORTS+=("${base}.log")
            audit_error "${sarif_rc}"
        fi
        RS_REPORTS+=("${base}.sarif")
    fi

    counts=$(rs_audit_counts "${base}.json" "${rc}")
    outcome=passed
    if [[ "${rc}" -ne 0 ]]; then
        FAILED_CODE=${rc}
        outcome=findings
        if [[ "${REPORT_ONLY}" == true ]]; then
            outcome=findings-reported
        fi
    fi
    echo "cargo audit checked $(jq '.lockfile."dependency-count"' "${base}.json") crates in ${lockfile} against $(jq '.database."advisory-count"' "${base}.json") advisories."
    rs_audit_summary "${base}.json" "  "
    INDEX=$(jq -c --arg lockfile "${lockfile}" --arg slug "${SLUG_LIST[i]}" --arg sha "$(rs_sha256 "${lockfile}")" \
        --arg report "${base}.json" --arg outcome "${outcome}" --argjson counts "${counts}" \
        '. + [{lockfile: $lockfile, slug: $slug, sha256: $sha, report: $report, outcome: $outcome} + $counts]' <<< "${INDEX}")
    if [[ "${JUNIT}" == true ]]; then
        suite=${PARAM_REPORT_NAME}
        if [[ "${MULTI}" == true ]]; then
            suite="${PARAM_REPORT_NAME}-${SLUG_LIST[i]}"
        fi
        SUITES=$(jq -c --arg name "${suite}" --argjson cases "$(rs_audit_cases "${base}.json" cargo-audit "${rc}")" \
            '. + [{name: $name, cases: $cases}]' <<< "${SUITES}")
    fi
done

if [[ "${MULTI}" == true ]]; then
    jq '{lockfiles: .}' <<< "${INDEX}" > "${RS_BASE}.json"
    RS_REPORTS+=("${RS_BASE}.json")
    # shellcheck disable=SC2034 # read by rs_run_record
    RS_COUNTS=$(jq -c '{lockfiles: length, vulnerabilities: (map(.vulnerabilities) | add),
        warnings: (reduce (.[].warnings | to_entries[]) as $w ({}; .[$w.key] += $w.value)),
        denied_warnings: (map(.denied_warnings) | add), denied_by_config: (map(.denied_by_config) | any)}' <<< "${INDEX}")
    WHERE="${#LOCKFILES[@]} lockfiles"
else
    # shellcheck disable=SC2034 # read by rs_run_record
    RS_COUNTS=$(jq -c '.[0] | {vulnerabilities, warnings, denied_warnings, denied_by_config}' <<< "${INDEX}")
    WHERE=${LOCKFILE}
fi

if [[ "${JUNIT}" == true ]]; then
    rs_junit_suites "${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "${SUITES}"
    RS_REPORTS+=("${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

FINDINGS=false
OUTCOME=passed
if [[ "${FAILED_CODE}" -ne 0 ]]; then
    FINDINGS=true
    OUTCOME=findings
    if [[ "${REPORT_ONLY}" == true ]]; then
        OUTCOME=findings-reported
    fi
fi
if [[ "${RUN_RECORD}" == true ]]; then
    rs_run_record "${RS_BASE}.run-record.json" audit "${OUTCOME}" "${FAILED_CODE}" "${STARTED}"
fi
MESSAGE="cargo audit found $(jq '.vulnerabilities' <<< "${RS_COUNTS}") vulnerabilities and $(jq '.denied_warnings' <<< "${RS_COUNTS}") denied warnings in ${WHERE}."
if [[ "$(jq '.denied_by_config' <<< "${RS_COUNTS}")" == true ]]; then
    MESSAGE="${MESSAGE} cargo audit's own config (the deny list in .cargo/audit.toml) denied them."
fi
if [[ "${MULTI}" == true && "${FINDINGS}" == true ]]; then
    MESSAGE="${MESSAGE} Findings in: $(jq -r '[.[] | select(.outcome != "passed") | .lockfile] | join(", ")' <<< "${INDEX}")."
fi
rs_gate "${FINDINGS}" "${REPORT_ONLY}" "${MESSAGE}"
