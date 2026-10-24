#!/bin/bash

# Helpers for the tree_forbid and tree_expect commands, which assert what the
# dependency graph cargo tree resolves holds. Each command passes this file to
# its step as SCRIPT_CARGO_TREE_LIB, besides SCRIPT_RUST_SECURITY_LIB, and its
# script evals both after set -euo pipefail, so it only defines functions.
#
# They read cargo tree, not cargo metadata: cargo metadata has no -p, and its
# resolve unifies features across every workspace member, so it can't show
# what cargo build -p server links. Each line cargo tree prints must parse,
# and cargo tree's own exit code is checked before its output is read: a
# graph that didn't resolve, such as with a stale lockfile under --locked, is
# an error, never an empty graph that passes.

# The line format: the package, a tab, and its features. cargo tree adds
# " (*)" to a package whose dependencies it printed before. A package's
# display can hold spaces (a path source), but a feature list holds no tab or
# space, so the last tab ends the package.
# shellcheck disable=SC2034 # read by the scripts
RS_TREE_FORMAT=$'{p}\t{f}'

# jq functions over cargo tree's output, given $cwd, the working directory:
# - tree_lines: the lines cargo tree --prefix depth printed, as strings, to
#   {depth, name, version, kind, source, proc_macro, features, repeat, key,
#   label, path}. kind is registry (crates.io or another registry), path or
#   git; a path source is relative to $cwd when it is inside it. key is how
#   expected nodes are written: name@version, path:name@version or
#   git:name@version. path is the labels ("name vVERSION") from the root of
#   the line's tree down to it. A blank line separates two trees (one per
#   workspace member). A line that doesn't parse is an error.
# - spec_match($spec): whether a line is the package a cargo package spec,
#   name or name@version (a version can leave out its last parts), names.
# - glob_match($glob): whether a string matches a pattern where * matches any
#   run of characters and ? any one, against the whole string.
# shellcheck disable=SC2016 # jq program, not shell
RS_TREE_JQ='
    def tree_line($cwd): . as $text
        | (capture("^(?<depth>[0-9]+)(?<p>.*)\t(?<f>[^\t ]*)(?<repeat> \\(\\*\\))?$")
            // error("cargo tree printed a line this command cannot read: \($text)"))
        | . as $m
        | ($m.p | capture("^(?<name>[^\\s()]+) v(?<version>[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\\+[0-9A-Za-z.-]+)?)(?<macro> \\(proc-macro\\))?(?: \\((?<source>.+)\\))?$")
            // error("cargo tree printed a package this command cannot read: \($text)"))
        | . as $p
        | (if $p.source == null then "registry"
            elif ($p.source | startswith("/")) then "path"
            elif ($p.source | test("^[A-Za-z][A-Za-z0-9+.-]*://[^#\\s]+#[0-9a-f]+$")) then "git"
            elif ($p.source | test("^(sparse|registry)\\+\\S+$|^registry `.+`$|^[A-Za-z0-9_-]+$|^[A-Za-z][A-Za-z0-9+.-]*://\\S+$")) then "registry"
            else error("cargo tree printed a source this command cannot read: \($text)") end) as $kind
        | {depth: ($m.depth | tonumber), name: $p.name, version: $p.version, kind: $kind,
            source: (if $kind == "path" then ($p.source | if . == $cwd then "." elif startswith($cwd + "/") then ltrimstr($cwd + "/") else . end)
                else $p.source end),
            proc_macro: ($p.macro != null), features: ($m.f | split(",") | map(select(. != ""))), repeat: ($m.repeat != null)}
        | .key = (if .kind == "registry" then "" else .kind + ":" end) + .name + "@" + .version
        | .label = "\(.name) v\(.version)";
    def tree_lines($cwd):
        reduce .[] as $text ({stack: [], lines: []};
            if $text == "" then .stack = []
            else ($text | tree_line($cwd)) as $line
                | if $line.depth > (.stack | length) then error("cargo tree printed a line below no parent: \($text)") else . end
                | .stack = (.stack[:$line.depth] + [$line.label])
                | .lines += [$line + {path: .stack}]
            end)
        | .lines;
    def spec_match($spec): ($spec | split("@")) as $s
        | .name == $s[0] and (($s | length) == 1 or .version == $s[1] or (.version | startswith($s[1] + ".")));
    def glob_re: "^" + (explode | map(if . == 42 then ".*" elif . == 63 then "."
            elif (. >= 33 and . <= 47) or (. >= 58 and . <= 64) or (. >= 91 and . <= 96) or (. >= 123 and . <= 126) then "\\" + ([.] | implode)
            else [.] | implode end) | join("")) + "$";
    def glob_match($glob): test($glob | glob_re);
    def nodes: group_by(.key) | map(.[0] + {features: (map(.features) | unique)} | del(.depth, .repeat, .path));
'

# rs_tree_spec PARAMETER VALUE: stops the step unless VALUE is a package spec
# these commands take: name, or name@version.
rs_tree_spec() {
    if ! rs_match "$2" '^[A-Za-z0-9_-]+(@[0-9]+(\.[0-9]+){0,2}([-+][0-9A-Za-z.+-]+)?)?$'; then
        echo "ERROR: $1 must be a package name, or name@version such as paste@1.0.15, not '$2'." >&2
        exit 1
    fi
}

# rs_tree_params: reads the parameters both commands share, and sets
#   RS_TREE_PICK       the packages the graph starts from: -p PACKAGE or
#                      --workspace, or nothing for the manifest's own
#   RS_TREE_GRAPH      the options that shape it: features, target, edges,
#                      and how cargo may treat the lockfile and the network
#   RS_TREE_PACKAGE    package, a spec, or empty
#   RS_TREE_WORKSPACE  true or false
#   RS_TREE_MANIFESTS  the manifests to check: manifest_path, each file
#                      manifest_paths names, or "" for working_dir's own
#   RS_TREE_MULTI      true with manifest_paths
#   RS_EXCEPTIONS      the exception parameter's IDs, as a JSON array
rs_tree_params() {
    local manifest edges=() edge target features all_features no_default_features locked offline frozen
    manifest=$(rs_subst "${PARAM_MANIFEST_PATH}")
    RS_TREE_PACKAGE=$(rs_subst "${PARAM_PACKAGE}")
    RS_TREE_WORKSPACE=$(rs_bool workspace "${PARAM_WORKSPACE}")
    target=$(rs_subst "${PARAM_TARGET}")
    all_features=$(rs_bool all_features "${PARAM_ALL_FEATURES}")
    no_default_features=$(rs_bool no_default_features "${PARAM_NO_DEFAULT_FEATURES}")
    locked=$(rs_bool locked "${PARAM_LOCKED}")
    offline=$(rs_bool offline "${PARAM_OFFLINE}")
    frozen=$(rs_bool frozen "${PARAM_FROZEN}")
    # shellcheck disable=SC2034 # read by the scripts
    RS_TREE_PICK=()
    if [[ -n "${RS_TREE_PACKAGE}" ]]; then
        rs_tree_spec package "${RS_TREE_PACKAGE}"
        if [[ "${RS_TREE_WORKSPACE}" == true ]]; then
            echo "ERROR: package and workspace are both set. Name one package, or check the whole workspace." >&2
            exit 1
        fi
        RS_TREE_PICK=(-p "${RS_TREE_PACKAGE}")
    elif [[ "${RS_TREE_WORKSPACE}" == true ]]; then
        RS_TREE_PICK=(--workspace)
    fi
    RS_TREE_GRAPH=()
    rs_list features "${PARAM_FEATURES}"
    if [[ ${#RS_LIST[@]} -gt 0 ]]; then
        features=$(IFS=,; printf '%s' "${RS_LIST[*]}")
        RS_TREE_GRAPH+=(--features "${features}")
    fi
    if [[ "${all_features}" == true ]]; then
        RS_TREE_GRAPH+=(--all-features)
    fi
    if [[ "${no_default_features}" == true ]]; then
        RS_TREE_GRAPH+=(--no-default-features)
    fi
    if [[ -n "${target}" ]]; then
        RS_TREE_GRAPH+=(--target "${target}")
    fi
    rs_list edges "${PARAM_EDGES}"
    for edge in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
        case "${edge}" in
            all | normal | build | dev | no-normal | no-build | no-dev | no-proc-macro) edges+=("${edge}") ;;
            *)
                echo "ERROR: edges takes all, normal, build, dev, no-normal, no-build, no-dev and no-proc-macro, not '${edge}'." >&2
                echo "  (features edges change what cargo tree prints, so they are not taken.)" >&2
                exit 1
                ;;
        esac
    done
    if [[ ${#edges[@]} -gt 0 ]]; then
        RS_TREE_GRAPH+=(--edges "$(IFS=,; printf '%s' "${edges[*]}")")
    fi
    if [[ "${frozen}" == true ]]; then
        RS_TREE_GRAPH+=(--frozen)
    else
        if [[ "${offline}" == true ]]; then
            RS_TREE_GRAPH+=(--offline)
        fi
        if [[ "${locked}" == true ]]; then
            RS_TREE_GRAPH+=(--locked)
        fi
    fi
    rs_list_lines manifest_paths "${PARAM_MANIFEST_PATHS}"
    RS_TREE_MULTI=false
    if [[ ${#RS_LIST[@]} -gt 0 ]]; then
        if [[ -n "${manifest}" ]]; then
            echo "ERROR: manifest_path and manifest_paths are both set. Name one Cargo.toml in manifest_path, or several in manifest_paths." >&2
            exit 1
        fi
        RS_TREE_MULTI=true
        rs_files manifest_paths
        RS_TREE_MANIFESTS=("${RS_FILES[@]}")
    else
        RS_TREE_MANIFESTS=("${manifest}")
    fi
    rs_list_lines exception "${PARAM_EXCEPTION}"
    # shellcheck disable=SC2034 # read by rs_run_record
    RS_EXCEPTIONS=$(printf '%s\n' ${RS_LIST[@]+"${RS_LIST[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))')
}

# rs_tree_slugs: sets RS_TREE_SLUGS and RS_TREE_BASES to each manifest's
# slug and report path: <report_name>-<slug> with manifest_paths, and
# <report_name> without. Two manifests whose reports would share a name stop
# the step.
rs_tree_slugs() {
    local manifest
    local -A seen=()
    RS_TREE_SLUGS=()
    RS_TREE_BASES=()
    for manifest in "${RS_TREE_MANIFESTS[@]}"; do
        if [[ "${RS_TREE_MULTI}" != true ]]; then
            RS_TREE_SLUGS+=("")
            RS_TREE_BASES+=("${RS_BASE}")
            continue
        fi
        rs_slug "${manifest}" Cargo.toml
        if [[ -n "${seen[${RS_SLUG}]:-}" ]]; then
            echo "ERROR: manifest_paths names ${seen[${RS_SLUG}]} and ${manifest}, whose reports would both be named ${PARAM_REPORT_NAME}-${RS_SLUG}." >&2
            exit 1
        fi
        seen[${RS_SLUG}]=${manifest}
        RS_TREE_SLUGS+=("${RS_SLUG}")
        RS_TREE_BASES+=("${RS_BASE}-${RS_SLUG}")
    done
}

# rs_tree_metadata MANIFEST: sets RS_TREE_META to cargo metadata --no-deps
# for MANIFEST (or working_dir's), which resolves nothing, so it neither
# writes Cargo.lock nor uses the network, and adds the workspace's lockfile and
# manifests to RS_INPUTS. Sets RS_TREE_LOCKFILE, and RS_TREE_MEMBERS to the
# workspace's packages as a JSON array of name@version. Returns 1, with
# cargo's error in RS_TREE_LOG's file, when cargo metadata fails.
rs_tree_metadata() {
    local root
    if ! RS_TREE_META=$("${RS_CARGO}" metadata --no-deps --format-version 1 ${1:+--manifest-path "$1"} 2> "${RS_TREE_LOG}"); then
        return 1
    fi
    root=$(jq -r '.workspace_root' <<< "${RS_TREE_META}")
    RS_TREE_LOCKFILE="${root}/Cargo.lock"
    # Even before it exists: without locked, cargo tree can write it, and the
    # run record hashes inputs when it is written.
    RS_INPUTS+=("lockfile:${RS_TREE_LOCKFILE}")
    rs_manifest_inputs "${RS_TREE_META}"
    # shellcheck disable=SC2034 # read by the scripts
    RS_TREE_MEMBERS=$(jq -c '[.workspace_members as $m | .packages[] | select(.id as $id | $m | index($id)) | "\(.name)@\(.version)"]' <<< "${RS_TREE_META}")
}

# rs_tree_run ROLE OUTPUT ARG...: runs cargo ARG... (a cargo tree call),
# keeps what it printed in OUTPUT, and parses it into OUTPUT.json with
# tree_lines. Adds the call to RS_TREE_RUNS, OUTPUT to RS_REPORTS, and sets
# RS_TREE_LAST_ARGS to ARG.... Returns 1, saying why, when cargo tree fails
# or prints a line that doesn't parse: either is an error, never a graph.
rs_tree_run() {
    local role=$1 output=$2 rc=0 error
    shift 2
    rs_show_command cargo "$@"
    # shellcheck disable=SC2034 # read by the scripts
    RS_TREE_LAST_ARGS=("$@")
    "${RS_CARGO}" "$@" > "${output}" 2> "${RS_TREE_LOG}" || rc=$?
    RS_REPORTS+=("${output}")
    RS_TREE_RUNS=$(jq -c --arg role "${role}" --arg output "${output}" --arg sha "$(rs_sha256 "${output}")" \
        --argjson args "$(rs_public_args "$@")" --argjson code "${rc}" \
        '. + [{role: $role, arguments: $args, exit_code: $code, output: $output, sha256: $sha}]' <<< "${RS_TREE_RUNS}")
    # shellcheck disable=SC2034 # read by the scripts
    RS_TREE_CODE=${rc}
    if [[ "${rc}" -ne 0 ]]; then
        echo "ERROR: cargo tree failed (exit code ${rc}), so there is no graph to check. It says:" >&2
        sed 's/^/  /' "${RS_TREE_LOG}" | tail -n 20 >&2
        return 1
    fi
    if ! jq -R -n --arg cwd "$(pwd)" "${RS_TREE_JQ}"'[inputs] | tree_lines($cwd)' "${output}" > "${output}.json" 2> "${RS_TREE_LOG}"; then
        error=$(sed -n 's/^jq: error ([^)]*): //p' "${RS_TREE_LOG}" | head -n 1)
        echo "ERROR: ${error:-cargo tree printed output this command cannot read}" >&2
        return 1
    fi
    if [[ "$(jq 'length' "${output}.json")" -eq 0 ]]; then
        echo "ERROR: cargo tree printed no packages, so there is no graph to check." >&2
        return 1
    fi
}

# rs_tree_roots LINES SPEC: returns 1, saying why, unless the trees in the
# parsed LINES start where the selection says: at packages SPEC names when it
# is set, at every workspace member with workspace, and otherwise at
# workspace members (the manifest's package, or a virtual manifest's default
# members). A wrong manifest_path or package then fails, rather than check
# some other graph.
rs_tree_roots() {
    local roots
    # shellcheck disable=SC2016 # jq program, not shell
    if [[ -n "$2" ]]; then
        roots=$(jq -r --arg spec "$2" "${RS_TREE_JQ}"'[.[] | select(.depth == 0) | select(spec_match($spec) | not) | .label] | join(", ")' "$1")
        if [[ -n "${roots}" ]]; then
            echo "ERROR: cargo tree's graph starts at ${roots}, not at $2." >&2
            return 1
        fi
        return 0
    fi
    # shellcheck disable=SC2016 # jq program, not shell
    roots=$(jq -r --argjson members "${RS_TREE_MEMBERS}" '[.[] | select(.depth == 0)
        | select("\(.name)@\(.version)" as $r | .kind != "path" or ($members | index($r) | not)) | .label] | join(", ")' "$1")
    if [[ -n "${roots}" ]]; then
        echo "ERROR: cargo tree's graph starts at ${roots}, which is not a member of the workspace." >&2
        return 1
    fi
    if [[ "${RS_TREE_WORKSPACE}" == true ]]; then
        # shellcheck disable=SC2016 # jq program, not shell
        roots=$(jq -r --argjson members "${RS_TREE_MEMBERS}" '[.[] | select(.depth == 0) | "\(.name)@\(.version)"] as $roots
            | [$members[] | select(. as $m | $roots | index($m) | not)] | join(", ")' "$1")
        if [[ -n "${roots}" ]]; then
            echo "ERROR: cargo tree's graph doesn't start at every workspace member: it leaves out ${roots}." >&2
            return 1
        fi
    fi
}
