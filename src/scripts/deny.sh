#!/bin/bash
#
# Runs cargo deny check for the deny command, and writes cargo-deny's JSON
# diagnostics, a SARIF report and, when asked, JUnit XML and a run record.
# The project's deny.toml is the policy: this script passes it through.
#
# cargo-deny's exit code is a bitmask of the checks that failed (advisories
# 1, bans 2, licenses 4, sources 8), which overlaps the codes it fails with.
# A check that completes always ends its JSON output with a summary line, so
# that is what tells findings from a failure: a failure stops the step even
# with report_only. Its SARIF output exits 0 whatever it found, so SARIF is
# written by a second pass, offline, after the JSON pass decided.

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
WORKSPACE=$(rs_bool workspace "${PARAM_WORKSPACE}")
EXCLUDE_DEV=$(rs_bool exclude_dev "${PARAM_EXCLUDE_DEV}")
ALL_FEATURES=$(rs_bool all_features "${PARAM_ALL_FEATURES}")
NO_DEFAULT_FEATURES=$(rs_bool no_default_features "${PARAM_NO_DEFAULT_FEATURES}")
OFFLINE=$(rs_bool offline "${PARAM_OFFLINE}")
LOCKED=$(rs_bool locked "${PARAM_LOCKED}")
FROZEN=$(rs_bool frozen "${PARAM_FROZEN}")
AUDIT_COMPATIBLE=$(rs_bool audit_compatible_output "${PARAM_AUDIT_COMPATIBLE_OUTPUT}")
REQUIRE_REASONS=$(rs_bool require_ignore_reasons "${PARAM_REQUIRE_IGNORE_REASONS}")
SARIF=$(rs_bool sarif "${PARAM_SARIF}")
JUNIT=$(rs_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(rs_bool report_only "${PARAM_REPORT_ONLY}")
RUN_RECORD=$(rs_bool run_record "${PARAM_RUN_RECORD}")
EXTRA_ARGS=$(rs_subst "${PARAM_EXTRA_ARGS}")
rs_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${RS_WORDS[@]+"${RS_WORDS[@]}"})
rs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rs_require_jq
rs_tool cargo-deny
RS_TOOL_VERSION=$("${RS_TOOL}" --version 2> /dev/null || true)

for word in ${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"}; do
    case "${word}" in
        -f | --format | --format=* | -f?*)
            echo "ERROR: extra_args can't set ${word}: deny writes the JSON and SARIF reports itself." >&2
            exit 1
            ;;
    esac
done

# Options cargo-deny reads before "check" (from 0.20, every option it shares
# with "list" goes there).
ROOT_ARGS=()
if [[ -n "${MANIFEST_PATH}" ]]; then
    ROOT_ARGS+=(--manifest-path "${MANIFEST_PATH}")
fi
if [[ -n "${CONFIG_PATH}" ]]; then
    # cargo-deny falls back to its default config, which rejects every
    # licence, when --config names a file that doesn't exist.
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
if [[ "${WORKSPACE}" == true ]]; then
    ROOT_ARGS+=(--workspace)
fi
rs_list exclude "${PARAM_EXCLUDE}"
for crate in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
    ROOT_ARGS+=(--exclude "${crate}")
done
if [[ "${EXCLUDE_DEV}" == true ]]; then
    ROOT_ARGS+=(--exclude-dev)
