#!/bin/bash

# Shared helpers for the rust-security-orb commands. Each command passes this
# file to its step as SCRIPT_RUST_SECURITY_LIB, and its script evals it after
# set -euo pipefail, so it only defines functions.

# rs_subst VALUE: prints VALUE with environment variables expanded. The value
# is piped in on stdin: passed as an argument, a value starting with "-" would
# be parsed as a flag. Without the CircleCI CLI (local runs), the value is used
# as is.
rs_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# rs_bool NAME VALUE: prints true or false. CircleCI passes boolean parameters
# as 1 or 0; local callers use true or false.
rs_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            exit 1
            ;;
    esac
}

# split_shell_words STRING: splits STRING into the SHELL_WORDS array the way
# the shell splits a command line into words, but expands and executes
# nothing. Single quotes keep everything literal. Inside double quotes a
# backslash escapes only ", \, $, ` and newline, as in bash. Outside quotes a
# backslash escapes the next character, and a backslash-newline joins lines.
# A # that starts a word starts a comment, which runs to the end of the line.
# Spaces, tabs and newlines separate words, and '' is an empty word. Returns 1
# if a quote is never closed, 2 if the input ends in a backslash outside
# quotes (which escapes nothing), 3 for bash's $'...' or $"..." quoting, which
# it does not implement, 4 for a $(...) or backtick outside quotes, which it
# would not run, and 5 for a shell operator (| & ; < > ( )) outside quotes,
# such as a redirection or a <(...) process substitution.
split_shell_words() {
    local input=$1 word="" in_word=false quote="" char next i
    SHELL_WORDS=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if [[ "${quote}" == "'" ]]; then
            if [[ "${char}" == "'" ]]; then quote=""; else word+=${char}; fi
        elif [[ "${quote}" == '"' ]]; then
            if [[ "${char}" == '"' ]]; then
                quote=""
            elif [[ "${char}" == "\\" ]] && ((i + 1 < ${#input})); then
                next=${input:i+1:1}
                case "${next}" in
                    '"' | "\\" | '$' | '`') word+=${next}; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) word+=${char} ;;
                esac
            else
                word+=${char}
            fi
        else
            case "${char}" in
                ' ' | $'\t' | $'\n')
                    if [[ "${in_word}" == true ]]; then
                        SHELL_WORDS+=("${word}")
                        word=""
                        in_word=false
                    fi
                    ;;
                "'" | '"') quote=${char}; in_word=true ;;
                "#")
                    if [[ "${in_word}" == true ]]; then
                        word+=${char}
                    else
                        while ((i + 1 < ${#input})) && [[ "${input:i+1:1}" != $'\n' ]]; do
                            i=$((i + 1))
                        done
                    fi
                    ;;
                "\\")
                    ((i + 1 < ${#input})) || return 2
                    i=$((i + 1))
                    if [[ "${input:i:1}" != $'\n' ]]; then
                        word+=${input:i:1}
                        in_word=true
                    fi
                    ;;
                '$')
                    case "${input:i+1:1}" in
                        "'" | '"') return 3 ;;
                        "(") return 4 ;;
                    esac
                    word+=${char}
                    in_word=true
                    ;;
                '`') return 4 ;;
                '|' | '&' | ';' | '<' | '>' | '(' | ')') return 5 ;;
                *) word+=${char}; in_word=true ;;
            esac
        fi
    done
    [[ -z "${quote}" ]] || return 1
    if [[ "${in_word}" == true ]]; then
        SHELL_WORDS+=("${word}")
    fi
}

# rs_words PARAMETER VALUE: sets RS_WORDS to VALUE split like shell words
# (see split_shell_words), naming PARAMETER in any error. Nothing in it is
# expanded or executed: a $(...) or backtick that reached a parameter through
# an environment variable (a branch name, a commit message) reaches the tool as
# text inside quotes, and fails the step outside them.
rs_words() {
    local status=0
    split_shell_words "$2" || status=$?
    case "${status}" in
        0) ;;
        1)
            echo "ERROR: ${1} could not be split into arguments: it has a quote that is never closed." >&2
            echo "  A literal ' or \" needs a backslash before it, or quotes of the other kind around it." >&2
            exit 1
            ;;
        2)
            echo "ERROR: ${1} could not be split into arguments: it ends in a backslash." >&2
            echo "  A literal \\ at the end needs another \\ before it." >&2
            exit 1
            ;;
        3)
            echo "ERROR: ${1} could not be split into arguments: \$'...' and \$\"...\" quoting is not supported." >&2
            echo "  Use '...' or \"...\" instead." >&2
            exit 1
            ;;
        4)
            echo "ERROR: ${1} could not be split into arguments: it has a \$(...) or backtick outside quotes." >&2
            echo "  ${1} is not run as shell code, so the command would not run. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
        *)
            echo "ERROR: ${1} could not be split into arguments: it has one of | & ; < > ( ) outside quotes." >&2
            echo "  ${1} is not run as shell code, so pipes, redirections and <(...) would not work. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    RS_WORDS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
}

