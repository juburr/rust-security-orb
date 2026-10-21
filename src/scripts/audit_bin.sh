#!/bin/bash
#
# Runs cargo audit bin over built binaries for the audit_bin command: it
# checks the dependencies a binary was actually built with, which
# cargo-auditable embeds in it, rather than a lockfile's superset of every
# configuration. Writes one JSON report (and SARIF report) per binary, an
# index of them, and, when asked, JUnit XML and a run record.
#
# cargo audit bin reports nothing per binary in its JSON output that says
# which binary a report is for, so each binary is scanned on its own. As with
# audit, a scan that completes prints its whole JSON report and one that fails
# prints nothing; a binary with no dependency information at all (not built
# with cargo auditable, and no dependency paths cargo audit could recover)
# can't be scanned, which fails the step even with report_only.

set -euo pipefail

if [[ -z "${SCRIPT_RUST_SECURITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_RUST_SECURITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_RUST_SECURITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SARIF=$(rs_bool sarif "${PARAM_SARIF}")
JUNIT=$(rs_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(rs_bool report_only "${PARAM_REPORT_ONLY}")
RUN_RECORD=$(rs_bool run_record "${PARAM_RUN_RECORD}")
REQUIRE_AUDITABLE=$(rs_bool require_auditable "${PARAM_REQUIRE_AUDITABLE}")
rs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rs_audit_extra_args
rs_require_jq
rs_tool cargo-audit
if [[ "${REQUIRE_AUDITABLE}" == true ]]; then
    if ! AUDIT_INFO=$(command -v rust-audit-info); then
        echo "ERROR: require_auditable needs rust-audit-info, which is not on the PATH. Add rust-audit-info to the" >&2
        echo "  install command's tools, or use install_rust_audit_info." >&2
        exit 1
    fi
fi

# Every binary named, with shell patterns expanded. A pattern that matches
# nothing, and a name that isn't a file, fail the step: a binary that isn't
# there can't pass an audit.
rs_list binaries "${PARAM_BINARIES}"
if [[ ${#RS_LIST[@]} -eq 0 ]]; then
    echo "ERROR: binaries names no binary to audit." >&2
    exit 1
fi
BINARIES=()
shopt -s nullglob
for pattern in "${RS_LIST[@]}"; do
    # The pattern is expanded here on purpose.
    # shellcheck disable=SC2206
    matches=(${pattern})
    if [[ ${#matches[@]} -eq 0 ]]; then
        echo "ERROR: binaries names ${pattern}, which matches no file (in $(pwd))." >&2
        exit 1
    fi
    for file in "${matches[@]}"; do
        if [[ ! -f "${file}" ]]; then
            echo "ERROR: ${file} is not a file." >&2
            exit 1
        fi
        BINARIES+=("${file}")
    done
done
shopt -u nullglob

rs_audit_options
RS_TOOL_VERSION=$("${RS_TOOL}" --version 2> /dev/null || true)
# The options every scan shares, for the run record.
# shellcheck disable=SC2034 # read by rs_run_record
RS_ARGS=(audit ${RS_AUDIT_OPTS[@]+"${RS_AUDIT_OPTS[@]}"} ${RS_EXTRA[@]+"${RS_EXTRA[@]}"} bin)
RS_INPUTS=()
RS_REPORTS=()
INDEX="[]"
CASES="[]"
CODES=0
FAILED_CODE=0
MISSING=()
declare -A USED_NAMES=()

echo "Auditing ${#BINARIES[@]} binaries with ${RS_TOOL_VERSION:-cargo-audit}..."
for binary in "${BINARIES[@]}"; do
    RS_INPUTS+=("binary:${binary}")
    name=${binary##*/}
    name=${name//[^A-Za-z0-9._-]/_}
    # A second binary with the same name gets the first free <name>-<n>.
    candidate=${name}
    n=1
    while [[ -n "${USED_NAMES[${candidate}]:-}" ]]; do
        n=$((n + 1))
        candidate="${name}-${n}"
    done
    name=${candidate}
    USED_NAMES[${name}]=1
    base="${RS_BASE}-${name}"
    if [[ "${REQUIRE_AUDITABLE}" == true ]] && ! "${AUDIT_INFO}" "${binary}" > /dev/null 2> "${base}.audit-info.log"; then
        echo "  ${binary}: no cargo-auditable data ($(head -n 1 "${base}.audit-info.log"))"
        MISSING+=("${binary}")
    fi
    rm -f "${base}.audit-info.log"
    # Only the first scan may fetch the database; the others read that copy.
    OPTS=()
    if [[ "${RS_NO_FETCH}" != true && "${CODES}" -gt 0 ]]; then
        OPTS+=(--no-fetch)
    fi
    CODES=$((CODES + 1))
    rc=0
    "${RS_TOOL}" audit ${RS_AUDIT_OPTS[@]+"${RS_AUDIT_OPTS[@]}"} ${OPTS[@]+"${OPTS[@]}"} ${RS_EXTRA[@]+"${RS_EXTRA[@]}"} \
        --json bin "${binary}" > "${base}.json" 2> "${base}.log" || rc=$?
    if ! jq -e 'type == "object" and (.vulnerabilities | type == "object")' "${base}.json" > /dev/null 2>&1; then
        echo "ERROR: cargo audit bin could not audit ${binary} (exit code ${rc}). Its output:" >&2
        sed 's/^/  /' "${base}.log" | tail -n 20 >&2
        if grep -q "No dependency information found" "${base}.log"; then
            echo "  ${binary} carries no dependency information: build it with cargo auditable (see auditable_build)." >&2
        fi
        if [[ "${RUN_RECORD}" == true ]]; then
            RS_REPORTS+=("${base}.log")
            rs_run_record "${RS_BASE}.run-record.json" audit_bin error "${rc}" "${STARTED}"
        fi
        exit 1
    fi
    RS_REPORTS+=("${base}.json")
    if ! rs_audit_check "${base}.log" "${base}.json" "${rc}"; then
        echo "ERROR: The audit of ${binary} can't be trusted, so the step stops." >&2
        if [[ "${RUN_RECORD}" == true ]]; then
            RS_REPORTS+=("${base}.log")
            rs_run_record "${RS_BASE}.run-record.json" audit_bin error "${rc}" "${STARTED}"
        fi
        exit 1
    fi
    if [[ -s "${base}.log" ]]; then
        RS_REPORTS+=("${base}.log")
    else
        rm -f "${base}.log"
    fi
    if [[ "${rc}" -ne 0 ]]; then
        FAILED_CODE=${rc}
    fi
    if [[ "${SARIF}" == true ]]; then
        OPTS=()
        if [[ "${RS_NO_FETCH}" != true ]]; then
            OPTS+=(--no-fetch)
        fi
        "${RS_TOOL}" audit ${RS_AUDIT_OPTS[@]+"${RS_AUDIT_OPTS[@]}"} ${OPTS[@]+"${OPTS[@]}"} ${RS_EXTRA[@]+"${RS_EXTRA[@]}"} \
            --format sarif bin "${binary}" > "${base}.sarif" 2> "${base}.sarif.log" || true
        if ! jq -e '.version == "2.1.0"' "${base}.sarif" > /dev/null 2>&1; then
            echo "ERROR: cargo audit bin did not write a SARIF report for ${binary}. Its output:" >&2
            sed 's/^/  /' "${base}.sarif.log" | tail -n 20 >&2
            exit 1
        fi
        rm -f "${base}.sarif.log"
        RS_REPORTS+=("${base}.sarif")
    fi
    counts=$(rs_audit_counts "${base}.json" "${rc}")
    INDEX=$(jq -c --arg binary "${binary}" --arg sha "$(rs_sha256 "${binary}")" --arg report "${base}.json" --argjson counts "${counts}" \
        '. + [{binary: $binary, sha256: $sha, report: $report} + $counts]' <<< "${INDEX}")
    echo "  ${binary}: $(jq -r '"\(.vulnerabilities) vulnerabilities, \(.denied_warnings) denied warnings"' <<< "${counts}")"
    rs_audit_summary "${base}.json" "    "
    if [[ "${JUNIT}" == true ]]; then
        CASES=$(jq -c --argjson more "$(rs_audit_cases "${base}.json" "cargo-audit-bin.${name}" "${rc}")" '. + $more' <<< "${CASES}")
    fi
done

jq --argjson missing "$(printf '%s\n' ${MISSING[@]+"${MISSING[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))')" \
    '{binaries: ., without_auditable_data: $missing}' <<< "${INDEX}" > "${RS_BASE}.json"
RS_REPORTS+=("${RS_BASE}.json")
# shellcheck disable=SC2034 # read by rs_run_record
RS_COUNTS=$(jq -c '{binaries: (.binaries | length), vulnerabilities: ([.binaries[].vulnerabilities] | add),
    denied_warnings: ([.binaries[].denied_warnings] | add), denied_by_config: ([.binaries[].denied_by_config] | any),
    without_auditable_data: (.without_auditable_data | length)}' "${RS_BASE}.json")

if [[ "${JUNIT}" == true ]]; then
    if [[ "${REQUIRE_AUDITABLE}" == true ]]; then
        for binary in ${MISSING[@]+"${MISSING[@]}"}; do
            CASES=$(jq -c --arg binary "${binary}" '. + [{classname: "cargo-audit-bin.auditable", name: $binary, status: "failed",
                message: "no cargo-auditable data: build it with cargo auditable"}]' <<< "${CASES}")
        done
    fi
    rs_junit "${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "${PARAM_REPORT_NAME}" "${CASES}"
    RS_REPORTS+=("${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

FINDINGS=false
MESSAGE="cargo audit bin found $(jq '.vulnerabilities' <<< "${RS_COUNTS}") vulnerabilities and $(jq '.denied_warnings' <<< "${RS_COUNTS}") denied warnings in ${#BINARIES[@]} binaries."
if [[ "${FAILED_CODE}" -ne 0 ]]; then
    FINDINGS=true
fi
if [[ "$(jq '.denied_by_config' <<< "${RS_COUNTS}")" == true ]]; then
    MESSAGE="${MESSAGE} cargo audit's own config (the deny list in .cargo/audit.toml) denied warnings."
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
    FINDINGS=true
    MESSAGE="${MESSAGE} ${#MISSING[@]} carry no cargo-auditable data (require_auditable): ${MISSING[*]}."
fi
OUTCOME=passed
if [[ "${FINDINGS}" == true ]]; then
    OUTCOME=findings
    if [[ "${REPORT_ONLY}" == true ]]; then
        OUTCOME=findings-reported
    fi
fi
if [[ "${RUN_RECORD}" == true ]]; then
    rs_run_record "${RS_BASE}.run-record.json" audit_bin "${OUTCOME}" "${FAILED_CODE}" "${STARTED}"
fi
rs_gate "${FINDINGS}" "${REPORT_ONLY}" "${MESSAGE}"
