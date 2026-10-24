#!/bin/bash
#
# Fails, for the tree_expect command, unless a depth-bounded part of the
# dependency graph cargo tree resolves is exactly the set of packages that
# was reviewed: an exception's premise, such as "only this crate depends on
# the one with the advisory, at this version". A new dependent, a changed
# version, or the subject leaving the graph fails it, so the exception is
# reviewed again. Writes the trees cargo tree printed, a JSON report with the
# missing and unexpected packages, and, when asked, JUnit XML and a run
# record.
#
# cargo tree -i exits 101 both when its package isn't in the graph and when
# the graph doesn't resolve, so whether the subject is there is read from the
# full graph of the same selection, never from cargo's error. A cargo tree
# that fails, or prints a line that doesn't parse, stops the step even with
# report_only.

set -euo pipefail

if [[ -z "${SCRIPT_RUST_SECURITY_LIB:-}" || -z "${SCRIPT_CARGO_TREE_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_RUST_SECURITY_LIB or SCRIPT_CARGO_TREE_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_RUST_SECURITY_LIB}"
eval "${SCRIPT_CARGO_TREE_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INVERT=$(rs_subst "${PARAM_INVERT}")
DEPTH=$(rs_subst "${PARAM_DEPTH}")
IF_ABSENT=${PARAM_IF_ABSENT}
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
if ! rs_match "${DEPTH}" '^[0-9]+$'; then
    echo "ERROR: depth must be a whole number, not '${DEPTH}'." >&2
    exit 1
fi
case "${IF_ABSENT}" in
    fail | pass) ;;
    *)
        echo "ERROR: if_absent must be fail or pass, not '${IF_ABSENT}'." >&2
        exit 1
        ;;
esac
if [[ -n "${INVERT}" ]]; then
    rs_tree_spec invert "${INVERT}"
fi
SUBJECT=${INVERT:-${RS_TREE_PACKAGE}}

# The reviewed set: name@version for a registry package, path:name@version
# and git:name@version, and {root} for the selection's root package.
rs_list_lines expected "${PARAM_EXPECTED}"
EXPECTED=()
USES_ROOT=false
for node in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
    if [[ "${node}" == "{root}" ]]; then
        USES_ROOT=true
    elif ! rs_match "${node}" '^((path|git):)?[A-Za-z0-9_-]+@[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$'; then
        echo "ERROR: expected takes name@version (a registry package), path:name@version, git:name@version and {root}, not '${node}'." >&2
        exit 1
    fi
    EXPECTED+=("${node}")