# rs_env_var_name PARAMETER VALUE: stops the step unless VALUE can name an
# environment variable.
rs_env_var_name() {
    if [[ ! "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "ERROR: ${1} must name an environment variable, not '${2}'." >&2
        exit 1
    fi
}

# rs_export NAME VALUE: exports NAME=VALUE, shell-quoted, to later steps
# through BASH_ENV.
rs_export() {
    if [[ -z "${BASH_ENV:-}" ]]; then
        echo "WARN: BASH_ENV is not set, so ${1} is not exported to later steps." >&2
        return 0
    fi
    printf 'export %s=%q\n' "$1" "$2" >> "${BASH_ENV}"
}

# rs_tool BINARY: sets RS_TOOL to BINARY's path on the PATH, or stops the step
# saying how to install it.
rs_tool() {
    # shellcheck disable=SC2034 # read by the script that evals this file
    if ! RS_TOOL=$(command -v "$1"); then
        echo "ERROR: $1 is not on the PATH. Install it in an earlier step with this orb's install command" >&2
        echo "  (tools: $1), or with install_${1//-/_}." >&2
        exit 1
    fi
}

# rs_require_jq: stops the step unless jq, which the reports are built with,
# is on the PATH.
rs_require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        echo "ERROR: jq is not on the PATH, and this command needs it to read the tool's JSON report." >&2
        echo "  CircleCI's cimg images have it; on other images, install jq in an earlier step." >&2
        exit 1
    fi
}

# rs_output DIR NAME: checks output_dir and report_name, creates DIR, and sets
# RS_OUT to DIR and RS_BASE to the path every report of this run starts with.
rs_output() {
    if [[ "$1" != /* || "$1" == *$'\n'* ]]; then
        echo "ERROR: output_dir must be an absolute path, not '$1'." >&2
        exit 1
    fi
    if [[ ! "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "ERROR: report_name must be letters, digits, '.', '_' and '-', not '$2'." >&2
        exit 1
    fi
    if ! mkdir -p "$1"; then
        echo "ERROR: Could not create output_dir $1." >&2
        exit 1
    fi
    RS_OUT=${1%/}
    RS_OUT=${RS_OUT:-/}
    # shellcheck disable=SC2034 # read by the script that evals this file
    RS_BASE="${RS_OUT%/}/$2"
}

# rs_list PARAMETER VALUE: sets RS_LIST to VALUE, with environment variables
# expanded, split on commas and spaces.
rs_list() {
    local value
    RS_LIST=()
    value=$(rs_subst "$2")
    if [[ "${value}" == *$'\n'* ]]; then
        echo "ERROR: ${1} must be separated by commas or spaces, not newlines." >&2
        exit 1
    fi
    # shellcheck disable=SC2034 # read by the script that evals this file
    read -r -a RS_LIST <<< "${value//,/ }"
}

# rs_sha256 FILE: prints FILE's SHA-256.
rs_sha256() {
    sha256sum "$1" | awk '{ print $1 }'
}

# rs_db_fresh DB_DIR ALLOW_STALE: applies cargo-audit's own rule, a database
# whose newest commit is 90 days old or more is stale, to a run that doesn't
# fetch, where cargo-audit doesn't check it. Stops the step for a stale
# database unless ALLOW_STALE is true, and for a database whose age can't be
# read (not a git checkout), since it could be any age.
rs_db_fresh() {
    local db=$1 committed now age_days
    if ! committed=$(git -C "${db}" log -1 --format=%ct 2> /dev/null) || [[ ! "${committed}" =~ ^[0-9]+$ ]]; then
        if [[ "$2" == true ]]; then
            echo "WARN: The age of the advisory database in ${db} could not be read (it is not a git checkout); allow_stale is true, so it is used anyway." >&2
            return 0
        fi
        echo "ERROR: The age of the advisory database in ${db} could not be read: it is not a git checkout, or git is not installed." >&2
        echo "  Fetch it with fetch_advisory_db, which keeps its git history, or set allow_stale to true to use it whatever its age." >&2
        exit 1
    fi
    now=$(date +%s)
    age_days=$(((now - committed) / 86400))
    if ((now - committed >= 90 * 86400)); then
        if [[ "$2" == true ]]; then
            echo "WARN: The advisory database's newest commit is ${age_days} days old; allow_stale is true, so it is used anyway." >&2
            return 0
        fi
        echo "ERROR: The advisory database's newest commit is ${age_days} days old, and cargo-audit treats a database 90 days old or more as stale." >&2
        echo "  Refresh the copy this job uses (see fetch_advisory_db), or set allow_stale to true." >&2
        exit 1
    fi
    echo "Advisory database: newest commit $(git -C "${db}" log -1 --format=%cI) (${age_days} days old)."
}

# rs_junit FILE SUITE CASES: writes JUnit XML to FILE for CircleCI's Tests
# tab, from CASES, a JSON array of test cases:
#   {"classname": ..., "name": ..., "status": "failed" | "skipped" | "passed",
#    "message": ..., "detail": ...}
# A run with no cases gets one passing case, so the tab shows it ran.
rs_junit() {
    local dir=${1%/*}
    mkdir -p "${dir}"
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r --arg suite "$2" '
        (if length == 0 then [{classname: $suite, name: "no findings", status: "passed"}] else . end) as $cases
        | "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
          "<testsuites>",
          "  <testsuite name=\"\($suite | @html)\" tests=\"\($cases | length)\" failures=\"\([$cases[] | select(.status == "failed")] | length)\" skipped=\"\([$cases[] | select(.status == "skipped")] | length)\">",
          ($cases[] |
            "    <testcase classname=\"\(.classname | @html)\" name=\"\(.name | @html)\">"
            + (if .status == "failed" then "<failure message=\"\((.message // "") | @html)\">\((.detail // "") | @html)</failure>"
               elif .status == "skipped" then "<skipped message=\"\((.message // "") | @html)\"/>"
               else "" end)
            + "</testcase>"),
          "  </testsuite>",
          "</testsuites>"
    ' <<< "$3" > "$1"
}

# rs_gate FINDINGS REPORT_ONLY SUMMARY: ends a check. Without findings it
# succeeds. With findings it fails with SUMMARY, unless REPORT_ONLY is true,
# when it only warns: the reports are written either way.
rs_gate() {
    if [[ "$1" == false ]]; then
        echo "Passed: $3"
        exit 0
    fi
    if [[ "$2" == true ]]; then
        echo "WARN: $3" >&2
        echo "WARN: report_only is true, so this step passes. The reports are in ${RS_OUT}." >&2
        exit 0
    fi
    echo "ERROR: $3" >&2
    echo "  The reports are in ${RS_OUT}. Set report_only to true to report findings without failing." >&2
    exit 1
}

# rs_run_record FILE COMMAND OUTCOME EXIT_CODE STARTED: writes a run record,
# the JSON document schemas/run-record.v1.json describes, saying what exactly
# this command checked, so a reviewer can tell without running it again. It
# reads what the command set:
#   RS_TOOL          the tool binary that ran
#   RS_ARGS          the arguments it ran with, as an array
#   RS_INPUTS        "role:path" entries, such as "lockfile:Cargo.lock"
#   RS_REPORTS       the report files written
#   RS_DB            the advisory database directory used, if any
#   RS_COUNTS        a JSON object of the command's counts
# OUTCOME is passed, findings, findings-reported (findings with report_only)
# or error.
rs_run_record() {
    local file=$1 entry path role sha tool_json db_json="null" toolchain args inputs="[]" reports="[]" install="null"
    local tool_sha=""
    for entry in ${RS_INPUTS[@]+"${RS_INPUTS[@]}"}; do
        role=${entry%%:*}
        path=${entry#*:}
        sha=""
        if [[ -f "${path}" ]]; then
            sha=$(rs_sha256 "${path}")
            path=$(cd "$(dirname "${path}")" && pwd)/${path##*/}
        fi
        inputs=$(jq -c --arg role "${role}" --arg path "${path}" --arg sha "${sha}" \
            '. + [{role: $role, path: $path, sha256: (if $sha == "" then null else $sha end)}]' <<< "${inputs}")
    done
    for path in ${RS_REPORTS[@]+"${RS_REPORTS[@]}"}; do
        if [[ -f "${path}" ]]; then
            reports=$(jq -c --arg path "${path}" --arg sha "$(rs_sha256 "${path}")" '. + [{path: $path, sha256: $sha}]' <<< "${reports}")
        fi
    done
    if [[ -n "${RS_TOOL:-}" && -f "${RS_TOOL}" ]]; then
        tool_sha=$(sha512sum "${RS_TOOL}" | awk '{ print $1 }')
        entry="$(dirname "${RS_TOOL}")/.${RS_TOOL##*/}.install.json"
        # The install record counts only if it describes this very binary.
        if [[ -f "${entry}" ]] && jq -e --arg sha "${tool_sha}" '.binary_sha512 == $sha' "${entry}" > /dev/null 2>&1; then
            install=$(jq -c 'del(.binary_sha512)' "${entry}")
        fi
    fi
    tool_json=$(jq -cn --arg name "${RS_TOOL##*/}" --arg path "${RS_TOOL:-}" --arg version "${RS_TOOL_VERSION:-}" \
        --arg sha "${tool_sha}" --argjson install "${install}" \
        '{name: $name, path: $path, version: $version, sha512: (if $sha == "" then null else $sha end), install: $install}')
    if [[ -n "${RS_DB:-}" ]]; then
        db_json=$(jq -cn --arg path "${RS_DB}" \
            --arg url "$(git -C "${RS_DB}" remote get-url origin 2> /dev/null || true)" \
            --arg commit "$(git -C "${RS_DB}" log -1 --format=%H 2> /dev/null || true)" \
            --arg time "$(git -C "${RS_DB}" log -1 --format=%cI 2> /dev/null || true)" \
            '{path: $path, url: (if $url == "" then null else $url end), commit: (if $commit == "" then null else $commit end),
                commit_time: (if $time == "" then null else $time end)}')
    fi
    # NUL-separated, so arguments that start with "-" never reach jq's own
    # option parsing.
    args=$(printf '%s\0' ${RS_ARGS[@]+"${RS_ARGS[@]}"} | jq -Rsc 'split("\u0000") | .[:-1]')
    toolchain=$(jq -cn --arg cargo "$(cargo --version 2> /dev/null || true)" --arg rustc "$(rustc --version 2> /dev/null || true)" \
        '{cargo: (if $cargo == "" then null else $cargo end), rustc: (if $rustc == "" then null else $rustc end)}')
    if ! jq -n --arg command "$2" --arg outcome "$3" --argjson code "$4" --arg started "$5" \
        --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "$(pwd)" \
        --argjson tool "${tool_json}" --argjson toolchain "${toolchain}" --argjson db "${db_json}" \
        --argjson inputs "${inputs}" --argjson reports "${reports}" --argjson counts "${RS_COUNTS:-null}" \
        --arg build_url "${CIRCLE_BUILD_URL:-}" --arg sha1 "${CIRCLE_SHA1:-}" --arg job "${CIRCLE_JOB:-}" \
        --argjson args "${args}" '{
            schema: "https://github.com/juburr/rust-security-orb/blob/main/schemas/run-record.v1.json",
            command: $command, outcome: $outcome, exit_code: $code,
            started_at: $started, finished_at: $finished,
            ci: (if $build_url == "" then null else {build_url: $build_url, sha1: $sha1, job: $job} end),
            working_directory: $cwd,
            tool: $tool, arguments: $args, toolchain: $toolchain,
            advisory_db: $db, inputs: $inputs, counts: $counts, reports: $reports
        }' > "${file}"; then
        echo "WARN: Could not write the run record ${file}." >&2
        return 0
    fi
    echo "Run record: ${file}"
}

# rs_audit_options: reads the cargo audit parameters the audit and audit_bin
# commands share (db_path, no_fetch, allow_stale, deny, target_arch,
# target_os, no_yanked) and sets:
#   RS_AUDIT_OPTS    the cargo audit options they make
#   RS_DENIED        the warning kinds deny turns into errors
#   RS_DB            the advisory database directory cargo audit reads
#   RS_NO_FETCH      true when the database is used without fetching
# The database is db_path, or else the one fetch_advisory_db exported in
# RUSTSEC_ADVISORY_DB, or else cargo-audit's default. Without fetching,
# cargo audit doesn't check the database's age, so rs_db_fresh applies its
# rule here.
rs_audit_options() {
    local db allow_stale no_yanked kind value
    db=$(rs_subst "${PARAM_DB_PATH}")
    db=${db:-${RUSTSEC_ADVISORY_DB:-}}
    RS_NO_FETCH=$(rs_bool no_fetch "${PARAM_NO_FETCH}")
    allow_stale=$(rs_bool allow_stale "${PARAM_ALLOW_STALE}")
    no_yanked=$(rs_bool no_yanked "${PARAM_NO_YANKED}")
    RS_AUDIT_OPTS=()
    RS_DENIED=()
    if [[ -n "${db}" ]]; then
        RS_AUDIT_OPTS+=(--db "${db}")
    fi
    # shellcheck disable=SC2034 # read by rs_run_record
    RS_DB=${db:-${CARGO_HOME:-${HOME:-}/.cargo}/advisory-db}
    if [[ "${RS_NO_FETCH}" == true ]]; then
        RS_AUDIT_OPTS+=(--no-fetch)
        rs_db_fresh "${RS_DB}" "${allow_stale}"
    elif [[ "${allow_stale}" == true ]]; then
        RS_AUDIT_OPTS+=(--stale)
    fi
    rs_list deny "${PARAM_DENY}"
    for kind in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
        case "${kind}" in
            warnings | unmaintained | unsound | yanked) ;;
            *)
                echo "ERROR: deny takes warnings, unmaintained, unsound and yanked, not '${kind}'." >&2
                exit 1
                ;;
        esac
        RS_DENIED+=("${kind}")
        RS_AUDIT_OPTS+=(--deny "${kind}")
    done
    rs_list target_arch "${PARAM_TARGET_ARCH}"
    for value in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
        RS_AUDIT_OPTS+=(--target-arch "${value}")
    done
    rs_list target_os "${PARAM_TARGET_OS}"
    for value in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
        RS_AUDIT_OPTS+=(--target-os "${value}")
    done
    if [[ "${no_yanked}" == true ]]; then
        RS_AUDIT_OPTS+=(--no-yanked)
    fi
}