fi
rs_list features "${PARAM_FEATURES}"
if [[ ${#RS_LIST[@]} -gt 0 ]]; then
    FEATURE_LIST=$(IFS=,; printf '%s' "${RS_LIST[*]}")
    ROOT_ARGS+=(--features "${FEATURE_LIST}")
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
if [[ "${FROZEN}" == true ]]; then
    ROOT_ARGS+=(--frozen)
else
    if [[ "${OFFLINE}" == true ]]; then
        ROOT_ARGS+=(--offline)
    fi
    if [[ "${LOCKED}" == true ]]; then
        ROOT_ARGS+=(--locked)
    fi
fi

CHECK_ARGS=(check)
rs_list checks "${PARAM_CHECKS}"
for check in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
    case "${check}" in
        advisories | bans | licenses | sources | all) CHECK_ARGS+=("${check}") ;;
        *)
            echo "ERROR: checks takes advisories, bans, licenses, sources and all, not '${check}'." >&2
            exit 1
            ;;
    esac
done
for level in allow warn deny; do
    var="PARAM_${level^^}"
    rs_list "${level}" "${!var}"
    for code in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
        CHECK_ARGS+=("--${level}" "${code}")
    done
done
if [[ "${AUDIT_COMPATIBLE}" == true ]]; then
    CHECK_ARGS+=(--audit-compatible-output)
fi
CHECK_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})
RS_ARGS=(${ROOT_ARGS[@]+"${ROOT_ARGS[@]}"} "${CHECK_ARGS[@]}")

# The inputs and the advisory database, for the run record.
RS_INPUTS=()
rs_deny_inputs "${MANIFEST_PATH}" "${CONFIG_PATH}"
if [[ -n "${METADATA_PATH}" ]]; then
    RS_INPUTS+=("metadata:${METADATA_PATH}")
fi
rs_deny_db
RS_REPORTS=()
JSONL="${RS_BASE}.jsonl"

echo "Running cargo deny ${CHECK_ARGS[*]} with ${RS_TOOL_VERSION:-cargo-deny}..."
RC=0
"${RS_TOOL}" --format json --log-level info "${RS_ARGS[@]}" 2> "${JSONL}" > "${RS_BASE}.audit.json" || RC=$?
if [[ "${AUDIT_COMPATIBLE}" == true && -s "${RS_BASE}.audit.json" ]]; then
    RS_REPORTS+=("${RS_BASE}.audit.json")
else
    rm -f "${RS_BASE}.audit.json"
fi
SUMMARY=$(jq -c 'select(.type? == "summary") | .fields' "${JSONL}" 2> /dev/null | tail -n 1) || SUMMARY=""
if [[ -z "${SUMMARY}" ]]; then
    echo "ERROR: cargo deny did not complete (exit code ${RC}), so there is no report. Its errors:" >&2
    if ! jq -r 'select(.type? == "log" and .fields.level == "ERROR") | "  " + .fields.message' "${JSONL}" 2> /dev/null | grep . >&2; then
        sed 's/^/  /' "${JSONL}" | tail -n 40 >&2
    fi
    if [[ "${RUN_RECORD}" == true ]]; then
        RS_REPORTS+=("${JSONL}")
        rs_run_record "${RS_BASE}.run-record.json" deny error "${RC}" "${STARTED}"
    fi
    exit 1
fi
RS_REPORTS+=("${JSONL}")

if [[ "${SARIF}" == true ]]; then
    SARIF_ARGS=(--format sarif ${ROOT_ARGS[@]+"${ROOT_ARGS[@]}"})
    if [[ "${FROZEN}" != true && "${OFFLINE}" != true ]]; then
        SARIF_ARGS+=(--offline)
    fi
    SARIF_RC=0
    "${RS_TOOL}" "${SARIF_ARGS[@]}" "${CHECK_ARGS[@]}" > "${RS_BASE}.sarif" 2> "${RS_BASE}.sarif.log" || SARIF_RC=$?
    if ! rs_json_is "${RS_BASE}.sarif" '.version == "2.1.0" and (.runs | type == "array")'; then
        echo "ERROR: cargo deny did not write a SARIF report. Its output:" >&2
        sed 's/^/  /' "${RS_BASE}.sarif.log" | tail -n 20 >&2
        if [[ "${RUN_RECORD}" == true ]]; then
            RS_REPORTS+=("${RS_BASE}.sarif.log")
            rs_run_record "${RS_BASE}.run-record.json" deny error "${SARIF_RC}" "${STARTED}"
        fi
        exit 1
    fi
    rm -f "${RS_BASE}.sarif.log"
    RS_REPORTS+=("${RS_BASE}.sarif")
