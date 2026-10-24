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

VALUE=false
for word in ${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"}; do
    # The value of the option before it.
    if [[ "${VALUE}" == true ]]; then
        VALUE=false
        continue
    fi
    case "${word}" in
        -f | --format | --format=* | -f?*)
            echo "ERROR: extra_args can't set ${word}: deny writes the JSON and SARIF reports itself." >&2
            exit 1
            ;;
        --audit-compatible-output)
            echo "ERROR: extra_args can't set ${word}: use the audit_compatible_output parameter, which keeps the report it writes." >&2
            exit 1
            ;;
        --graph | --warn | --allow | --deny | --feature-depth) VALUE=true ;;
        # extra_args goes after "check", whose only other arguments are the
        # checks to run, which decide whether the run record names an
        # advisory database.
        -- | [!-]* | -)
            echo "ERROR: extra_args can't hold ${word}: cargo deny would read it as a check to run, which the run record" >&2
            echo "  wouldn't follow. To choose the checks, use the checks parameter." >&2
            exit 1
            ;;
        --*) ;;
        # Short options can be grouped, as in -sA: s and h take no value; any
        # other option's value is the rest of the word, or else the next word.
        -?*)
            FLAGS=${word#-}
            while [[ "${FLAGS}" == [sh]* ]]; do
                FLAGS=${FLAGS:1}
            done
            if [[ "${FLAGS}" == f* ]]; then
                echo "ERROR: extra_args can't set ${word}: deny writes the JSON and SARIF reports itself." >&2
                exit 1
            elif [[ ${#FLAGS} -eq 1 ]]; then
                VALUE=true
            fi
            ;;
    esac
done

# One manifest, whose reports are <report_name>.*, or several, each with
# reports of its own, <report_name>-<slug>.*.
rs_list_lines manifest_paths "${PARAM_MANIFEST_PATHS}"
MULTI=false
if [[ ${#RS_LIST[@]} -gt 0 ]]; then
    if [[ -n "${MANIFEST_PATH}" ]]; then
        echo "ERROR: manifest_path and manifest_paths are both set. Name one Cargo.toml in manifest_path, or several in manifest_paths." >&2
        exit 1
    fi
    if [[ -n "${METADATA_PATH}" ]]; then
        echo "ERROR: metadata_path describes one workspace, so it can't go with manifest_paths." >&2
        exit 1
    fi
    MULTI=true
    rs_files manifest_paths
    MANIFESTS=("${RS_FILES[@]}")
else
    MANIFESTS=("${MANIFEST_PATH}")
fi
BASES=()
SLUG_LIST=()
declare -A SLUGS=()
for manifest in "${MANIFESTS[@]}"; do
    if [[ "${MULTI}" == true ]]; then
        rs_slug "${manifest}" Cargo.toml
        if [[ -n "${SLUGS[${RS_SLUG}]:-}" ]]; then
            echo "ERROR: manifest_paths names ${SLUGS[${RS_SLUG}]} and ${manifest}, whose reports would both be named ${PARAM_REPORT_NAME}-${RS_SLUG}." >&2
            exit 1
        fi
        SLUGS[${RS_SLUG}]=${manifest}
        SLUG_LIST+=("${RS_SLUG}")
        BASES+=("${RS_BASE}-${RS_SLUG}")
    else
        SLUG_LIST+=("")
        BASES+=("${RS_BASE}")
    fi
done

# Options cargo-deny reads before "check" (from 0.20, every option it shares
# with "list" goes there), but --manifest-path, which each manifest's check
# puts first.
ROOT_ARGS=()
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
# cargo deny reads the advisory database only for the advisories check, which
# runs when checks names it or all, or names nothing.
READS_DB=false
if [[ ${#RS_LIST[@]} -eq 0 ]]; then
    READS_DB=true
fi
for check in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
    case "${check}" in
        advisories | all)
            READS_DB=true
            CHECK_ARGS+=("${check}")
            ;;
        bans | licenses | sources) CHECK_ARGS+=("${check}") ;;
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
# The arguments every manifest's check shares, for the run record; with one
# manifest, its --manifest-path too.
RS_ARGS=(${ROOT_ARGS[@]+"${ROOT_ARGS[@]}"} "${CHECK_ARGS[@]}")
if [[ "${MULTI}" != true && -n "${MANIFEST_PATH}" ]]; then
    RS_ARGS=(--manifest-path "${MANIFEST_PATH}" "${RS_ARGS[@]}")
fi
# shellcheck disable=SC2034 # read by rs_run_record
RS_INPUTS=()
RS_REPORTS=()
# What a diagnostic is about, for the log and JUnit: its advisory's ID and
# crate. A diagnostic about an entry in deny.toml, such as an ignore that
# matched nothing, has no advisory object, so the ID (or for a yanked crate,
# the crate spec) comes from the label cargo-deny puts on that entry.
# shellcheck disable=SC2016 # jq program, not shell
DENY_SUBJECT_JQ='
    def subject: [(.advisory.id // ([.labels[]? | select(.message == "no crate matched advisory criteria"
            or .message == "unknown advisory" or .message == "advisory ignored here"
            or .message == "yanked crate not detected" or .message == "yanked ignore") | .span] | .[0])),
        (.graphs[0].Krate | if . then "\(.name) \(.version)" else null end)] | map(select(. != null)) | join(" ");
'

# deny_error CODE: stops the step for a cargo deny that didn't complete,
# with an error run record.
deny_error() {
    if [[ "${RUN_RECORD}" == true ]]; then
        rs_run_record "${RS_BASE}.run-record.json" deny error "$1" "${STARTED}"
    fi
    exit 1
}

INDEX="[]"
SUITES="[]"
FAILED_CODE=0
MISSING_TOTAL=0
DB_SEEN=""
DB_VARIES=false
for ((i = 0; i < ${#MANIFESTS[@]}; i++)); do
    manifest=${MANIFESTS[i]}
    base=${BASES[i]}
    JSONL="${base}.jsonl"
    MANIFEST_ARGS=()
    if [[ -n "${manifest}" ]]; then
        MANIFEST_ARGS=(--manifest-path "${manifest}")
    fi
    ARGS=(${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} ${ROOT_ARGS[@]+"${ROOT_ARGS[@]}"} "${CHECK_ARGS[@]}")
    # The inputs, for the run record.
    if [[ "${RUN_RECORD}" == true ]]; then
        rs_deny_record_inputs "${manifest}" "${CONFIG_PATH}" "${METADATA_PATH}"
    fi

    echo "Checking${manifest:+ ${manifest}} with ${RS_TOOL_VERSION:-cargo-deny}..."
    rs_show_command "${RS_TOOL##*/}" --format json --log-level info "${ARGS[@]}"
    rc=0
    "${RS_TOOL}" --format json --log-level info "${ARGS[@]}" 2> "${JSONL}" > "${base}.audit.json" || rc=$?
    # The database cargo deny read, which it fetched just now unless offline.
    # Each manifest's check can fetch, and each can have a deny.toml of its
    # own, so the run record names a database only when they all read the
    # same one at the same commit.
    if [[ "${RUN_RECORD}" == true && "${READS_DB}" == true ]]; then
        rs_deny_db
        db="${RS_DB}@$(git -C "${RS_DB:-/nonexistent}" log -1 --format=%H 2> /dev/null || true)"
        if [[ "${i}" -gt 0 && "${db}" != "${DB_SEEN}" ]]; then
            DB_VARIES=true
        fi
        DB_SEEN=${db}
    fi
    if [[ "${AUDIT_COMPATIBLE}" == true && -s "${base}.audit.json" ]]; then
        RS_REPORTS+=("${base}.audit.json")
    else
        rm -f "${base}.audit.json"
    fi
    SUMMARY=$(jq -c 'select(.type? == "summary") | .fields' "${JSONL}" 2> /dev/null | tail -n 1) || SUMMARY=""
    if [[ -z "${SUMMARY}" ]]; then
        echo "ERROR: cargo deny did not complete (exit code ${rc}), so there is no report. Its errors:" >&2
        if ! jq -r 'select(.type? == "log" and .fields.level == "ERROR") | "  " + .fields.message' "${JSONL}" 2> /dev/null | grep . >&2; then
            sed 's/^/  /' "${JSONL}" | tail -n 40 >&2
        fi
        RS_REPORTS+=("${JSONL}")
        deny_error "${rc}"
    fi
    RS_REPORTS+=("${JSONL}")
    # With [bans.std-replacements], cargo deny skips that check when it can't
    # load the std-replacement-data it fetches into TMPDIR (offline doesn't
    # fetch it), logs an error, and still reports bans as passed.
    STD_DATA_ERROR=$(jq -rR 'fromjson? | select(.type? == "log" and .fields.level? == "ERROR"
        and (.fields.message? // "" | startswith("failed to load std-replacement-data"))) | .fields.message' "${JSONL}" 2> /dev/null) || STD_DATA_ERROR=""
    if [[ -n "${STD_DATA_ERROR}" ]]; then
        echo "ERROR: cargo deny skipped its [bans.std-replacements] check: ${STD_DATA_ERROR%%$'\n'*}" >&2
        echo "  offline stops it fetching that data. Run cargo deny fetch std-replacement earlier in the job, or leave offline off." >&2
        deny_error "${rc}"
    fi

    if [[ "${SARIF}" == true ]]; then
        SARIF_ARGS=(--format sarif ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} ${ROOT_ARGS[@]+"${ROOT_ARGS[@]}"})
        if [[ "${FROZEN}" != true && "${OFFLINE}" != true ]]; then
            SARIF_ARGS+=(--offline)
        fi
        sarif_rc=0
        "${RS_TOOL}" "${SARIF_ARGS[@]}" "${CHECK_ARGS[@]}" > "${base}.sarif" 2> "${base}.sarif.log" || sarif_rc=$?
        if ! rs_json_is "${base}.sarif" '.version == "2.1.0" and (.runs | type == "array")'; then
            echo "ERROR: cargo deny did not write a SARIF report. Its output:" >&2
            sed 's/^/  /' "${base}.sarif.log" | tail -n 20 >&2
            RS_REPORTS+=("${base}.sarif.log")
            deny_error "${sarif_rc}"
        fi
        rm -f "${base}.sarif.log"
        RS_REPORTS+=("${base}.sarif")
    fi

    # Advisories and yanked crates ignored in deny.toml without a reason:
    # cargo-deny notes each ignore that applied, with its reason as a label
    # when it has one, whose span is the reason's text: "ignore reason" for
    # an advisory, "reason" for a yanked crate. A reason of only spaces, or
    # "", gives none.
    # shellcheck disable=SC2016 # jq program, not shell
    missing=$(jq -c 'select(.type? == "diagnostic" and (.fields.code == "advisory-ignored" or .fields.code == "yanked-ignored"))
        | .fields | (if .code == "yanked-ignored" then "reason" else "ignore reason" end) as $reason_label
        | select([.labels[]? | select(.message == $reason_label and ((.span // "") | test("[^[:space:]]")))] | length == 0)
        | .labels[0].span' "${JSONL}" | jq -sc '.')
    counts=$(jq -c --argjson missing "${missing}" '. + {ignores_without_reason: ($missing | length)}' <<< "${SUMMARY}")

    echo "cargo deny results${manifest:+ for ${manifest}}:"
    jq -r 'to_entries[] | "  \(.key): \(.value.errors) errors, \(.value.warnings) warnings"' <<< "${SUMMARY}"
    jq -r "${DENY_SUBJECT_JQ}"'select(.type? == "diagnostic" and (.fields.severity == "error" or .fields.severity == "warning")) | .fields
        | "  \(.severity)[\(.code)]\(subject | if . == "" then "" else " " + . end): \(.message)"' "${JSONL}"
    if [[ "${REQUIRE_REASONS}" == true && "${missing}" != "[]" ]]; then
        echo "Ignored without a reason in deny.toml: $(jq -r 'join(", ")' <<< "${missing}")"
        MISSING_TOTAL=$((MISSING_TOTAL + $(jq 'length' <<< "${missing}")))
    fi

    if [[ "${JUNIT}" == true ]]; then
        # shellcheck disable=SC2016 # jq program, not shell
        cases=$(jq -c "${DENY_SUBJECT_JQ}"'select(.type? == "diagnostic" and (.fields.severity == "error" or .fields.severity == "warning")) | .fields | .code as $code | {
                classname: "cargo-deny.\(.code)",
                name: (subject | if . == "" then $code else . end),
                status: (if .severity == "error" then "failed" else "skipped" end),
                message: .message,
                detail: ((.notes // []) | join("\n"))
            }' "${JSONL}" | jq -sc --argjson missing "${missing}" --arg require "${REQUIRE_REASONS}" \
            '. + (if $require == "true" then [$missing[] | {classname: "cargo-deny.ignore-reason", name: ., status: "failed",
                message: "ignored in deny.toml without a reason"}] else [] end)')
        suite=${PARAM_REPORT_NAME}
        if [[ "${MULTI}" == true ]]; then
            suite="${PARAM_REPORT_NAME}-${SLUG_LIST[i]}"
        fi
        SUITES=$(jq -c --arg name "${suite}" --argjson cases "${cases}" '. + [{name: $name, cases: $cases}]' <<< "${SUITES}")
    fi

    outcome=passed
    if [[ "${rc}" -ne 0 || ( "${REQUIRE_REASONS}" == true && "${missing}" != "[]" ) ]]; then
        outcome=findings
        if [[ "${REPORT_ONLY}" == true ]]; then
            outcome=findings-reported
        fi
    fi
    if [[ "${rc}" -ne 0 ]]; then
        FAILED_CODE=${rc}
    fi
    sha=""
    if [[ -f "${manifest}" ]]; then
        sha=$(rs_sha256 "${manifest}")
    fi
    INDEX=$(jq -c --arg manifest "${manifest}" --arg slug "${SLUG_LIST[i]}" --arg sha "${sha}" --arg report "${JSONL}" \
        --arg outcome "${outcome}" --argjson counts "${counts}" \
        '. + [{manifest: $manifest, slug: $slug, sha256: $sha, report: $report, outcome: $outcome, counts: $counts}]' <<< "${INDEX}")
done
if [[ "${DB_VARIES}" == true ]]; then
    echo "WARN: The manifests' checks read different advisory databases, or the same one at different commits, so the run" >&2
    echo "WARN: record names none. Fetch the database once with fetch_advisory_db and set offline, so they all read one copy." >&2
    RS_DB=""
fi

if [[ "${MULTI}" == true ]]; then
    jq '{manifests: .}' <<< "${INDEX}" > "${RS_BASE}.json"
    RS_REPORTS+=("${RS_BASE}.json")
    # Each check's counts, summed over the manifests.
    # shellcheck disable=SC2034 # read by rs_run_record
    RS_COUNTS=$(jq -c '(reduce (.[].counts | del(.ignores_without_reason) | to_entries[]) as $check ({};
            reduce ($check.value | to_entries[]) as $n (.; .[$check.key][$n.key] += $n.value)))
        + {manifests: length, ignores_without_reason: (map(.counts.ignores_without_reason) | add)}' <<< "${INDEX}")
else
    # shellcheck disable=SC2034 # read by rs_run_record
    RS_COUNTS=$(jq -c '.[0].counts' <<< "${INDEX}")
fi

if [[ "${JUNIT}" == true ]]; then
    rs_junit_suites "${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "${SUITES}"
    RS_REPORTS+=("${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

FINDINGS=false
if [[ "${MULTI}" == true ]]; then
    # shellcheck disable=SC2016 # jq program, not shell
    MESSAGE="cargo deny $(jq -r --arg all "${#MANIFESTS[@]}" '[.[] | [.counts | to_entries[] | select(.value | type == "object" and .errors > 0) | .key] as $failed
            | select($failed | length > 0) | "\(.manifest) (\($failed | join(", ")))"]
        | if length == 0 then "found no errors in \($all) manifests" else "failed in \(length) of \($all) manifests: " + join("; ") end' <<< "${INDEX}")."
else
    MESSAGE="cargo deny $(jq -r '[to_entries[] | select(.value | type == "object" and .errors > 0) | .key] | if length == 0 then "found no errors" else "failed: " + join(", ") end' <<< "${RS_COUNTS}")."
fi
if [[ "${FAILED_CODE}" -ne 0 ]]; then
    FINDINGS=true
fi
if [[ "${MISSING_TOTAL}" -gt 0 ]]; then
    FINDINGS=true
    MESSAGE="${MESSAGE} ${MISSING_TOTAL} ignored advisories have no reason in deny.toml (require_ignore_reasons)."
fi
OUTCOME=passed
if [[ "${FINDINGS}" == true ]]; then
    OUTCOME=findings
    if [[ "${REPORT_ONLY}" == true ]]; then
        OUTCOME=findings-reported
    fi
fi
if [[ "${RUN_RECORD}" == true ]]; then
    rs_run_record "${RS_BASE}.run-record.json" deny "${OUTCOME}" "${FAILED_CODE}" "${STARTED}"
fi
rs_gate "${FINDINGS}" "${REPORT_ONLY}" "${MESSAGE}"