# rs_audit_extra_args: sets RS_EXTRA to the extra_args words, refusing the
# options that would change the report format these commands write.
rs_audit_extra_args() {
    local word extra
    extra=$(rs_subst "${PARAM_EXTRA_ARGS}")
    rs_words extra_args "${extra}"
    RS_EXTRA=(${RS_WORDS[@]+"${RS_WORDS[@]}"})
    for word in ${RS_EXTRA[@]+"${RS_EXTRA[@]}"}; do
        case "${word}" in
            --json | --format | --format=*)
                echo "ERROR: extra_args can't set ${word}: this command writes the JSON and SARIF reports itself." >&2
                exit 1
                ;;
        esac
    done
}

# rs_audit_counts JSON: prints the counts of a cargo audit JSON report, with
# the warnings RS_DENIED turns into errors counted as denied_warnings.
rs_audit_counts() {
    jq -c --argjson denied "$(rs_denied_json)" '{
        vulnerabilities: .vulnerabilities.count,
        warnings: (.warnings | map_values(length)),
        denied_warnings: ([.warnings | to_entries[] | .key as $k | select(($denied | index("warnings")) or ($denied | index($k))) | .value | length] | add // 0)
    }' "$1"
}

# rs_denied_json: prints RS_DENIED as a JSON array.
rs_denied_json() {
    printf '%s\n' ${RS_DENIED[@]+"${RS_DENIED[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))'
}

# rs_audit_summary JSON PREFIX: prints a cargo audit JSON report's findings,
# one per line, each line starting with PREFIX.
rs_audit_summary() {
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r --arg prefix "$2" '
        (.vulnerabilities.list[] | "\($prefix)vulnerability  \(.advisory.id)  \(.package.name) \(.package.version)  \(.advisory.title)"),
        (.warnings | to_entries[] | .value[] | "\($prefix)\(.kind)  \(.advisory.id // "-")  \(.package.name) \(.package.version)\(if .advisory then "  " + .advisory.title else "" end)")
    ' "$1"
}

# rs_audit_cases JSON CLASSNAME: prints a cargo audit JSON report's findings
# as JUnit test cases for rs_junit: vulnerabilities and denied warnings fail,
# other warnings are skipped.
rs_audit_cases() {
    # shellcheck disable=SC2016 # jq program, not shell
    jq -c --argjson denied "$(rs_denied_json)" --arg class "$2" '
        [(.vulnerabilities.list[] | {
            classname: "\($class).vulnerability",
            name: "\(.advisory.id) \(.package.name) \(.package.version)",
            status: "failed",
            message: .advisory.title,
            detail: "\(.advisory.url // ("https://rustsec.org/advisories/" + .advisory.id))\nPatched: \((.versions.patched // []) | join(", ") | if . == "" then "none" else . end)"
        }),
        (.warnings | to_entries[] | .key as $kind | .value[] | {
            classname: "\($class).\($kind)",
            name: "\(.advisory.id // $kind) \(.package.name) \(.package.version)",
            status: (if ($denied | index("warnings")) or ($denied | index($kind)) then "failed" else "skipped" end),
            message: (.advisory.title // "\($kind) crate"),
            detail: (.advisory.url // "")
        })]' "$1"
}
