#!/bin/bash
#
# Checks, for the verify_auditable command, that each binary carries the
# dependency list cargo auditable embeds and that it decodes, by reading it
# back with rust-audit-info. Stripping, post-link tools and packaging can
# each remove it without a word, so this checks the final artifact, not the
# build output. Writes the decoded list of each binary as JSON and, with
# cyclonedx, a CycloneDX SBOM made from it by auditable2cdx.

set -euo pipefail

if [[ -z "${SCRIPT_RUST_SECURITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_RUST_SECURITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_RUST_SECURITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CYCLONEDX=$(rs_bool cyclonedx "${PARAM_CYCLONEDX}")
JUNIT=$(rs_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(rs_bool run_record "${PARAM_RUN_RECORD}")
rs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rs_require_jq
rs_tool rust-audit-info
if [[ "${CYCLONEDX}" == true ]]; then
    if ! CDX=$(command -v auditable2cdx); then
        echo "ERROR: cyclonedx needs auditable2cdx, which is not on the PATH. Add auditable2cdx to the install command's" >&2
        echo "  tools, or use install_auditable2cdx." >&2
        exit 1
    fi
fi

rs_list binaries "${PARAM_BINARIES}"
if [[ ${#RS_LIST[@]} -eq 0 ]]; then
    echo "ERROR: binaries names no binary to verify." >&2
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

# shellcheck disable=SC2034 # read by rs_run_record
RS_ARGS=()
RS_INPUTS=()
RS_REPORTS=()
INDEX="[]"
CASES="[]"
MISSING=()
declare -A USED_NAMES=()

echo "Checking ${#BINARIES[@]} binaries for cargo-auditable data..."
for binary in "${BINARIES[@]}"; do
    RS_INPUTS+=("binary:${binary}")
    name=${binary##*/}
    name=${name//[^A-Za-z0-9._-]/_}
    if [[ -n "${USED_NAMES[${name}]:-}" ]]; then
        USED_NAMES[${name}]=$((USED_NAMES[${name}] + 1))
        name="${name}-${USED_NAMES[${name}]}"
    fi
    USED_NAMES[${name}]=1
    base="${RS_BASE}-${name}"
    if ! "${RS_TOOL}" "${binary}" > "${base}.audit.json" 2> "${base}.log" \
        || ! jq -e '.packages | type == "array" and length > 0' "${base}.audit.json" > /dev/null 2>&1; then
        echo "  ${binary}: FAILED: $(head -n 1 "${base}.log")"
        MISSING+=("${binary}")
        rm -f "${base}.audit.json" "${base}.log"
        CASES=$(jq -c --arg binary "${binary}" '. + [{classname: "auditable", name: $binary, status: "failed",
            message: "no cargo-auditable data, or it does not decode"}]' <<< "${CASES}")
        INDEX=$(jq -c --arg binary "${binary}" --arg sha "$(rs_sha256 "${binary}")" \
            '. + [{binary: $binary, sha256: $sha, auditable: false}]' <<< "${INDEX}")
        continue
    fi
    rm -f "${base}.log"
    RS_REPORTS+=("${base}.audit.json")
    packages=$(jq '.packages | length' "${base}.audit.json")
    root=$(jq -r '[.packages[] | select(.root == true) | "\(.name) \(.version)"] | join(", ")' "${base}.audit.json")
    echo "  ${binary}: ok, ${root}, ${packages} packages"
    entry=$(jq -cn --arg binary "${binary}" --arg sha "$(rs_sha256 "${binary}")" --arg report "${base}.audit.json" \
        --argjson packages "${packages}" '{binary: $binary, sha256: $sha, auditable: true, packages: $packages, report: $report}')
    if [[ "${CYCLONEDX}" == true ]]; then
        if ! "${CDX}" "${binary}" > "${base}.cdx.json" 2> "${base}.log" \
            || ! jq -e '.bomFormat == "CycloneDX"' "${base}.cdx.json" > /dev/null 2>&1; then
            echo "ERROR: auditable2cdx could not turn ${binary}'s dependency list into a CycloneDX SBOM. Its output:" >&2
            sed 's/^/  /' "${base}.log" | tail -n 20 >&2
            exit 1
        fi
        rm -f "${base}.log"
        RS_REPORTS+=("${base}.cdx.json")
        entry=$(jq -c --arg sbom "${base}.cdx.json" '. + {sbom: $sbom}' <<< "${entry}")
    fi
    INDEX=$(jq -c --argjson entry "${entry}" '. + [$entry]' <<< "${INDEX}")
    CASES=$(jq -c --arg binary "${binary}" '. + [{classname: "auditable", name: $binary, status: "passed"}]' <<< "${CASES}")
done

jq '{binaries: .}' <<< "${INDEX}" > "${RS_BASE}.json"
RS_REPORTS+=("${RS_BASE}.json")
# shellcheck disable=SC2034 # read by rs_run_record
RS_COUNTS=$(jq -c '{binaries: (.binaries | length), without_auditable_data: ([.binaries[] | select(.auditable | not)] | length)}' "${RS_BASE}.json")
if [[ "${JUNIT}" == true ]]; then
    rs_junit "${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "${PARAM_REPORT_NAME}" "${CASES}"
    RS_REPORTS+=("${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
    if [[ "${RUN_RECORD}" == true ]]; then
        rs_run_record "${RS_BASE}.run-record.json" verify_auditable findings 1 "${STARTED}"
    fi
    echo "ERROR: ${#MISSING[@]} of ${#BINARIES[@]} binaries carry no cargo-auditable data that decodes: ${MISSING[*]}." >&2
    echo "  Build them with cargo auditable (auditable_build), and check that no later step (stripping with" >&2
    echo "  llvm-strip or --strip-section-headers, packers) removes the .dep-v0 section." >&2
    exit 1
fi
if [[ "${RUN_RECORD}" == true ]]; then
    rs_run_record "${RS_BASE}.run-record.json" verify_auditable passed 0 "${STARTED}"
fi
echo "Passed: every binary carries cargo-auditable data that decodes."