fi

# Advisories ignored in deny.toml without a reason: cargo-deny notes each
# ignore that applied, with its reason as a label when it has one.
MISSING_REASONS=$(jq -c 'select(.type? == "diagnostic" and (.fields.code == "advisory-ignored" or .fields.code == "yanked-ignored"))
    | select([.fields.labels[]?.message] | index("ignore reason") | not)
    | .fields.labels[0].span' "${JSONL}" | jq -sc '.')
# shellcheck disable=SC2034 # read by rs_run_record
RS_COUNTS=$(jq -c --argjson missing "${MISSING_REASONS}" '. + {ignores_without_reason: ($missing | length)}' <<< "${SUMMARY}")

echo "cargo deny results:"
jq -r 'to_entries[] | "  \(.key): \(.value.errors) errors, \(.value.warnings) warnings"' <<< "${SUMMARY}"
# shellcheck disable=SC2016 # jq program, not shell
jq -r 'select(.type? == "diagnostic" and (.fields.severity == "error" or .fields.severity == "warning")) | .fields
    | "  \(.severity)[\(.code)] \(.advisory.id // "")\(if .advisory then " " else "" end)\(.graphs[0].Krate.name // "") \(.graphs[0].Krate.version // ""): \(.message)"' "${JSONL}"
if [[ "${REQUIRE_REASONS}" == true && "${MISSING_REASONS}" != "[]" ]]; then
    echo "Ignored without a reason in deny.toml: $(jq -r 'join(", ")' <<< "${MISSING_REASONS}")"
fi

if [[ "${JUNIT}" == true ]]; then
    # shellcheck disable=SC2016 # jq program, not shell
    CASES=$(jq -c 'select(.type? == "diagnostic" and (.fields.severity == "error" or .fields.severity == "warning")) | .fields | .code as $code | {
            classname: "cargo-deny.\(.code)",
            name: ([.advisory.id, (.graphs[0].Krate | if . then "\(.name) \(.version)" else null end)] | map(select(. != null)) | join(" ") | if . == "" then $code else . end),
            status: (if .severity == "error" then "failed" else "skipped" end),
            message: .message,
            detail: ((.notes // []) | join("\n"))
        }' "${JSONL}" | jq -sc --argjson missing "${MISSING_REASONS}" --arg require "${REQUIRE_REASONS}" \
        '. + (if $require == "true" then [$missing[] | {classname: "cargo-deny.ignore-reason", name: ., status: "failed",
            message: "ignored in deny.toml without a reason"}] else [] end)')
    rs_junit "${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "${PARAM_REPORT_NAME}" "${CASES}"
    RS_REPORTS+=("${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

FINDINGS=false
MESSAGE="cargo deny $(jq -r '[to_entries[] | select(.value.errors > 0) | .key] | if length == 0 then "found no errors" else "failed: " + join(", ") end' <<< "${SUMMARY}")."
if [[ "${RC}" -ne 0 ]]; then
    FINDINGS=true
fi
if [[ "${REQUIRE_REASONS}" == true && "${MISSING_REASONS}" != "[]" ]]; then
    FINDINGS=true
    MESSAGE="${MESSAGE} $(jq 'length' <<< "${MISSING_REASONS}") ignored advisories have no reason in deny.toml (require_ignore_reasons)."
fi
OUTCOME=passed
if [[ "${FINDINGS}" == true ]]; then
    OUTCOME=findings
    if [[ "${REPORT_ONLY}" == true ]]; then
        OUTCOME=findings-reported
    fi
fi
if [[ "${RUN_RECORD}" == true ]]; then
    rs_run_record "${RS_BASE}.run-record.json" deny "${OUTCOME}" "${RC}" "${STARTED}"
fi
rs_gate "${FINDINGS}" "${REPORT_ONLY}" "${MESSAGE}"
