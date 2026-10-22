#!/bin/bash
#
# Writes a licence inventory of every crate in the dependency graph with
# cargo deny list, for the licenses command: an artifact for legal review,
# apart from the pass/fail licences check the deny command runs. It reports
# and never gates, so it fails only when cargo deny list itself fails.

set -euo pipefail

if [[ -z "${SCRIPT_RUST_SECURITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_RUST_SECURITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_RUST_SECURITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST_PATH=$(rs_subst "${PARAM_MANIFEST_PATH}")
CONFIG_PATH=$(rs_subst "${PARAM_CONFIG_PATH}")
METADATA_PATH=$(rs_subst "${PARAM_METADATA_PATH}")
TARGET=$(rs_subst "${PARAM_TARGET}")
LAYOUT=${PARAM_LAYOUT}
ALL_FEATURES=$(rs_bool all_features "${PARAM_ALL_FEATURES}")
NO_DEFAULT_FEATURES=$(rs_bool no_default_features "${PARAM_NO_DEFAULT_FEATURES}")
OFFLINE=$(rs_bool offline "${PARAM_OFFLINE}")
LOCKED=$(rs_bool locked "${PARAM_LOCKED}")
RUN_RECORD=$(rs_bool run_record "${PARAM_RUN_RECORD}")
rs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rs_require_jq
rs_tool cargo-deny
RS_TOOL_VERSION=$("${RS_TOOL}" --version 2> /dev/null || true)

case "${LAYOUT}" in
    crate | license) ;;
    *)
        echo "ERROR: layout must be crate or license, not '${LAYOUT}'." >&2
        exit 1
        ;;
esac
rs_list formats "${PARAM_FORMATS}"
FORMATS=(${RS_LIST[@]+"${RS_LIST[@]}"})
if [[ ${#FORMATS[@]} -eq 0 ]]; then
    echo "ERROR: formats names no format. Use json, tsv or both." >&2
    exit 1
fi
for format in "${FORMATS[@]}"; do
    case "${format}" in
        json | tsv) ;;
        *)
            echo "ERROR: formats takes json and tsv, not '${format}'." >&2
            exit 1
            ;;
    esac
done

ROOT_ARGS=()
# shellcheck disable=SC2034 # read by rs_run_record
RS_INPUTS=()
if [[ -n "${MANIFEST_PATH}" ]]; then
    ROOT_ARGS+=(--manifest-path "${MANIFEST_PATH}")
fi
if [[ -n "${CONFIG_PATH}" ]]; then
    if [[ ! -f "${CONFIG_PATH}" ]]; then
        echo "ERROR: config_path ${CONFIG_PATH} does not exist (in $(pwd))." >&2
        exit 1
    fi
    ROOT_ARGS+=(--config "${CONFIG_PATH}")
fi
if [[ -n "${METADATA_PATH}" ]]; then
    if [[ ! -f "${METADATA_PATH}" ]]; then
        echo "ERROR: metadata_path ${METADATA_PATH} does not exist (in $(pwd))." >&2
        exit 1
    fi
    ROOT_ARGS+=(--metadata-path "${METADATA_PATH}")
fi
# The config (licence clarifications can change the inventory), lockfile and
# manifests or metadata, for the run record.
if [[ "${RUN_RECORD}" == true ]]; then
    rs_deny_record_inputs "${MANIFEST_PATH}" "${CONFIG_PATH}" "${METADATA_PATH}"
fi
rs_list features "${PARAM_FEATURES}"
if [[ ${#RS_LIST[@]} -gt 0 ]]; then
    ROOT_ARGS+=(--features "$(IFS=,; printf '%s' "${RS_LIST[*]}")")
fi
if [[ "${ALL_FEATURES}" == true ]]; then
    ROOT_ARGS+=(--all-features)
fi
if [[ "${NO_DEFAULT_FEATURES}" == true ]]; then
    ROOT_ARGS+=(--no-default-features)
fi
if [[ -n "${TARGET}" ]]; then
    ROOT_ARGS+=(--target "${TARGET}")
fi
if [[ "${OFFLINE}" == true ]]; then
    ROOT_ARGS+=(--offline)
fi
if [[ "${LOCKED}" == true ]]; then
    ROOT_ARGS+=(--locked)
fi
RS_ARGS=(${ROOT_ARGS[@]+"${ROOT_ARGS[@]}"} list --layout "${LAYOUT}")
RS_REPORTS=()

for format in "${FORMATS[@]}"; do
    file="${RS_BASE}.${format}"
    echo "Listing licences as ${format} with ${RS_TOOL_VERSION:-cargo-deny}..."
    rc=0
    "${RS_TOOL}" "${RS_ARGS[@]}" --format "${format}" > "${file}" 2> "${RS_BASE}.log" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        echo "ERROR: cargo deny list failed (exit code ${rc}). Its output:" >&2
        sed 's/^/  /' "${RS_BASE}.log" | tail -n 40 >&2
        if [[ "${RUN_RECORD}" == true ]]; then
            RS_REPORTS+=("${RS_BASE}.log")
            rs_run_record "${RS_BASE}.run-record.json" licenses error "${rc}" "${STARTED}"
        fi
        exit 1
    fi
    RS_REPORTS+=("${file}")
done
rm -f "${RS_BASE}.log"

if [[ -f "${RS_BASE}.json" ]]; then
    if [[ "${LAYOUT}" == crate ]]; then
        # shellcheck disable=SC2016 # jq program, not shell
        COUNTS=$(jq -c '{crates: length, licenses: ([.[].licenses[]] | unique | length),
            unlicensed: ([to_entries[] | select((.value.licenses | length) == 0)] | length)}' "${RS_BASE}.json")
        jq -r 'to_entries[] | "  \(.key | split(" ")[:2] | join(" ")): \(.value.licenses | join(", ") | if . == "" then "(none)" else . end)"' "${RS_BASE}.json"
    else
        COUNTS=$(jq -c '{licenses: (.licenses | length), unlicensed: (.unlicensed | length)}' "${RS_BASE}.json")
        jq -r '.licenses[] | "  \(.[0]): \(.[1] | length) crates"' "${RS_BASE}.json"
    fi
    # shellcheck disable=SC2034 # read by rs_run_record
    RS_COUNTS=${COUNTS}
fi
if [[ "${RUN_RECORD}" == true ]]; then
    rs_run_record "${RS_BASE}.run-record.json" licenses passed 0 "${STARTED}"
fi
echo "Wrote the licence inventory to ${RS_OUT}: $(printf '%s ' "${RS_REPORTS[@]##*/}")"
