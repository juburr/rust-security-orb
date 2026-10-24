#!/bin/bash
#
# Fails, for the tree_forbid command, when the dependency graph cargo tree
# resolves for a selection (a package or the workspace, a feature set, a
# target, edge kinds) holds a forbidden package, or a package with a forbidden
# feature enabled: "this crate never ships in that binary". Writes the graph
# cargo tree printed, a JSON report naming each violation and how the root
# reaches it, and, when asked, JUnit XML and a run record.
#
# A cargo tree that fails, or prints a line that doesn't parse, stops the step
# even with report_only: an empty or unread graph would pass every check.

set -euo pipefail

if [[ -z "${SCRIPT_RUST_SECURITY_LIB:-}" || -z "${SCRIPT_CARGO_TREE_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_RUST_SECURITY_LIB or SCRIPT_CARGO_TREE_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_RUST_SECURITY_LIB}"
eval "${SCRIPT_CARGO_TREE_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REACHABLE=$(rs_subst "${PARAM_ONLY_IF_REACHABLE}")
REACHABLE_FROM=$(rs_subst "${PARAM_ONLY_IF_REACHABLE_FROM}")
JUNIT=$(rs_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(rs_bool report_only "${PARAM_REPORT_ONLY}")
RUN_RECORD=$(rs_bool run_record "${PARAM_RUN_RECORD}")
rs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rs_require_jq
if ! RS_CARGO=$(command -v cargo); then
    echo "ERROR: cargo is not on the PATH, and cargo tree resolves the graph this command checks. Use a Rust image such as cimg/rust." >&2
    exit 1
fi
rs_tree_params

# The forbidden packages and features: patterns where * matches any run of
# characters and ? any one, against the whole name.
rs_list_lines forbidden_packages "${PARAM_FORBIDDEN_PACKAGES}"
PACKAGES=(${RS_LIST[@]+"${RS_LIST[@]}"})
for pattern in ${PACKAGES[@]+"${PACKAGES[@]}"}; do
    if ! rs_match "${pattern}" '^[A-Za-z0-9_*?-]+$'; then
        echo "ERROR: forbidden_packages takes crate names, with * and ? as wildcards, not '${pattern}'." >&2
        exit 1
    fi
done
rs_list_lines forbidden_features "${PARAM_FORBIDDEN_FEATURES}"
FEATURES=(${RS_LIST[@]+"${RS_LIST[@]}"})
for pattern in ${FEATURES[@]+"${FEATURES[@]}"}; do
    if ! rs_match "${pattern}" '^[A-Za-z0-9_*?-]+:[^:]+$'; then
        echo "ERROR: forbidden_features takes crate:feature, such as index:writer, with * and ? as wildcards, not '${pattern}'." >&2
        exit 1
    fi
done
if [[ ${#PACKAGES[@]} -eq 0 && ${#FEATURES[@]} -eq 0 ]]; then
    echo "ERROR: forbidden_packages and forbidden_features are both empty, so there is nothing to check." >&2
    exit 1
fi
RULES=$(jq -nc --args '$ARGS.positional' ${PACKAGES[@]+"${PACKAGES[@]}"})
FEATURE_RULES=$(jq -nc --args '$ARGS.positional' ${FEATURES[@]+"${FEATURES[@]}"})
# The check runs only when only_if_reachable is in the graph of
# only_if_reachable_from (or of the selection itself), as when a feature only
# a workspace-wide build unifies matters only if the binary links the crate.
REACH_PICK=()
if [[ -n "${REACHABLE}" ]]; then
    rs_tree_spec only_if_reachable "${REACHABLE}"
    REACH_PICK=(${RS_TREE_PICK[@]+"${RS_TREE_PICK[@]}"})
    if [[ -n "${REACHABLE_FROM}" ]]; then
        rs_tree_spec only_if_reachable_from "${REACHABLE_FROM}"
        REACH_PICK=(-p "${REACHABLE_FROM}")
    fi
elif [[ -n "${REACHABLE_FROM}" ]]; then
    echo "ERROR: only_if_reachable_from is set without only_if_reachable, the package that must be reachable from it." >&2
    exit 1
fi

# shellcheck disable=SC2034 # read by rs_run_record
RS_TOOL=${RS_CARGO}
RS_TOOL_VERSION=$("${RS_CARGO}" --version 2> /dev/null || true)
# shellcheck disable=SC2034 # read by rs_run_record
RS_INPUTS=()
RS_REPORTS=()
RS_TREE_LOG="${RS_BASE}.cargo.log"
TREE_ARGS=(tree ${RS_TREE_PICK[@]+"${RS_TREE_PICK[@]}"} ${RS_TREE_GRAPH[@]+"${RS_TREE_GRAPH[@]}"}
    --prefix depth --format "${RS_TREE_FORMAT}" --color never)
# The arguments the manifests' calls share, without --manifest-path.
RS_ARGS=("${TREE_ARGS[@]}")

# tree_error: stops the step for a graph that couldn't be read, with an error
# run record that lists what cargo said.
tree_error() {
    if [[ -s "${RS_TREE_LOG}" ]]; then
        RS_REPORTS+=("${RS_TREE_LOG}")
    fi
    # With one manifest, the call that failed.
    if [[ "${RS_TREE_MULTI}" != true && -n "${RS_TREE_LAST_ARGS[*]+set}" ]]; then
        RS_ARGS=("${RS_TREE_LAST_ARGS[@]}")
    fi
    if [[ "${RUN_RECORD}" == true ]]; then
        rs_run_record "${RS_BASE}.run-record.json" tree_forbid error "${RS_TREE_CODE:-1}" "${STARTED}"
    fi
    exit 1
}

rs_tree_slugs
INDEX="[]"
SUITES="[]"
for ((i = 0; i < ${#RS_TREE_MANIFESTS[@]}; i++)); do
    manifest=${RS_TREE_MANIFESTS[i]}
    slug=${RS_TREE_SLUGS[i]}
    base=${RS_TREE_BASES[i]}
    MANIFEST_ARGS=()
    if [[ -n "${manifest}" ]]; then
        MANIFEST_ARGS=(--manifest-path "${manifest}")
    fi
    RS_TREE_RUNS="[]"
    # A report an earlier run left would be stored with this run's.
    rm -f "${base}.tree.txt" "${base}.reachability.txt"
    if ! rs_tree_metadata "${manifest}"; then
        echo "ERROR: cargo metadata could not read ${manifest:-the workspace in $(pwd)}:" >&2
        sed 's/^/  /' "${RS_TREE_LOG}" | tail -n 20 >&2
        tree_error
    fi
    echo "Checking the graph of ${manifest:-$(pwd)}..."
    verdict=""
    reason=""
    if [[ -n "${REACHABLE}" ]]; then
        if ! rs_tree_run reachability "${base}.reachability.txt" tree ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} \
            ${REACH_PICK[@]+"${REACH_PICK[@]}"} ${RS_TREE_GRAPH[@]+"${RS_TREE_GRAPH[@]}"} \
            --prefix depth --format "${RS_TREE_FORMAT}" --color never \
            || ! rs_tree_roots "${base}.reachability.txt.json" "${REACHABLE_FROM:-${RS_TREE_PACKAGE}}"; then
            tree_error
        fi
        # shellcheck disable=SC2016 # jq program, not shell
        if [[ "$(jq --arg spec "${REACHABLE}" "${RS_TREE_JQ}"'any(.[]; spec_match($spec))' "${base}.reachability.txt.json")" != true ]]; then
            verdict=skipped
            reason="${REACHABLE} is not in the graph of ${REACHABLE_FROM:-${RS_TREE_PACKAGE:-the selection}}, so the check does not apply"
            echo "  Skipped: ${reason}."
        fi
    fi
    violations="[]"
    nodes="[]"
    if [[ -z "${verdict}" ]]; then
        if ! rs_tree_run graph "${base}.tree.txt" "${TREE_ARGS[0]}" ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} "${TREE_ARGS[@]:1}" \
            || ! rs_tree_roots "${base}.tree.txt.json" "${RS_TREE_PACKAGE}"; then
            tree_error
        fi
        # Each forbidden package once, and each forbidden feature once per
        # package, with the first path cargo tree printed to it.
        # shellcheck disable=SC2016 # jq program, not shell
        violations=$(jq -c --argjson packages "${RULES}" --argjson features "${FEATURE_RULES}" "${RS_TREE_JQ}"'
            . as $lines
            | ([$packages[] as $rule | $lines[] | select(.name | glob_match($rule))
                    | {rule: $rule, package: .key, feature: null, path}] | unique_by([.rule, .package]))
            + ([$features[] | (split(":")[0]) as $krate | (split(":")[1:] | join(":")) as $feature | . as $rule
                    | $lines[] | select(.name | glob_match($krate)) | . as $line | .features[] | select(glob_match($feature))
                    | {rule: $rule, package: $line.key, feature: ., path: $line.path}] | unique_by([.rule, .package, .feature]))' \
            "${base}.tree.txt.json")
        nodes=$(jq -c "${RS_TREE_JQ}"'nodes' "${base}.tree.txt.json")
        verdict=passed
        if [[ "${violations}" != "[]" ]]; then
            verdict=failed
        fi
        echo "  cargo tree resolved $(jq 'length' <<< "${nodes}") packages."
        # shellcheck disable=SC2016 # jq program, not shell
        jq -r '.[] | "  forbidden: \(.package)\(if .feature then " with feature \(.feature)" else "" end) (\(.rule)), reached by \(.path | join(" -> "))"' <<< "${violations}"
    fi
    rm -f "${base}.tree.txt.json" "${base}.reachability.txt.json"

    sha=""
    if [[ -f "${RS_TREE_LOCKFILE}" ]]; then
        sha=$(rs_sha256 "${RS_TREE_LOCKFILE}")
    fi
    # shellcheck disable=SC2016 # jq program, not shell
    jq -n --arg manifest "${manifest}" --argjson exceptions "${RS_EXCEPTIONS}" --arg cargo "${RS_TOOL_VERSION}" \
        --arg lockfile "${RS_TREE_LOCKFILE}" --arg sha "${sha}" --argjson runs "${RS_TREE_RUNS}" --arg verdict "${verdict}" \
        --arg reason "${reason}" --argjson packages "${RULES}" --argjson features "${FEATURE_RULES}" \
        --arg reachable "${REACHABLE}" --arg from "${REACHABLE_FROM}" --argjson nodes "${nodes}" --argjson violations "${violations}" '{
            command: "tree_forbid", manifest: (if $manifest == "" then null else $manifest end), exceptions: $exceptions,
            cargo: $cargo, lockfile: {path: $lockfile, sha256: (if $sha == "" then null else $sha end)}, runs: $runs,
            forbidden_packages: $packages, forbidden_features: $features,
            only_if_reachable: (if $reachable == "" then null else {package: $reachable, from: (if $from == "" then null else $from end)} end),
            verdict: $verdict, reason: (if $reason == "" then null else $reason end), nodes: $nodes, violations: $violations
        }' > "${base}.json"
    RS_REPORTS+=("${base}.json")
    INDEX=$(jq -c --arg manifest "${manifest}" --arg slug "${slug}" --arg report "${base}.json" --arg verdict "${verdict}" \
        --argjson nodes "$(jq 'length' <<< "${nodes}")" --argjson violations "$(jq 'length' <<< "${violations}")" \
        '. + [{manifest: $manifest, slug: $slug, report: $report, verdict: $verdict, nodes: $nodes, violations: $violations}]' <<< "${INDEX}")
    if [[ "${JUNIT}" == true ]]; then
        # One test case per forbidden package or feature pattern.
        # shellcheck disable=SC2016 # jq program, not shell
        cases=$(jq -c --argjson packages "${RULES}" --argjson features "${FEATURE_RULES}" --arg verdict "${verdict}" --arg reason "${reason}" '
            . as $violations
            | [($packages[] | {classname: "tree-forbid.package", name: .}), ($features[] | {classname: "tree-forbid.feature", name: .})]
            | map(.name as $rule | [$violations[] | select(.rule == $rule)] as $found
                | if $verdict == "skipped" then . + {status: "skipped", message: $reason}
                  elif ($found | length) > 0 then . + {status: "failed",
                    message: "forbidden: \([$found[] | .package + (if .feature then " with feature " + .feature else "" end)] | join(", "))",
                    detail: ([$found[] | .path | join(" -> ")] | join("\n"))}
                  else . + {status: "passed"} end)' <<< "${violations}")
        suite=${PARAM_REPORT_NAME}
        if [[ "${RS_TREE_MULTI}" == true ]]; then
            suite="${PARAM_REPORT_NAME}-${slug}"
        fi
        SUITES=$(jq -c --arg name "${suite}" --argjson cases "${cases}" '. + [{name: $name, cases: $cases}]' <<< "${SUITES}")
    fi
done
rm -f "${RS_TREE_LOG}"
# With one manifest, the run record names the cargo tree call whose output
# decided; with several, the arguments their calls share.
if [[ "${RS_TREE_MULTI}" != true ]]; then
    # shellcheck disable=SC2034 # read by rs_run_record
    RS_ARGS=("${RS_TREE_LAST_ARGS[@]}")
fi

if [[ "${RS_TREE_MULTI}" == true ]]; then
    jq '{selections: .}' <<< "${INDEX}" > "${RS_BASE}.json"
    RS_REPORTS+=("${RS_BASE}.json")
fi
# shellcheck disable=SC2034 # read by rs_run_record
RS_COUNTS=$(jq -c '{selections: length, nodes: (map(.nodes) | add), violations: (map(.violations) | add),
    skipped: ([.[] | select(.verdict == "skipped")] | length)}' <<< "${INDEX}")
if [[ "${JUNIT}" == true ]]; then
    rs_junit_suites "${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "${SUITES}"
    RS_REPORTS+=("${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

FINDINGS=false
OUTCOME=passed
if [[ "$(jq '.violations' <<< "${RS_COUNTS}")" -gt 0 ]]; then
    FINDINGS=true
    OUTCOME=findings
    if [[ "${REPORT_ONLY}" == true ]]; then
        OUTCOME=findings-reported
    fi
elif [[ "$(jq '.skipped == .selections' <<< "${RS_COUNTS}")" == true ]]; then
    OUTCOME=skipped
fi
if [[ "${RUN_RECORD}" == true ]]; then
    rs_run_record "${RS_BASE}.run-record.json" tree_forbid "${OUTCOME}" "${RS_TREE_CODE:-0}" "${STARTED}"
fi
if [[ "${OUTCOME}" == skipped ]]; then
    echo "Skipped: ${REACHABLE} is not in the graph of ${REACHABLE_FROM:-${RS_TREE_PACKAGE:-the selection}}, so nothing was checked."
    exit 0
fi
MESSAGE="cargo tree's graph holds no forbidden package or feature."
if [[ "${FINDINGS}" == true ]]; then
    MESSAGE="cargo tree's graph holds $(jq '.violations' <<< "${RS_COUNTS}") forbidden packages or features."
    if [[ "${RS_TREE_MULTI}" == true ]]; then
        MESSAGE="${MESSAGE} In: $(jq -r '[.[] | select(.verdict == "failed") | .manifest] | join(", ")' <<< "${INDEX}")."
    fi
fi
rs_gate "${FINDINGS}" "${REPORT_ONLY}" "${MESSAGE}"