done
if [[ ${#EXPECTED[@]} -eq 0 ]]; then
    echo "ERROR: expected is empty. List every package the tree must hold, the subject included." >&2
    exit 1
fi
EXPECTED_JSON=$(jq -nc --args '$ARGS.positional | unique' "${EXPECTED[@]}")

# shellcheck disable=SC2034 # read by rs_run_record
RS_TOOL=${RS_CARGO}
RS_TOOL_VERSION=$("${RS_CARGO}" --version 2> /dev/null || true)
# shellcheck disable=SC2034 # read by rs_run_record
RS_INPUTS=()
RS_REPORTS=()
RS_TREE_LOG="${RS_BASE}.cargo.log"
FORMAT_ARGS=(--prefix depth --format "${RS_TREE_FORMAT}" --color never)
# The tree to compare: inverted from invert, or else forward from the
# selection, down to depth. Without --no-dedupe, cargo tree prints a package's
# dependencies only where it first meets it, so one first met at the depth
# limit hides its dependencies from a shorter path to it.
SHAPE_ARGS=(--depth "${DEPTH}" --no-dedupe)
if [[ -n "${INVERT}" ]]; then
    SHAPE_ARGS=(-i "${INVERT}" "${SHAPE_ARGS[@]}")
fi
# The arguments the manifests' calls share, without --manifest-path.
RS_ARGS=(tree ${RS_TREE_PICK[@]+"${RS_TREE_PICK[@]}"} ${RS_TREE_GRAPH[@]+"${RS_TREE_GRAPH[@]}"} "${SHAPE_ARGS[@]}" "${FORMAT_ARGS[@]}")

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
        rs_run_record "${RS_BASE}.run-record.json" tree_expect error "${RS_TREE_CODE:-1}" "${STARTED}"
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
    rm -f "${base}.tree.txt" "${base}.graph.txt"
    if ! rs_tree_metadata "${manifest}"; then
        echo "ERROR: cargo metadata could not read ${manifest:-the workspace in $(pwd)}:" >&2
        sed 's/^/  /' "${RS_TREE_LOG}" | tail -n 20 >&2
        tree_error
    fi
    echo "Checking the graph of ${manifest:-$(pwd)}..."

    # Whether the subject is in the graph at all, from the full forward graph:
    # the selection's for invert, the workspace's for a package the tree
    # starts from (cargo tree -p only takes a package in the graph).
    present=true
    ROOTS="[]"
    if [[ -n "${SUBJECT}" ]]; then
        GRAPH_PICK=(${RS_TREE_PICK[@]+"${RS_TREE_PICK[@]}"})
        GRAPH_SPEC=${RS_TREE_PACKAGE}
        if [[ -z "${INVERT}" ]]; then
            GRAPH_PICK=(--workspace)
            GRAPH_SPEC=""
        fi
        if ! rs_tree_run graph "${base}.graph.txt" tree ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} ${GRAPH_PICK[@]+"${GRAPH_PICK[@]}"} \
            ${RS_TREE_GRAPH[@]+"${RS_TREE_GRAPH[@]}"} "${FORMAT_ARGS[@]}" \
            || ! rs_tree_roots "${base}.graph.txt.json" "${GRAPH_SPEC}"; then
            tree_error
        fi
        # shellcheck disable=SC2016 # jq program, not shell
        if [[ "$(jq --arg spec "${SUBJECT}" "${RS_TREE_JQ}"'any(.[]; spec_match($spec))' "${base}.graph.txt.json")" != true ]]; then
            present=false
        fi
        if [[ -n "${INVERT}" ]]; then
            ROOTS=$(jq -c '[.[] | select(.depth == 0) | .key] | unique' "${base}.graph.txt.json")
        fi
        rm -f "${base}.graph.txt.json"
    fi

    nodes="[]"
    missing="[]"
    unexpected="[]"
    resolved=${EXPECTED_JSON}
    reason=""
    if [[ "${present}" != true ]]; then
        reason="${SUBJECT} is not in the graph"
        verdict=failed
        if [[ "${IF_ABSENT}" == pass ]]; then
            verdict=passed
            reason="${reason}, and if_absent is pass"
        fi
        echo "  ${reason}."
    else
        TREE_SPEC=${RS_TREE_PACKAGE}
        if [[ -n "${INVERT}" ]]; then
            TREE_SPEC=${INVERT}
        fi
        if ! rs_tree_run tree "${base}.tree.txt" tree ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} ${RS_TREE_PICK[@]+"${RS_TREE_PICK[@]}"} \
            ${RS_TREE_GRAPH[@]+"${RS_TREE_GRAPH[@]}"} "${SHAPE_ARGS[@]}" "${FORMAT_ARGS[@]}" \
            || ! rs_tree_roots "${base}.tree.txt.json" "${TREE_SPEC}"; then
            tree_error
        fi
        if [[ -z "${INVERT}" ]]; then
            ROOTS=$(jq -c '[.[] | select(.depth == 0) | .key] | unique' "${base}.tree.txt.json")
        fi
        # {root} is the selection's root package, so one expectation fits
        # every manifest of manifest_paths.
        if [[ "${USES_ROOT}" == true ]]; then
            if [[ "$(jq 'length' <<< "${ROOTS}")" -ne 1 ]]; then
                echo "ERROR: expected names {root}, but the graph of ${manifest:-$(pwd)} starts at $(jq -r 'length' <<< "${ROOTS}") packages," >&2
                echo "  $(jq -r 'join(", ")' <<< "${ROOTS}"). {root} needs a selection with one root package (not workspace: true)." >&2
                tree_error
            fi
            # shellcheck disable=SC2016 # jq program, not shell
            resolved=$(jq -c --argjson roots "${ROOTS}" 'map(if . == "{root}" then $roots[0] else . end) | unique' <<< "${EXPECTED_JSON}")
        fi
        nodes=$(jq -c "${RS_TREE_JQ}"'nodes' "${base}.tree.txt.json")
        rm -f "${base}.tree.txt.json"
        # shellcheck disable=SC2016 # jq program, not shell
        missing=$(jq -c --argjson expected "${resolved}" '[.[].key] as $actual | [$expected[] | select(. as $e | $actual | index($e) | not)]' <<< "${nodes}")
        # shellcheck disable=SC2016 # jq program, not shell
        unexpected=$(jq -c --argjson expected "${resolved}" '[.[].key | select(. as $a | $expected | index($a) | not)]' <<< "${nodes}")
        verdict=passed
        if [[ "${missing}" != "[]" || "${unexpected}" != "[]" ]]; then
            verdict=failed
        fi
        echo "  cargo tree printed $(jq 'length' <<< "${nodes}") packages within depth ${DEPTH} of ${SUBJECT:-the root}: $(jq -r 'map(.key) | join(", ")' <<< "${nodes}")"
        if [[ "${missing}" != "[]" ]]; then
            echo "  missing: $(jq -r 'join(", ")' <<< "${missing}")"
        fi
        if [[ "${unexpected}" != "[]" ]]; then
            echo "  unexpected: $(jq -r 'join(", ")' <<< "${unexpected}")"
        fi
    fi

    sha=""
    if [[ -f "${RS_TREE_LOCKFILE}" ]]; then
        sha=$(rs_sha256 "${RS_TREE_LOCKFILE}")
    fi
    # shellcheck disable=SC2016 # jq program, not shell
    jq -n --arg manifest "${manifest}" --argjson exceptions "${RS_EXCEPTIONS}" --arg cargo "${RS_TOOL_VERSION}" \
        --arg lockfile "${RS_TREE_LOCKFILE}" --arg sha "${sha}" --argjson runs "${RS_TREE_RUNS}" --arg subject "${SUBJECT}" \
        --arg invert "${INVERT}" --argjson depth "${DEPTH}" --arg if_absent "${IF_ABSENT}" --argjson present "${present}" \
        --argjson expected "${resolved}" --arg verdict "${verdict}" --arg reason "${reason}" --argjson nodes "${nodes}" \
        --argjson missing "${missing}" --argjson unexpected "${unexpected}" '{
            command: "tree_expect", manifest: (if $manifest == "" then null else $manifest end), exceptions: $exceptions,
            cargo: $cargo, lockfile: {path: $lockfile, sha256: (if $sha == "" then null else $sha end)}, runs: $runs,
            subject: (if $subject == "" then null else $subject end), inverted: ($invert != ""), depth: $depth,
            if_absent: $if_absent, present: $present, expected: $expected,
            verdict: $verdict, reason: (if $reason == "" then null else $reason end),
            nodes: $nodes, missing: $missing, unexpected: $unexpected
        }' > "${base}.json"
    RS_REPORTS+=("${base}.json")
    INDEX=$(jq -c --arg manifest "${manifest}" --arg slug "${slug}" --arg report "${base}.json" --arg verdict "${verdict}" \
        --argjson present "${present}" --argjson nodes "$(jq 'length' <<< "${nodes}")" \
        --argjson missing "$(jq 'length' <<< "${missing}")" --argjson unexpected "$(jq 'length' <<< "${unexpected}")" \
        '. + [{manifest: $manifest, slug: $slug, report: $report, verdict: $verdict, present: $present, nodes: $nodes,
            missing: $missing, unexpected: $unexpected}]' <<< "${INDEX}")
    if [[ "${JUNIT}" == true ]]; then
        name="${SUBJECT:-${manifest:-root}} depth ${DEPTH}"
        if [[ -n "${INVERT}" ]]; then
            name="${INVERT} inverted, depth ${DEPTH}"
        fi
        # shellcheck disable=SC2016 # jq program, not shell
        cases=$(jq -nc --arg name "${name}" --arg verdict "${verdict}" --arg reason "${reason}" --argjson missing "${missing}" \
            --argjson unexpected "${unexpected}" '[{classname: "tree-expect", name: $name,
                status: (if $verdict == "failed" then "failed" else "passed" end),
                message: (if $reason != "" then $reason
                    else [(if ($missing | length) > 0 then "missing: " + ($missing | join(", ")) else empty end),
                        (if ($unexpected | length) > 0 then "unexpected: " + ($unexpected | join(", ")) else empty end)] | join("; ") end)}]')
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
RS_COUNTS=$(jq -c '{selections: length, nodes: (map(.nodes) | add), missing: (map(.missing) | add),
    unexpected: (map(.unexpected) | add), absent: ([.[] | select(.present | not)] | length)}' <<< "${INDEX}")
if [[ "${JUNIT}" == true ]]; then
    rs_junit_suites "${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml" "${SUITES}"
    RS_REPORTS+=("${RS_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

FINDINGS=false
OUTCOME=passed
if [[ "$(jq '[.[] | select(.verdict == "failed")] | length' <<< "${INDEX}")" -gt 0 ]]; then
    FINDINGS=true
    OUTCOME=findings
    if [[ "${REPORT_ONLY}" == true ]]; then
        OUTCOME=findings-reported
    fi
fi
if [[ "${RUN_RECORD}" == true ]]; then
    rs_run_record "${RS_BASE}.run-record.json" tree_expect "${OUTCOME}" "${RS_TREE_CODE:-0}" "${STARTED}"
fi
MESSAGE="cargo tree's graph around ${SUBJECT:-the root} is the expected one."
if [[ "$(jq '.absent' <<< "${RS_COUNTS}")" -gt 0 && "${FINDINGS}" != true ]]; then
    MESSAGE="${SUBJECT} is not in $(jq -r '.absent as $a | .selections as $s | if $a == $s then "the graph" else "\($a) of the \($s) graphs" end' <<< "${RS_COUNTS}"),"
    MESSAGE="${MESSAGE} which if_absent: pass accepts."
fi
if [[ "${FINDINGS}" == true ]]; then
    # shellcheck disable=SC2016 # jq program, not shell
    MESSAGE="cargo tree's graph around ${SUBJECT:-the root} is not the expected one: $(jq -r --arg subject "${SUBJECT}" '[
        (map(.missing) | add | if . > 0 then "\(.) missing" else empty end),
        (map(.unexpected) | add | if . > 0 then "\(.) unexpected" else empty end),
        ([.[] | select(.present | not)] | length | if . > 0 then "\($subject) is not in the graph" else empty end)] | join(", ")' <<< "${INDEX}")."
    if [[ "${RS_TREE_MULTI}" == true ]]; then
        MESSAGE="${MESSAGE} In: $(jq -r '[.[] | select(.verdict == "failed") | .manifest] | join(", ")' <<< "${INDEX}")."
    fi
    MESSAGE="${MESSAGE} Review the change, then update expected (and the exception it guards)."
fi
rs_gate "${FINDINGS}" "${REPORT_ONLY}" "${MESSAGE}"
