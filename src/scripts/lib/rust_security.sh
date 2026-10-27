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

# rs_match VALUE REGEX: [[ VALUE =~ REGEX ]] in the C locale, setting
# BASH_REMATCH. In other locales a range such as [a-z] can match letters such
# as é (cimg images set LC_ALL=en_US.UTF-8), so checks with ranges use this.
rs_match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

# rs_env_var_name PARAMETER VALUE: stops the step unless VALUE can name an
# environment variable.
rs_env_var_name() {
    if ! rs_match "$2" '^[A-Za-z_][A-Za-z0-9_]*$'; then
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

# rs_json_is FILE FILTER [JQ_OPTION...]: whether FILE holds one JSON value for
# which FILTER is true. It compares jq's output instead of using -e, since jq
# 1.6 (as on Ubuntu 22.04 and some cimg images) exits 0 with -e when the file
# is empty, as a tool that failed before writing its report leaves it.
rs_json_is() {
    local file=$1 filter=$2 options=()
    if [[ $# -gt 2 ]]; then
        options=("${@:3}")
    fi
    [[ "$(jq -c ${options[@]+"${options[@]}"} "(${filter}) | if . then true else false end" "${file}" 2> /dev/null)" == true ]]
}

# rs_tool BINARY: sets RS_TOOL to BINARY's path on the PATH, or stops the step
# saying how to install it. Warns when that binary is not one the install
# command verified, such as a copy installed with the image that comes first
# on the PATH: the install command leaves a record beside each binary it
# installs, naming the binary's SHA-512.
rs_tool() {
    if ! RS_TOOL=$(command -v "$1"); then
        echo "ERROR: $1 is not on the PATH. Install it in an earlier step with this orb's install command" >&2
        echo "  (tools: $1), or with install_${1//-/_}." >&2
        exit 1
    fi
    rs_tool_verified "$1" "${RS_TOOL}"
}

# rs_tool_verified NAME PATH: warns unless PATH is a NAME this orb's install
# command verified, as the install record it leaves beside the binary says.
rs_tool_verified() {
    if ! rs_is_verified "$1" "$2"; then
        echo "WARN: $2 is not the $1 this orb's install command verified against its checksum table." >&2
        echo "WARN: Install $1 with the install command, and put its install_path first on the PATH, to run a verified one." >&2
    fi
}

# rs_is_verified NAME PATH: whether PATH is a NAME this orb's install command
# verified.
rs_is_verified() {
    local record sha
    record="$(dirname "$2")/.$1.install.json"
    sha=$(sha512sum -- "$2" 2> /dev/null | awk '{ print $1 }') || sha=""
    [[ -n "${sha}" && -f "${record}" ]] && grep -qF "\"binary_sha512\":\"${sha}\"" "${record}"
}

# The shape cargo auditable's dependency list has, as jq: a format, when there
# is one, that is a whole number (cargo auditable before 0.7 writes none, and
# never writes 0); a non-empty packages array of objects with a name, version
# and source, exactly one of them the root; and dependencies that are indices
# into packages. rust-audit-info checks none of it, so it is checked here for
# both decoders.
# shellcheck disable=SC2016 # jq program, not shell
RS_DEP_V0_SHAPE='type == "object" and ((has("format") | not) or (.format | type == "number" and . == floor and . >= 0))
    and (.packages | type == "array" and length > 0)
    and all(.packages[]; type == "object" and (.name | type == "string") and (.version | type == "string") and (.source | type == "string"))
    and ([.packages[] | select(.root == true)] | length == 1)
    and ((.packages | length) as $n | all(.packages[]; (.dependencies // []) | type == "array"
        and all(.[]; type == "number" and . == floor and . >= 0 and . < $n)))'

# rs_decoder VALUE: picks how the dependency list cargo auditable embeds in a
# binary (its .dep-v0 section) is read: decoder VALUE is rust-audit-info, the
# tool the install command builds from source; native, the orb's own decoder
# (scripts/lib/dep_v0.py, passed as SCRIPT_DEP_V0_PY), which needs only
# python3 and reads ELF binaries of any architecture; or auto, which takes a
# rust-audit-info the install command verified, or else native, or else an
# unverified rust-audit-info, with a warning. Sets RS_DECODER (native or
# rust-audit-info) and RS_DECODER_TOOL (the binary that runs), and for native,
# RS_PROGRAM_PATH, RS_PROGRAM_NAME and RS_PROGRAM_SHA256 for the run record.
rs_decoder() {
    local tool python
    RS_DECODER=""
    RS_DECODER_TOOL=""
    case "$1" in
        auto | native | rust-audit-info) ;;
        *)
            echo "ERROR: decoder must be auto, native or rust-audit-info, not '$1'." >&2
            exit 1
            ;;
    esac
    tool=$(command -v rust-audit-info) || tool=""
    python=$(command -v python3) || python=""
    # rust-audit-info when asked for, or with auto when the install command
    # verified it.
    if [[ -n "${tool}" ]] && { [[ "$1" == rust-audit-info ]] || { [[ "$1" == auto ]] && rs_is_verified rust-audit-info "${tool}"; }; }; then
        rs_tool_verified rust-audit-info "${tool}"
        RS_DECODER=rust-audit-info
        RS_DECODER_TOOL=${tool}
        return 0
    fi
    if [[ "$1" != rust-audit-info && -n "${python}" ]]; then
        if [[ -z "${SCRIPT_DEP_V0_PY:-}" ]]; then
            echo "ERROR: The native decoder was not loaded: SCRIPT_DEP_V0_PY is empty." >&2
            exit 1
        fi
        RS_DECODER=native
        RS_DECODER_TOOL=${python}
        RS_PROGRAM_PATH=${python}
        # shellcheck disable=SC2034 # read by rs_tool_json
        RS_PROGRAM_NAME=dep_v0.py
        # shellcheck disable=SC2034 # read by rs_tool_json
        # As the file is in the orb's source, ending in one newline, whatever
        # the step's environment kept of it.
        RS_PROGRAM_SHA256=$(printf '%s\n' "$(printf '%s' "${SCRIPT_DEP_V0_PY}")" | sha256sum | awk '{ print $1 }')
        return 0
    fi
    # auto without python3 takes the rust-audit-info there is, verified or not.
    if [[ "$1" == auto && -n "${tool}" ]]; then
        rs_tool_verified rust-audit-info "${tool}"
        RS_DECODER=rust-audit-info
        RS_DECODER_TOOL=${tool}
        return 0
    fi
    case "$1" in
        rust-audit-info) echo "ERROR: decoder rust-audit-info needs rust-audit-info, which is not on the PATH. Add" >&2 ;;
        native) echo "ERROR: decoder native needs python3, which is not on the PATH. Install Python 3 in an earlier step, or add" >&2 ;;
        *) echo "ERROR: Reading cargo-auditable data needs rust-audit-info or python3, and neither is on the PATH. Add" >&2 ;;
    esac
    echo "  rust-audit-info to the install command's tools (it builds with cargo), or install Python 3 for decoder: native." >&2
    exit 1
}

# rs_decode BINARY OUTPUT LOG: writes the dependency list BINARY carries to
# OUTPUT with RS_DECODER, and returns 0 when it decodes and has the shape
# cargo auditable writes, 1 (with the reason in LOG) when there is none or it
# doesn't, and 2 (with the reason in LOG) when the decoder can't tell, such as
# for a file the native decoder can't read (it reads ELF only).
rs_decode() {
    local rc=0
    if [[ "${RS_DECODER}" == native ]]; then
        "${RS_DECODER_TOOL}" -I -c "${SCRIPT_DEP_V0_PY}" "$1" > "$2" 2> "$3" || rc=$?
        if [[ "${rc}" -ne 0 ]]; then
            return $((rc == 1 ? 1 : 2))
        fi
    elif ! "${RS_DECODER_TOOL}" "$1" > "$2" 2> "$3"; then
        return 1
    fi
    if ! rs_json_is "$2" "${RS_DEP_V0_SHAPE}"; then
        echo "Its dependency list is not the JSON cargo auditable writes: packages, one root, dependencies within them." > "$3"
        return 1
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
    if ! rs_match "$2" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
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

# rs_list_lines PARAMETER VALUE: as rs_list, but newlines separate items too,
# for lists that run long, such as files and dependency-graph node sets.
rs_list_lines() {
    local value
    RS_LIST=()
    value=$(rs_subst "$2")
    value=${value//[$'\n\r\t']/ }
    # shellcheck disable=SC2034 # read by the script that evals this file
    read -r -a RS_LIST <<< "${value//,/ }"
}

# rs_files PARAMETER: sets RS_FILES to the files RS_LIST names, with shell
# patterns expanded, each file once, in order. A pattern that matches
# nothing, and a name that isn't a file, stop the step: a file that isn't
# there can't pass a check. A name that starts with "-" becomes ./<name>,
# which no tool reads as an option.
rs_files() {
    local pattern file restore=false
    local -a matches=()
    local -A seen=()
    RS_FILES=()
    if ! shopt -q nullglob; then
        restore=true
        shopt -s nullglob
    fi
    for pattern in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
        # The pattern is expanded here on purpose.
        # shellcheck disable=SC2206
        matches=(${pattern})
        if [[ ${#matches[@]} -eq 0 ]]; then
            echo "ERROR: $1 names ${pattern}, which matches no file (in $(pwd))." >&2
            exit 1
        fi
        for file in "${matches[@]}"; do
            if [[ ! -f "${file}" ]]; then
                echo "ERROR: $1 names ${file}, which is not a file (in $(pwd))." >&2
                exit 1
            fi
            if [[ "${file}" == -* ]]; then
                file="./${file}"
            fi
            if [[ -z "${seen[${file}]:-}" ]]; then
                seen[${file}]=1
                RS_FILES+=("${file}")
            fi
        done
    done
    if [[ "${restore}" == true ]]; then
        shopt -u nullglob
    fi
}

# rs_slug PATH NAME: sets RS_SLUG to the name the reports for the input PATH
# get in a run over several inputs, <report_name>-<slug>: PATH relative to
# the working directory, without a last component NAME (Cargo.lock or
# Cargo.toml), with / as -, characters a report name can't hold as _, and
# root for the working directory itself.
rs_slug() {
    # In other locales [^A-Za-z0-9] can leave letters such as é alone.
    local path LC_ALL=C
    path=$(realpath -m -s --relative-to=. -- "$1" 2> /dev/null) || path=$1
    if [[ "${path}" == "$2" ]]; then
        path=""
    fi
    path=${path%/"$2"}
    path=${path//\//-}
    path=${path//[^A-Za-z0-9._-]/_}
    # shellcheck disable=SC2034 # read by the script that evals this file
    RS_SLUG=${path:-root}
}

# rs_sha256 FILE: prints FILE's SHA-256.
rs_sha256() {
    sha256sum -- "$1" | awk '{ print $1 }'
}

# rs_db_fresh DB_DIR ALLOW_STALE: applies cargo-audit's own rule, a database
# whose newest commit is 90 days old or more is stale, to a run that doesn't
# fetch, where cargo-audit doesn't check it. Stops the step for a stale
# database unless ALLOW_STALE is true, and for a database whose age can't be
# read (not a git checkout), since it could be any age.
rs_db_fresh() {
    local db=$1 committed now age_days
    # git -C searches parent directories, so a database without its own .git
    # inside another work tree would be dated by that repository instead.
    if [[ ! -e "${db}/.git" ]] || ! committed=$(git -C "${db}" log -1 --format=%ct 2> /dev/null) \
        || [[ ! "${committed}" =~ ^[0-9]+$ ]]; then
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
    # A commit dated in the future would never look stale. A day covers clock
    # skew between the machine that committed and this one.
    if ((committed - now > 86400)); then
        if [[ "$2" == true ]]; then
            echo "WARN: The advisory database's newest commit is dated $(((committed - now) / 86400)) days in the future; allow_stale is true, so it is used anyway." >&2
            return 0
        fi
        echo "ERROR: The advisory database's newest commit is dated $(((committed - now) / 86400)) days in the future, so its age can't be told." >&2
        echo "  Check the clock of whatever made the copy, or set allow_stale to true to use it whatever its age." >&2
        exit 1
    fi
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
    # shellcheck disable=SC2016 # jq program, not shell
    rs_junit_suites "$1" "$(jq -c --arg suite "$2" '[{name: $suite, cases: .}]' <<< "$3")"
}

# rs_junit_suites FILE SUITES: writes JUnit XML as rs_junit does, with one
# test suite per input of a command that checks several: SUITES is a JSON
# array of {"name": ..., "cases": CASES}.
rs_junit_suites() {
    local dir=${1%/*}
    mkdir -p "${dir}"
    jq -r '
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<testsuites>",
        (.[] | .name as $suite
          | (if (.cases | length) == 0 then [{classname: $suite, name: "no findings", status: "passed"}] else .cases end) as $cases
          | "  <testsuite name=\"\($suite | @html)\" tests=\"\($cases | length)\" failures=\"\([$cases[] | select(.status == "failed")] | length)\" skipped=\"\([$cases[] | select(.status == "skipped")] | length)\">",
            ($cases[] |
              "    <testcase classname=\"\(.classname | @html)\" name=\"\(.name | @html)\">"
              + (if .status == "failed" then "<failure message=\"\((.message // "") | @html)\">\((.detail // "") | @html)</failure>"
                 elif .status == "skipped" then "<skipped message=\"\((.message // "") | @html)\"/>"
                 else "" end)
              + "</testcase>"),
            "  </testsuite>"),
        "</testsuites>"
    ' <<< "$2" > "$1"
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
#   RS_OTHER_TOOLS   other binaries the command ran, as an array
#   RS_ARGS          the arguments it ran with, as an array
#   RS_INPUTS        "role:path" entries, such as "lockfile:Cargo.lock"; when
#                    they include manifests, rs_path_manifest_inputs adds the
#                    manifests of the lockfile's other path packages
#   RS_REPORTS       the report files written
#   RS_DB            the advisory database directory used, if any
#   RS_COUNTS        a JSON object of the command's counts
#   RS_EXCEPTIONS    the exceptions a check guards, as a JSON array (the
#                    tree commands); the record has no exceptions without it
# OUTCOME is passed, findings, findings-reported (findings with report_only),
# skipped (a check whose precondition didn't hold) or error.
rs_run_record() {
    local file=$1 entry path role sha tool_json others="[]" db_json="null" toolchain args inputs="[]" reports="[]" url match
    local -A listed=()
    rs_path_manifest_inputs
    case "$2" in
        deny | licenses | sbom) rs_license_inputs ;;
    esac
    for entry in ${RS_INPUTS[@]+"${RS_INPUTS[@]}"}; do
        role=${entry%%:*}
        path=${entry#*:}
        sha=""
        if [[ -f "${path}" ]]; then
            sha=$(rs_sha256 "${path}")
            path=$(cd "$(dirname "${path}")" && pwd)/${path##*/}
        fi
        # A command that checks several inputs can find the same file for
        # more than one, such as a shared config.
        if [[ -n "${listed[${role}:${path}]:-}" ]]; then
            continue
        fi
        listed[${role}:${path}]=1
        inputs=$(jq -c --arg role "${role}" --arg path "${path}" --arg sha "${sha}" \
            '. + [{role: $role, path: $path, sha256: (if $sha == "" then null else $sha end)}]' <<< "${inputs}")
    done
    for path in ${RS_REPORTS[@]+"${RS_REPORTS[@]}"}; do
        if [[ -f "${path}" && -z "${listed[report:${path}]:-}" ]]; then
            listed[report:${path}]=1
            reports=$(jq -c --arg path "${path}" --arg sha "$(rs_sha256 "${path}")" '. + [{path: $path, sha256: $sha}]' <<< "${reports}")
        fi
    done
    tool_json=$(rs_tool_json "${RS_TOOL:-}" "${RS_TOOL_VERSION:-}")
    for path in ${RS_OTHER_TOOLS[@]+"${RS_OTHER_TOOLS[@]}"}; do
        others=$(jq -c --argjson tool "$(rs_tool_json "${path}" "")" '. + [$tool]' <<< "${others}")
    done
    if [[ -n "${RS_DB:-}" && ! -e "${RS_DB}/.git" ]]; then
        db_json=$(jq -cn --arg path "${RS_DB}" '{path: $path, url: null, commit: null, commit_time: null, files_match_commit: null}')
    elif [[ -n "${RS_DB:-}" ]]; then
        # A remote URL can carry credentials (https://user:token@host/... or
        # ?access_token=...), which must not reach a stored artifact.
        url=$(git -C "${RS_DB}" remote get-url origin 2> /dev/null || true)
        url=$(rs_url_public "${url}")
        # A database passed through db_path, or one already in place, can
        # differ from its commit, which then doesn't identify what the tool
        # scanned.
        match=$(rs_db_files_match "${RS_DB}")
        if [[ "${match}" == false ]]; then
            echo "WARN: The advisory database's files in ${RS_DB} differ from its newest commit, so that commit doesn't" >&2
            echo "WARN: identify what was scanned. The run record says files_match_commit: false." >&2
        fi
        db_json=$(jq -cn --arg path "${RS_DB}" \
            --arg url "${url}" \
            --arg commit "$(git -C "${RS_DB}" log -1 --format=%H 2> /dev/null || true)" \
            --arg time "$(git -C "${RS_DB}" log -1 --format=%cI 2> /dev/null || true)" \
            --argjson match "${match}" \
            '{path: $path, url: (if $url == "" then null else $url end), commit: (if $commit == "" then null else $commit end),
                commit_time: (if $time == "" then null else $time end), files_match_commit: $match}')
    fi
    # A URL among the arguments, such as cargo audit's --url from extra_args,
    # loses its userinfo, query and fragment, as the database's URL does.
    args=$(rs_public_args ${RS_ARGS[@]+"${RS_ARGS[@]}"})
    toolchain=$(jq -cn --arg cargo "$(cargo --version 2> /dev/null || true)" --arg rustc "$(rustc --version 2> /dev/null || true)" \
        '{cargo: (if $cargo == "" then null else $cargo end), rustc: (if $rustc == "" then null else $rustc end)}')
    if ! jq -n --arg command "$2" --arg outcome "$3" --argjson code "$4" --arg started "$5" \
        --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "$(pwd)" \
        --argjson tool "${tool_json}" --argjson others "${others}" --argjson toolchain "${toolchain}" --argjson db "${db_json}" \
        --argjson inputs "${inputs}" --argjson reports "${reports}" --argjson counts "${RS_COUNTS:-null}" \
        --argjson ci "$(rs_ci_json)" --argjson args "${args}" --argjson exceptions "${RS_EXCEPTIONS:-null}" '{
            schema: "https://github.com/juburr/rust-security-orb/blob/main/schemas/run-record.v1.json",
            command: $command, outcome: $outcome, exit_code: $code,
            started_at: $started, finished_at: $finished,
            ci: $ci,
            working_directory: $cwd,
            tool: $tool, other_tools: $others, arguments: $args, toolchain: $toolchain,
            advisory_db: $db, inputs: $inputs, counts: $counts, reports: $reports
        } + (if $exceptions == null then {} else {exceptions: $exceptions} end)' > "${file}"; then
        echo "WARN: Could not write the run record ${file}." >&2
        return 0
    fi
    echo "Run record: ${file}"
}

# rs_ci_json: the CI job a run record names: a CircleCI job, a GitHub Actions
# run, or null.
rs_ci_json() {
    if [[ -n "${CIRCLE_BUILD_URL:-}" ]]; then
        jq -cn --arg url "${CIRCLE_BUILD_URL}" --arg sha "${CIRCLE_SHA1:-}" --arg job "${CIRCLE_JOB:-}" \
            '{provider: "circleci", build_url: $url, sha1: $sha, job: $job}'
    elif [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        jq -cn --arg url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}/attempts/${GITHUB_RUN_ATTEMPT:-1}" \
            --arg sha "${GITHUB_SHA:-}" --arg job "${GITHUB_JOB:-}" \
            '{provider: "github-actions", build_url: $url, sha1: $sha, job: $job}'
    else
        echo null
    fi
}

# rs_public_args ARG...: prints the arguments as a JSON array, with every URL
# in them stripped of its userinfo, query and fragment, which can hold
# credentials (https://user:token@host/... or ?access_token=...). They reach
# jq NUL-separated, so an argument that starts with "-" never reaches jq's
# own option parsing.
rs_public_args() {
    # Bash 4.0 calls an empty "$@" unbound under set -u.
    if [[ $# -eq 0 ]]; then
        echo "[]"
        return 0
    fi
    # Ended by a word rather than a NUL, which jq 1.6 drops from the end of
    # raw input.
    { printf '%s\0' "$@"; printf 'end'; } | jq -Rsc 'split("\u0000") | .[:-1]
        | map(gsub("(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)[^/?#\\s]*@"; "\(.scheme)")
            | gsub("(?<url>[A-Za-z][A-Za-z0-9+.-]*://[^?#\\s]*)[?#]\\S*"; "\(.url)"))'
}

# rs_show_command PROGRAM ARG...: prints the command a step runs, as one line
# a shell would read back, with URLs stripped as in run records, so a failed
# job's log says exactly what ran.
rs_show_command() {
    echo "Running: $(rs_public_args "$@" | jq -r 'map(if test("^[A-Za-z0-9_@%+=:,./{}-]+$") then . else @sh end) | join(" ")')"
}

# rs_tool_json PATH VERSION: describes a binary that ran for the run record:
# its SHA-512, and how the orb installed it, from the install record beside
# it when that record describes this very binary.
rs_tool_json() {
    local sha="" install="null" entry program="null"
    if [[ -n "$1" && -f "$1" ]]; then
        # Without sha512sum the record says so with a null SHA-512, as rs_tool
        # only warns.
        sha=$(sha512sum -- "$1" 2> /dev/null | awk '{ print $1 }') || sha=""
        entry="$(dirname "$1")/.${1##*/}.install.json"
        # shellcheck disable=SC2016 # jq program, not shell
        if [[ -f "${entry}" ]] && rs_json_is "${entry}" '.binary_sha512 == $sha' --arg sha "${sha}"; then
            install=$(jq -c 'del(.binary_sha512)' "${entry}")
        fi
    fi
    # An interpreter that ran a program of the orb's, such as python3 the
    # native .dep-v0 decoder: the program, by its SHA-256.
    if [[ -n "$1" && "$1" == "${RS_PROGRAM_PATH:-}" ]]; then
        program=$(jq -cn --arg name "${RS_PROGRAM_NAME}" --arg sha "${RS_PROGRAM_SHA256}" '{name: $name, sha256: $sha}')
    fi
    jq -cn --arg name "${1##*/}" --arg path "$1" --arg version "$2" --arg sha "${sha}" --argjson install "${install}" \
        --argjson program "${program}" '{name: $name, path: $path, version: $version, sha512: (if $sha == "" then null else $sha end),
            install: $install} + (if $program == null then {} else {program: $program} end)'
}

# rs_manifest_inputs METADATA: adds the workspace's manifests to RS_INPUTS,
# from the output of cargo metadata --no-deps: the workspace root's Cargo.toml
# and every member's. Their features, package metadata and workspace
# inheritance shape what the tools report, besides the lockfile.
rs_manifest_inputs() {
    local manifest
    while IFS= read -r manifest; do
        if [[ -n "${manifest}" ]]; then
            RS_INPUTS+=("manifest:${manifest}")
        fi
    done < <(jq -r '[(.workspace_root + "/Cargo.toml"),
        (.workspace_members as $m | .packages[] | select(.id as $id | $m | index($id)) | .manifest_path)] | unique[]' <<< "$1" 2> /dev/null)
}

# rs_db_files_match DIR: prints true when the files in the git checkout DIR
# are exactly its newest commit's, none missing, changed or added, false when
# they aren't, and null when git can't tell. It hashes the files itself rather
# than ask git status, which an index's skip-worktree (sparse) and
# assume-unchanged entries mislead, and with --no-filters, so nothing the
# repository's config names runs. It opens regular files only: a symbolic
# link is hashed as its target's path, as git commits it, and a FIFO, socket
# or device, which no commit holds and which could block forever, is a
# difference. So is a link that resolves outside the checkout or into its
# .git, even a committed one: the tools follow it to contents no commit
# holds.
rs_db_files_match() {
    local committed files links other sums entry target root resolved i
    local -a paths=() hashes=() lines=()
    if ! committed=$(git -C "$1" -c core.quotePath=false ls-tree -r --full-tree HEAD 2> /dev/null \
        | awk -F '\t' '{ split($1, f, " "); print f[3] " " $2 }' | LC_ALL=C sort) \
        || ! files=$(cd "$1" && find . -path ./.git -prune -o -type f -print | sed 's|^\./||') \
        || ! links=$(cd "$1" && find . -path ./.git -prune -o -type l -print | sed 's|^\./||') \
        || ! other=$(cd "$1" && find . -path ./.git -prune -o ! -type d ! -type f ! -type l -print); then
        echo null
        return 0
    fi
    if [[ -n "${other}" ]]; then
        echo false
        return 0
    fi
    if [[ -n "${files}" ]]; then
        if ! sums=$(cd "$1" && git hash-object --no-filters --stdin-paths <<< "${files}" 2> /dev/null); then
            echo null
            return 0
        fi
        mapfile -t paths <<< "${files}"
        mapfile -t hashes <<< "${sums}"
        for ((i = 0; i < ${#paths[@]}; i++)); do
            lines+=("${hashes[i]:-} ${paths[i]}")
        done
    fi
    if [[ -n "${links}" ]]; then
        if ! root=$(cd "$1" && pwd -P); then
            echo null
            return 0
        fi
        while IFS= read -r entry; do
            if ! resolved=$(cd "$1" && readlink -f "./${entry}") \
                || [[ "${resolved}" != "${root}/"* || "${resolved}" == "${root}/.git" || "${resolved}" == "${root}/.git/"* ]]; then
                echo false
                return 0
            fi
            if ! target=$(cd "$1" && readlink "./${entry}") \
                || ! sums=$(printf '%s' "${target}" | git -C "$1" hash-object --stdin 2> /dev/null); then
                echo null
                return 0
            fi
            lines+=("${sums} ${entry}")
        done <<< "${links}"
    fi
    if [[ "${committed}" == "$(printf '%s\n' ${lines[@]+"${lines[@]}"} | LC_ALL=C sort)" ]]; then
        echo true
    else
        echo false
    fi
}

# rs_path_manifest_inputs: when RS_INPUTS lists manifests, adds those of
# each lockfile's other path packages: path dependencies outside its
# workspace, and [patch] and [replace] paths. Their package metadata
# (licence, publish, description) shapes what the tools report, and changing
# it changes neither the lockfile nor the workspace's manifests. cargo pkgid
# finds each one's directory from the lockfile alone, without the network.
# rs_run_record runs it, since cargo can write the lockfile during the run.
rs_path_manifest_inputs() {
    local entry lockfile manifests=false root spec id encoded dir byte
    local -a lockfiles=()
    local -A known=() seen=() members=()
    for entry in ${RS_INPUTS[@]+"${RS_INPUTS[@]}"}; do
        case "${entry}" in
            manifest:*)
                manifests=true
                known[${entry#manifest:}]=1
                ;;
            lockfile:*)
                # Several with deny's and the tree commands' manifest_paths,
                # one per workspace.
                if [[ -z "${seen[${entry#lockfile:}]:-}" ]]; then
                    seen[${entry#lockfile:}]=1
                    lockfiles+=("${entry#lockfile:}")
                fi
                ;;
        esac
    done
    if [[ "${manifests}" != true ]] || ! command -v cargo > /dev/null 2>&1; then
        return 0
    fi
    for lockfile in ${lockfiles[@]+"${lockfiles[@]}"}; do
        if [[ ! -f "${lockfile}" ]] || ! root=$(cd "$(dirname "${lockfile}")" && pwd); then
            continue
        fi
        # The workspace's own packages are listed already, and cargo pkgid
        # takes a while, so it only looks up the others.
        members=()
        while IFS= read -r spec; do
            if [[ -n "${spec}" ]]; then
                members[${spec}]=1
            fi
        done < <(cargo metadata --no-deps --format-version 1 --manifest-path "${root}/Cargo.toml" 2> /dev/null \
            | jq -r '.packages[]? | "\(.name)@\(.version)"' 2> /dev/null)
        # Packages without a source are path packages; [[patch.unused]]
        # entries are not packages.
        while IFS= read -r spec; do
            if [[ -n "${members[${spec}]:-}" ]] \
                || ! id=$(cargo pkgid --offline --manifest-path "${root}/Cargo.toml" "${spec}" 2> /dev/null) \
                || ! rs_match "${id}" '^(path\+)?file://(/[^#]*)'; then
                continue
            fi
            encoded=${BASH_REMATCH[2]}
            dir=""
            while rs_match "${encoded}" '^([^%]*)%([0-9A-Fa-f]{2})(.*)$'; do
                printf -v byte '%b' "\\x${BASH_REMATCH[2]}"
                dir+=${BASH_REMATCH[1]}${byte}
                encoded=${BASH_REMATCH[3]}
            done
            dir+=${encoded}
            if [[ -z "${known[${dir%/}/Cargo.toml]:-}" ]]; then
                known[${dir%/}/Cargo.toml]=1
                RS_INPUTS+=("manifest:${dir%/}/Cargo.toml")
            fi
        done < <(awk '
            function flush() {
                if (package && name != "" && source == "") print name "@" version
                package = 0; name = version = source = ""
            }
            /^\[/ { flush(); package = ($0 ~ /^\[\[package\]\][ \t]*$/); next }
            package && /^name = "/ { name = $0; sub(/^name = "/, "", name); sub(/"[ \t]*$/, "", name) }
            package && /^version = "/ { version = $0; sub(/^version = "/, "", version); sub(/"[ \t]*$/, "", version) }
            package && /^source = / { source = "yes" }
            END { flush() }' "${lockfile}")
    done
}

# rs_license_inputs: adds to RS_INPUTS the licence files of the local
# packages (those with no source: the workspace's and path packages), which
# cargo-deny reads for a package without a licence expression, and cargo
# cyclonedx for license-file: each package directory's regular files whose
# names start with LICENSE or COPYING, as cargo-deny 0.20.2's
# find_license_files lists them, and its license-file. The packages are those
# of RS_INPUTS' metadata file, or else those whose manifests it lists. A
# registry crate's files come with the crate, which the lockfile pins.
rs_license_inputs() {
    local entry metadata="" manifest license file path
    local -A manifests=() listed=() licenses=() known=()
    local -a candidates=()
    for entry in ${RS_INPUTS[@]+"${RS_INPUTS[@]}"}; do
        case "${entry}" in
            manifest:*) manifests[${entry#manifest:}]=1 ;;
            metadata:*) metadata=${entry#metadata:} ;;
            license:*) known[${entry#license:}]=1 ;;
        esac
    done
    # Each local package's manifest and license-file, tab-separated. cargo
    # metadata gives license-file as the manifest has it, relative to the
    # package's directory.
    # shellcheck disable=SC2016 # jq program, not shell
    local filter='.packages[]? | select(.source == null) | "\(.manifest_path)\t\(.license_file // "")"'
    if [[ -n "${metadata}" ]]; then
        while IFS=$'\t' read -r manifest license; do
            licenses[${manifest}]=${license}
        done < <(jq -r "${filter}" "${metadata}" 2> /dev/null)
    elif command -v cargo > /dev/null 2>&1; then
        # One cargo metadata call lists a whole workspace, so a manifest an
        # earlier call listed needs none of its own.
        for manifest in "${!manifests[@]}"; do
            if [[ -n "${listed[${manifest}]:-}" ]]; then
                continue
            fi
            listed[${manifest}]=1
            while IFS=$'\t' read -r path license; do
                listed[${path}]=1
                if [[ -n "${manifests[${path}]:-}" ]]; then
                    licenses[${path}]=${license}
                fi
            done < <(cargo metadata --no-deps --format-version 1 --manifest-path "${manifest}" 2> /dev/null | jq -r "${filter}" 2> /dev/null)
        done
    fi
    for manifest in "${!licenses[@]}"; do
        candidates=("${manifest%/*}"/LICENSE* "${manifest%/*}"/COPYING*)
        license=${licenses[${manifest}]}
        if [[ "${license}" == /* ]]; then
            candidates+=("${license}")
        elif [[ -n "${license}" ]]; then
            candidates+=("${manifest%/*}/${license}")
        fi
        for file in "${candidates[@]}"; do
            if [[ ! -f "${file}" ]]; then
                continue
            fi
            path=$(cd "$(dirname "${file}")" && pwd)/${file##*/}
            if [[ -z "${known[${path}]:-}" ]]; then
                known[${path}]=1
                RS_INPUTS+=("license:${path}")
            fi
        done
    done
}

# rs_deny_inputs MANIFEST_PATH CONFIG_PATH [WORKSPACE_ROOT]: adds the files
# cargo-deny reads to RS_INPUTS, found the way cargo-deny 0.20.2 finds them:
# the config from CONFIG_PATH, or else the first deny.toml, .deny.toml or
# .cargo/deny.toml in the manifest's directory or above it; whatever the
# config, the first deny.exceptions.toml, .deny.exceptions.toml or
# .cargo/deny.exceptions.toml there, whose licence exceptions it adds; and
# the workspace's Cargo.lock. That is the one in WORKSPACE_ROOT, from cargo
# metadata, since a member's own lockfile doesn't count in a workspace;
# without it, the nearest Cargo.lock. Sets RS_DENY_CONFIG to the config, or
# empty when there is none.
rs_deny_inputs() {
    local dir name lockfile="" exceptions=""
    RS_DENY_CONFIG=$2
    if [[ -n "${RS_DENY_CONFIG}" ]]; then
        RS_INPUTS+=("config:${RS_DENY_CONFIG}")
    fi
    if [[ -n "${3:-}" ]]; then
        # Even before it exists: cargo can write it during the run, and the
        # run record hashes inputs when it is written.
        lockfile="$3/Cargo.lock"
        RS_INPUTS+=("lockfile:${lockfile}")
    fi
    dir=$(cd "$(dirname "${1:-./Cargo.toml}")" 2> /dev/null && pwd) || dir=""
    while [[ -n "${dir}" && ( -z "${RS_DENY_CONFIG}" || -z "${exceptions}" || -z "${lockfile}" ) ]]; do
        for name in deny.toml .deny.toml .cargo/deny.toml; do
            if [[ -z "${RS_DENY_CONFIG}" && -f "${dir}/${name}" ]]; then
                RS_DENY_CONFIG="${dir}/${name}"
                RS_INPUTS+=("config:${RS_DENY_CONFIG}")
            fi
        done
        for name in deny.exceptions.toml .deny.exceptions.toml .cargo/deny.exceptions.toml; do
            if [[ -z "${exceptions}" && -f "${dir}/${name}" ]]; then
                exceptions="${dir}/${name}"
                RS_INPUTS+=("config:${exceptions}")
            fi
        done
        if [[ -z "${lockfile}" && -f "${dir}/Cargo.lock" ]]; then
            lockfile="${dir}/Cargo.lock"
            RS_INPUTS+=("lockfile:${lockfile}")
        fi
        if [[ "${dir}" == / ]]; then
            break
        fi
        dir=$(dirname "${dir}")
    done
}

# rs_deny_record_inputs MANIFEST_PATH CONFIG_PATH METADATA_PATH: adds what a
# cargo-deny run reads to RS_INPUTS, for its run record: the config and the
# lockfile (rs_deny_inputs), and the METADATA_PATH file, or else the
# manifests, which cargo-deny reads through cargo metadata. Either names the
# workspace root, whose Cargo.lock is the workspace's.
rs_deny_record_inputs() {
    local metadata="" root=""
    if [[ -n "$3" ]]; then
        root=$(jq -r '.workspace_root // empty' < "$3" 2> /dev/null) || root=""
    elif command -v cargo > /dev/null 2>&1; then
        metadata=$(cargo metadata --no-deps --format-version 1 ${1:+--manifest-path "$1"} 2> /dev/null) || metadata=""
        root=$(jq -r '.workspace_root // empty' <<< "${metadata}" 2> /dev/null) || root=""
    fi
    rs_deny_inputs "$1" "$2" "${root}"
    if [[ -n "$3" ]]; then
        RS_INPUTS+=("metadata:$3")
    elif [[ -n "${metadata}" ]]; then
        rs_manifest_inputs "${metadata}"
    fi
}

# rs_expand_path VALUE: expands a path from deny.toml's db-path the way
# cargo-deny 0.20 does: a leading ~ to HOME, then $NAME, ${NAME} and
# ${NAME:-default}, with CARGO_HOME defaulting to $HOME/.cargo. Returns 1, as
# cargo-deny fails, for an unset variable without a default or a malformed
# reference.
rs_expand_path() {
    local in=$1 out="" name value has_default default
    # shellcheck disable=SC2016 # regular expressions, not shell
    local braced='^\$\{([A-Za-z0-9_]*)(:-([^}]*))?\}(.*)$' plain='^\$([A-Za-z0-9_]*)(.*)$'
    if [[ "${in}" == "~"* ]]; then
        out=${HOME:-}
        in=${in:1}
    fi
    while [[ "${in}" == *'$'* ]]; do
        out+=${in%%\$*}
        in="\$${in#*\$}"
        if rs_match "${in}" "${braced}"; then
            name=${BASH_REMATCH[1]}
            has_default=${BASH_REMATCH[2]:+yes}
            default=${BASH_REMATCH[3]}
            in=${BASH_REMATCH[4]}
        elif rs_match "${in}" "${plain}"; then
            name=${BASH_REMATCH[1]}
            has_default=""
            in=${BASH_REMATCH[2]}
        else
            return 1
        fi
        if [[ "${name}" == CARGO_HOME ]]; then
            value=${CARGO_HOME:-${HOME:-}/.cargo}
        elif rs_match "${name}" '^[A-Za-z_][A-Za-z0-9_]*$' && [[ -n "${!name+set}" ]]; then
            value=${!name}
        elif [[ -n "${has_default}" ]]; then
            value=${default}
        else
            return 1
        fi
        out+=${value}
    done
    printf '%s\n' "${out}${in}"
}

# Awk functions for the TOML readers below, which set q to a single quote.
# They read keys by their full dotted name, so a setting means the same
# whether written under its [table] header or as table.key, as in TOML. A
# quoted key part keeps its dots, so "a.b" = 1 is one key, never the dotted
# a.b, and toml_key, finding no plain name, skips it.
# - toml_table(line): the dotted name of the table a [header] line opens,
#   "[]" for an array of tables, or "\" for a name written with escapes.
# - toml_key(line): the dotted key a key = value line sets, relative to its
#   table, "" when the text before = isn't a key (such as inside an array),
#   or "\" for a quoted key written with escapes. Only a TOML parser would
#   read an escaped name exactly, so the readers fail closed on "\".
# - toml_rest(line): the value, the text after =.
# - toml_plain(value): whether value is not a multiline string, nor a basic
#   string with escapes, which only a TOML parser would read exactly.
# - toml_string(value): the string value starts with, or else value without
#   its comment.
RS_TOML_AWK='
    function toml_name(key,    name, i, c, quote) {
        # Whitespace around a key part goes, quotes go, and a dot inside
        # quotes stays part of its key part, as \001, so "a.b" never reads
        # as the dotted a.b.
        name = ""
        quote = ""
        for (i = 1; i <= length(key); i++) {
            c = substr(key, i, 1)
            if (quote != "") {
                if (c == quote) {
                    quote = ""
                } else {
                    name = name (c == "." ? "\001" : c)
                }
            } else if (c == "\"" || c == q) {
                quote = c
            } else if (c !~ /[[:space:]]/) {
                name = name c
            }
        }
        return name
    }
    function toml_table(line) {
        sub(/#.*/, "", line)
        if (line ~ /^[[:space:]]*\[\[/) { return "[]" }
        sub(/^[[:space:]]*\[/, "", line)
        sub(/\][[:space:]]*$/, "", line)
        return index(line, "\\") ? "\\" : toml_name(line)
    }
    function toml_key(line,    key, plain) {
        key = substr(line, 1, index(line, "=") - 1)
        plain = key
        gsub(/\\./, "", plain)
        if (toml_name(plain) !~ /^[A-Za-z0-9_.-]+$/) { return "" }
        return index(key, "\\") ? "\\" : toml_name(key)
    }
    function toml_rest(line) {
        line = substr(line, index(line, "=") + 1)
        sub(/^[[:space:]]*/, "", line)
        return line
    }
    function toml_plain(value) {
        return !(substr(value, 1, 3) == "\"\"\"" || substr(value, 1, 3) == q q q || (substr(value, 1, 1) == "\"" && index(value, "\\")))
    }
    function toml_string(value,    quote) {
        quote = substr(value, 1, 1)
        if (quote == "\"" || quote == q) {
            value = substr(value, 2)
            return substr(value, 1, index(value, quote) - 1)
        }
        sub(/[[:space:]]*(#.*)?$/, "", value)
        return value
    }
'

# rs_deny_db: sets RS_DB, for the run record, to the advisory database
# cargo-deny reads: in the advisories.db-path of RS_DENY_CONFIG, or else
# $CARGO_HOME/advisory-dbs, the directory cargo-deny names after the URL in
# advisories.db-urls, or after RustSec's when there is none (rs_db_name),
# whether fetch_advisory_db staged it or cargo-deny cloned it. Empty when it
# can't tell, such as for a relative db-path, one that cargo-deny couldn't
# expand either, a URL rs_db_name can't name, several databases (a run
# record names one), or settings written in a form the reader can't take
# exactly.
rs_deny_db() {
    local settings db_path="" url name=""
    local -a urls=()
    RS_DB=""
    if [[ -n "${RS_DENY_CONFIG:-}" && -f "${RS_DENY_CONFIG}" ]]; then
        # Prints "urls" and "url=<url>" for each URL in advisories.db-urls,
        # an array that can span lines, "path=<path>" for advisories.db-path,
        # and "unreadable" for an inline advisories table, a setting written
        # as a multiline string or with escapes, or a name written with
        # escapes. Keys count by their full dotted name, as for
        # rs_audit_config.
        settings=$(awk -v q="'" "${RS_TOML_AWK}"'
            function urls(line) {
                sub(/#.*/, "", line)
                while (match(line, "\"[^\"]*\"|" q "[^" q "]*" q)) {
                    if (!toml_plain(substr(line, RSTART, RLENGTH))) { print "unreadable" }
                    print "url=" substr(line, RSTART + 1, RLENGTH - 2)
                    line = substr(line, RSTART + RLENGTH)
                }
                if (index(line, "]")) { in_urls = 0 }
            }
            in_urls { urls($0); next }
            /^[[:space:]]*\[/ { table = toml_table($0); next }
            index($0, "=") {
                key = toml_key($0)
                if (key == "") { next }
                if (key == "\\" || table == "\\") {
                    print "unreadable"
                    next
                }
                key = table == "" ? key : table "." key
                rest = toml_rest($0)
                if (key == "advisories.db-urls") {
                    print "urls"
                    in_urls = 1
                    urls(rest)
                } else if (key == "advisories.db-path") {
                    quote = substr(rest, 1, 1)
                    if (toml_plain(rest) && (quote == "\"" || quote == q)) {
                        print "path=" toml_string(rest)
                    } else {
                        print "unreadable"
                    }
                } else if (key == "advisories") {
                    print "unreadable"
                }
            }' "${RS_DENY_CONFIG}")
        if grep -qx unreadable <<< "${settings}"; then
            return 0
        fi
        mapfile -t urls < <(sed -n 's/^url=//p' <<< "${settings}")
        db_path=$(sed -n 's/^path=//p' <<< "${settings}" | head -n 1)
    fi
    if [[ -z "${db_path}" ]]; then
        db_path="${CARGO_HOME:-${HOME:-}/.cargo}/advisory-dbs"
    elif ! db_path=$(rs_expand_path "${db_path}"); then
        return 0
    fi
    # cargo-deny opens a relative db-path from the directory it runs in,
    # which is this one, not the config's.
    if [[ "${db_path}" != /* ]]; then
        db_path="$(pwd)/${db_path}"
    fi
    db_path=${db_path%/}
    # cargo-deny reads RustSec's database when db-urls is unset or empty,
    # and each URL's (duplicates once) otherwise.
    if [[ ${#urls[@]} -eq 0 ]]; then
        urls=(https://github.com/RustSec/advisory-db)
    fi
    for url in "${urls[@]}"; do
        if ! rs_db_name "${url}" || [[ -n "${name}" && "${RS_DB_NAME}" != "${name}" ]]; then
            return 0
        fi
        name=${RS_DB_NAME}
    done
    if [[ -d "${db_path}/${name}" ]]; then
        RS_DB="${db_path}/${name}"
    fi
}

# rs_xxh64 SEED STRING: prints the XXH64 hash of the ASCII STRING, as 16 hex
# digits. Bash arithmetic is 64-bit and wraps like the unsigned arithmetic
# XXH64 uses; only right shifts need masking, since bash's are arithmetic.
rs_xxh64() {
    local seed=$1 s=$2 len=${#2} i=0 v1 v2 v3 v4 h k
    local -a b=()
    local p1=$((0x9E3779B185EBCA87)) p2=$((0xC2B2AE3D27D4EB4F)) p3=$((0x165667B19E3779F9))
    local p4=$((0x85EBCA77C2B2AE63)) p5=$((0x27D4EB2F165667C5))
    for ((i = 0; i < len; i++)); do
        printf -v k '%d' "'${s:i:1}"
        b+=("${k}")
    done
    rotl() { echo $((($1 << $2) | (($1 >> (64 - $2)) & ((1 << $2) - 1)))); }
    u64() { local j v=0; for ((j = 7; j >= 0; j--)); do v=$(((v << 8) | b[$1 + j])); done; echo "${v}"; }
    u32() { local j v=0; for ((j = 3; j >= 0; j--)); do v=$(((v << 8) | b[$1 + j])); done; echo "${v}"; }
    xround() { local acc=$(($1 + $2 * p2)); acc=$(rotl "${acc}" 31); echo $((acc * p1)); }
    merge() { local val; val=$(xround 0 "$2"); echo $(((($1 ^ val) * p1) + p4)); }
    i=0
    if ((len >= 32)); then
        v1=$((seed + p1 + p2))
        v2=$((seed + p2))
        v3=${seed}
        v4=$((seed - p1))
        while ((i + 32 <= len)); do
            v1=$(xround "${v1}" "$(u64 "${i}")")
            v2=$(xround "${v2}" "$(u64 $((i + 8)))")
            v3=$(xround "${v3}" "$(u64 $((i + 16)))")
            v4=$(xround "${v4}" "$(u64 $((i + 24)))")
            i=$((i + 32))
        done
        h=$(($(rotl "${v1}" 1) + $(rotl "${v2}" 7) + $(rotl "${v3}" 12) + $(rotl "${v4}" 18)))
        h=$(merge "${h}" "${v1}")
        h=$(merge "${h}" "${v2}")
        h=$(merge "${h}" "${v3}")
        h=$(merge "${h}" "${v4}")
    else
        h=$((seed + p5))
    fi
    h=$((h + len))
    while ((i + 8 <= len)); do
        k=$(xround 0 "$(u64 "${i}")")
        h=$(($(rotl $((h ^ k)) 27) * p1 + p4))
        i=$((i + 8))
    done
    if ((i + 4 <= len)); then
        h=$(($(rotl $((h ^ ($(u32 "${i}") * p1))) 23) * p2 + p3))
        i=$((i + 4))
    fi
    while ((i < len)); do
        h=$(($(rotl $((h ^ (b[i] * p5))) 11) * p1))
        i=$((i + 1))
    done
    h=$(((h ^ ((h >> 33) & ((1 << 31) - 1))) * p2))
    h=$(((h ^ ((h >> 29) & ((1 << 35) - 1))) * p3))
    h=$((h ^ ((h >> 32) & ((1 << 32) - 1))))
    printf '%016x\n' "${h}"
}

# rs_db_name URL: sets RS_DB_NAME to the directory cargo-deny keeps the
# advisory database cloned from URL in, <last path segment>-<hash>, and
# returns 0; or sets RS_URL_ERROR to why it can't tell, and returns 1. The
# hash is rs_xxh64's, with seed 0xca80de71, of the URL as cargo-deny sees it:
# lowercased, then normalized the way the url crate does for the URLs a
# database is served from (the default port dropped, an empty path written
# as "/"). Only https: over plain http, anyone on the network path could
# serve a database with advisories left out, and see an Authorization
# header. The path is limited to characters the url crate leaves as they
# are, without . or .. segments, which it would resolve: otherwise the name
# would not be the one cargo-deny looks for.
# shellcheck disable=SC2034 # RS_URL_ERROR is read by the caller
rs_db_name() {
    local url=${1,,} scheme host port path label
    local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    RS_DB_NAME=""
    RS_URL_ERROR=""
    if ! rs_match "${url}" '^(https)://([a-z0-9.-]+)(:[0-9]+)?(/[a-z0-9._~%/+:@!$&()*,;=-]*)?$'; then
        RS_URL_ERROR="url must be an https URL with a host and a path of plain ASCII, and no user, query or fragment."
        return 1
    fi
    scheme=${BASH_REMATCH[1]}
    host=${BASH_REMATCH[2]}
    port=${BASH_REMATCH[3]}
    path=${BASH_REMATCH[4]:-/}
    if [[ "${path}/" =~ /(\.|\.\.|%2e|%2e%2e|\.%2e|%2e\.)/ ]]; then
        RS_URL_ERROR="url's path must not have . or .. segments."
        return 1
    fi
    # The url crate reads a host whose last label is a number (decimal, or
    # hex with 0x) as an IPv4 address, and writes it as four decimal
    # numbers, so 127.1 is 127.0.0.1. Only that form keeps the name.
    label=${host%.}
    label=${label##*.}
    if rs_match "${label}" '^([0-9]+|0x[0-9a-f]*)$' && ! rs_match "${host}" "^${octet}(\\.${octet}){3}\$"; then
        RS_URL_ERROR="url's host must be a name, or an IPv4 address written as four decimal numbers from 0 to 255, such as 192.0.2.10."
        return 1
    fi
    # The url crate reads the port as a number, so :0443 is https's default
    # port, which it leaves out, and :08080 is :8080.
    if [[ -n "${port}" ]]; then
        port=${port#:}
        port=${port#"${port%%[!0]*}"}
        if [[ ${#port} -gt 5 ]] || (( 10#${port:-0} > 65535 )); then
            RS_URL_ERROR="url's port must be 65535 or less."
            return 1
        fi
        port=":$((10#${port:-0}))"
    fi
    if [[ "${scheme}:${port}" == "https::443" ]]; then
        port=""
    fi
    RS_DB_NAME="${path##*/}-$(rs_xxh64 $((0xca80de71)) "${scheme}://${host}${port}${path}")"
}

# rs_url_public URL: prints URL without its userinfo, query and fragment,
# which can hold credentials (https://user:token@host/... or
# ?access_token=...).
rs_url_public() {
    local url
    url=$(sed -E 's|^([A-Za-z][A-Za-z0-9+.-]*://)[^/?#]*@|\1|' <<< "$1")
    printf '%s\n' "${url%%[?#]*}"
}

# rs_url_key URL: URL as cargo-deny names a database's directory after it:
# lowercased, without https's default port, and with an empty path written
# as "/".
rs_url_key() {
    local url=${1,,} host path port
    if [[ "${url}" != https://* ]]; then
        printf '%s\n' "${url}"
        return 0
    fi
    host=${url#https://}
    host=${host%%/*}
    path=${url#https://"${host}"}
    # The port is a number, so :0443 is :443, which is left out.
    if rs_match "${host}" ':[0-9]+$'; then
        port=${host##*:}
        host=${host%:*}
        port=${port#"${port%%[!0]*}"}
        if [[ "${port:-0}" != 443 ]]; then
            host="${host}:${port:-0}"
        fi
    fi
    printf 'https://%s%s\n' "${host}" "${path:-/}"
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
    local db config_db="" allow_stale kind value
    db=$(rs_subst "${PARAM_DB_PATH}")
    db=${db:-${RUSTSEC_ADVISORY_DB:-}}
    RS_NO_FETCH=$(rs_bool no_fetch "${PARAM_NO_FETCH}")
    allow_stale=$(rs_bool allow_stale "${PARAM_ALLOW_STALE}")
    RS_NO_YANKED=$(rs_bool no_yanked "${PARAM_NO_YANKED}")
    RS_AUDIT_OPTS=()
    RS_DENIED=()
    rs_audit_config
    if [[ -n "${db}" ]]; then
        RS_AUDIT_OPTS+=(--db "${db}")
    elif [[ -n "${RS_CONFIG_DB_PATH}" ]]; then
        # --db wins over the config's path, which cargo audit reads otherwise.
        # shellcheck disable=SC2088 # matches a literal ~/, which cargo audit expands
        case "${RS_CONFIG_DB_PATH}" in
            "~/"*) config_db="${HOME:-}/${RS_CONFIG_DB_PATH#"~/"}" ;;
            *) config_db=${RS_CONFIG_DB_PATH} ;;
        esac
    fi
    # shellcheck disable=SC2034 # read by rs_run_record
    RS_DB=${db:-${config_db:-${CARGO_HOME:-${HOME:-}/.cargo}/advisory-db}}
    if [[ "${RS_CONFIG_DB_STALE}" == true ]]; then
        allow_stale=true
    fi
    if [[ "${RS_NO_FETCH}" == true ]]; then
        RS_AUDIT_OPTS+=(--no-fetch)
        rs_db_fresh "${RS_DB}" "${allow_stale}"
    elif [[ "${RS_CONFIG_DB_FETCH}" == false ]]; then
        # cargo audit then never fetches, and checks no database's age.
        RS_NO_FETCH=true
        echo "The audit.toml cargo audit reads (${RS_AUDIT_CONFIG}) turns fetching off ([database] fetch = false)."
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
    if [[ "${RS_NO_YANKED}" == true ]]; then
        RS_AUDIT_OPTS+=(--no-yanked)
    fi
}

# rs_audit_extra_args: sets RS_EXTRA to the extra_args words, refusing the
# options that would change the report format these commands write, those
# the parameters must set because the command reads them too, and words
# cargo audit would read as a subcommand or its argument.
rs_audit_extra_args() {
    local word extra flags parameter value=false
    extra=$(rs_subst "${PARAM_EXTRA_ARGS}")
    rs_words extra_args "${extra}"
    RS_EXTRA=(${RS_WORDS[@]+"${RS_WORDS[@]}"})
    for word in ${RS_EXTRA[@]+"${RS_EXTRA[@]}"}; do
        parameter=""
        # The value of the option before it.
        if [[ "${value}" == true ]]; then
            value=false
            continue
        fi
        case "${word}" in
            --json | --format | --format=*)
                echo "ERROR: extra_args can't set ${word}: this command writes the JSON and SARIF reports itself." >&2
                exit 1
                ;;
            # The database, whether it is fetched and whether a stale one is
            # accepted decide the staleness check and the database the run
            # record names; the denied kinds decide which warnings the counts
            # and JUnit report as failures.
            --no-fetch) parameter=no_fetch ;;
            --db | --db=*) parameter=db_path ;;
            --stale) parameter=allow_stale ;;
            --deny | --deny=*) parameter=deny ;;
            --color | --file | --ignore | --target-arch | --target-os | --url) value=true ;;
            # cargo audit takes no other arguments than options: a word that
            # is neither an option nor an option's value is a subcommand
            # (bin, which audits binaries instead of the lockfile), or after
            # one, or after --, its argument.
            -- | [!-]* | -)
                echo "ERROR: extra_args can't hold ${word}: cargo audit would read it as a subcommand, such as bin, or as its argument," >&2
                echo "  and audit something other than what this command records. audit checks the lockfile, and audit_bin the binaries it names." >&2
                exit 1
                ;;
            --*) ;;
            # Short options can be grouped, as in -qn. q, h and V take no
            # value; any other option's value is the rest of the word, or
            # else the next word.
            -?*)
                flags=${word#-}
                while [[ -n "${flags}" && -z "${parameter}" ]]; do
                    case "${flags:0:1}" in
                        n) parameter=no_fetch ;;
                        d) parameter=db_path ;;
                        D) parameter=deny ;;
                        q | h | V) flags=${flags:1} ;;
                        *)
                            if [[ -z "${flags:1}" ]]; then
                                value=true
                            fi
                            flags=""
                            ;;
                    esac
                done
                ;;
        esac
        if [[ "${parameter}" == deny ]]; then
            echo "ERROR: extra_args can't set ${word}: use the deny parameter, which the counts and JUnit report follow to tell denied warnings apart." >&2
            exit 1
        elif [[ -n "${parameter}" ]]; then
            echo "ERROR: extra_args can't set ${word}: use the ${parameter} parameter, which the database's staleness check and the run record follow." >&2
            exit 1
        fi
    done
}

# rs_audit_counts JSON CODE: prints the counts of a cargo audit JSON report
# from a run that exited with CODE, with the warnings that fail the step
# counted as denied_warnings (see RS_AUDIT_DENIED_JQ).
rs_audit_counts() {
    # shellcheck disable=SC2016 # jq program, not shell
    jq -c --argjson denied "$(rs_denied_json)" --argjson config "$(rs_config_denied_json)" --argjson code "$2" "${RS_AUDIT_DENIED_JQ}"'
        rs_denied_kinds as $kinds | {
            vulnerabilities: .vulnerabilities.count,
            warnings: (.warnings | map_values(length)),
            denied_warnings: ([.warnings | to_entries[] | select(.key as $k | $kinds | index($k)) | .value | length] | add // 0),
            denied_by_config: rs_denied_by_config
        }' "$1"
}

# rs_denied_json: prints RS_DENIED as a JSON array.
# The warning kinds that fail the step, as jq functions for a cargo audit JSON
# report, given $denied (the deny parameter), $config (the [output] deny list
# of the audit.toml cargo audit reads) and $code (cargo audit's exit code).
# cargo audit's report doesn't say what it denied, and a config this can't
# read could deny more: when cargo audit exits non-zero with no
# vulnerabilities and no denied kind it reported, every warning counts as
# denied.
# shellcheck disable=SC2016 # jq program, not shell
RS_AUDIT_DENIED_JQ='
    def rs_kinds_in($list): [.warnings | keys[] | . as $k | select(($list | index("warnings")) or ($list | index($k)))];
    def rs_listed_kinds: rs_kinds_in($denied + $config);
    def rs_unexplained: rs_listed_kinds as $kinds | $code != 0 and .vulnerabilities.count == 0
        and ([.warnings | to_entries[] | select(.key as $k | $kinds | index($k)) | .value | length] | add // 0) == 0;
    def rs_denied_kinds: if rs_unexplained then [.warnings | keys[]] else rs_listed_kinds end;
    def rs_denied_by_config: rs_unexplained or (rs_kinds_in($config) | length > 0);
'

# rs_audit_check LOG JSON CODE: returns 1, saying why, when cargo audit's run
# can't be trusted although it wrote a report: it exited non-zero without
# reporting anything, or it couldn't check for yanked crates (the crates.io
# index was unreachable) when deny, or the audit.toml cargo audit reads, makes
# yanked crates fail. Only warns when the yanked check failed and nothing
# denies yanked crates.
rs_audit_check() {
    local denied
    if [[ "$3" -ne 0 ]] && rs_json_is "$2" '.vulnerabilities.count == 0 and ([.warnings[] | length] | add // 0) == 0'; then
        echo "ERROR: cargo audit exited with ${3} but reported no vulnerability or warning. Its output:" >&2
        sed 's/^/  /' "$1" | tail -n 20 >&2
        return 1
    fi
    if [[ "${RS_NO_YANKED}" != true ]] && grep -q "couldn't check if the package is yanked" "$1"; then
        denied=" $(rs_denied_json | jq -r 'join(" ")') ${RS_CONFIG_DENIED[*]-} "
        if [[ "${denied}" == *" yanked "* || "${denied}" == *" warnings "* ]]; then
            echo "ERROR: cargo audit could not check for yanked crates, which deny makes fail the step:" >&2
            grep "couldn't check if the package is yanked" "$1" | sort -u | sed 's/^/  /' >&2
            echo "  The crates.io index must be reachable, or set no_yanked to true to skip the check." >&2
            return 1
        fi
        echo "WARN: cargo audit could not check for yanked crates (is the crates.io index reachable?); set no_yanked to true to skip the check:" >&2
        grep "couldn't check if the package is yanked" "$1" | sort -u | sed 's/^/WARN:   /' >&2
    fi
}

rs_denied_json() {
    printf '%s\n' ${RS_DENIED[@]+"${RS_DENIED[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))'
}
rs_config_denied_json() {
    printf '%s\n' ${RS_CONFIG_DENIED[@]+"${RS_CONFIG_DENIED[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))'
}

# rs_audit_config: sets RS_AUDIT_CONFIG to the audit.toml cargo audit reads
# (.cargo/audit.toml in the working directory, or else $CARGO_HOME's), or
# empty, RS_CONFIG_DENIED to the warning kinds its [output] deny lists, and
# RS_CONFIG_DB_PATH, RS_CONFIG_DB_FETCH and RS_CONFIG_DB_STALE to its
# [database] path, fetch and stale settings (empty when unset).
rs_audit_config() {
    local line
    RS_AUDIT_CONFIG=""
    RS_CONFIG_DENIED=()
    RS_CONFIG_DB_PATH=""
    RS_CONFIG_DB_FETCH=""
    RS_CONFIG_DB_STALE=""
    if [[ -f .cargo/audit.toml ]]; then
        RS_AUDIT_CONFIG=.cargo/audit.toml
    elif [[ -f "${CARGO_HOME:-${HOME:-}/.cargo}/audit.toml" ]]; then
        RS_AUDIT_CONFIG="${CARGO_HOME:-${HOME:-}/.cargo}/audit.toml"
    else
        return 0
    fi
    # Prints "deny <kind>" for each kind in output.deny, an array that can
    # span lines, "<key> <value>" for database.path, fetch and stale,
    # "unreadable <key>" for one of those it can't read, "inline <table>"
    # for a database or output table written inline, and "escaped" for a key
    # or table name written with escapes. Keys count by their full dotted
    # name, so [database] fetch = false and database.fetch = false are the
    # same setting, as in TOML.
    while IFS= read -r line; do
        case "${line}" in
            "deny "*) RS_CONFIG_DENIED+=("${line#deny }") ;;
            "path "*) RS_CONFIG_DB_PATH=${line#path } ;;
            "fetch "*) RS_CONFIG_DB_FETCH=${line#fetch } ;;
            "stale "*) RS_CONFIG_DB_STALE=${line#stale } ;;
            "unreadable "*)
                echo "ERROR: ${RS_AUDIT_CONFIG} writes ${line#unreadable } as a multiline string or with escapes, which this command can't read." >&2
                echo "  Write it with plain \"...\" or '...' strings, which this command reads exactly." >&2
                exit 1
                ;;
            escaped)
                echo "ERROR: ${RS_AUDIT_CONFIG} writes a key or table name with escapes, which this command can't read." >&2
                echo "  Write names plainly, such as [database] or database.fetch, so its settings reach the staleness check and the run record." >&2
                exit 1
                ;;
            "inline "*)
                echo "ERROR: ${RS_AUDIT_CONFIG} sets ${line#inline } as an inline table, which this command can't read." >&2
                echo "  Write it as a [${line#inline }] table, so its settings reach the staleness check and the run record." >&2
                exit 1
                ;;
        esac
    done < <(awk -v q="'" "${RS_TOML_AWK}"'
        function take(line) {
            sub(/#.*/, "", line)
            buf = buf " " line
            if (buf ~ /\]/) { collecting = 0; done = 1 }
        }
        collecting { take($0); next }
        # An array of tables ("[]") holds none of these settings.
        /^[[:space:]]*\[/ { table = toml_table($0); next }
        index($0, "=") {
            key = toml_key($0)
            if (key == "") { next }
            if (key == "\\" || table == "\\") {
                print "escaped"
                next
            }
            key = table == "" ? key : table "." key
            rest = toml_rest($0)
            if (key == "output.deny" && !done) {
                collecting = 1
                take(rest)
            } else if (key ~ /^database\.(path|fetch|stale)$/) {
                if (toml_plain(rest)) {
                    print substr(key, 10) " " toml_string(rest)
                } else {
                    print "unreadable " key
                }
            } else if (key == "database" || key == "output") {
                print "inline " key
            }
        }
        END {
            # Only a TOML parser would read the kinds exactly if written
            # with escapes.
            if (index(buf, "\\")) {
                print "unreadable output.deny"
                exit
            }
            gsub(q, "\"", buf)
            while (match(buf, /"[a-z]+"/)) {
                print "deny " substr(buf, RSTART + 1, RLENGTH - 2)
                buf = substr(buf, RSTART + RLENGTH)
            }
        }' "${RS_AUDIT_CONFIG}")
}

# rs_audit_ignores_prepare MODE DIR: for unused_ignores MODE (allow, warn or
# deny, as for cargo-deny's unused-ignored-advisory), sets RS_IGNORES to the
# ignores cargo audit applies, as a JSON array of {id, source}: those in the
# audit.toml it reads (RS_AUDIT_CONFIG, advisories.ignore by its full dotted
# name, an array that can span lines and hold comments) and those --ignore in
# extra_args adds. With MODE allow it does nothing. Writes DIR/.cargo/audit.toml, a copy of that config without
# advisories.ignore, which shadows $CARGO_HOME/audit.toml for a cargo audit
# run in DIR, and sets RS_EXTRA_KEEP to extra_args without --ignore. A config
# it can't rewrite with certainty (an inline advisories table, a multiline or
# escaped string, anything but strings in the array) stops the step: an
# unused ignore must never go unreported because the check couldn't run.
rs_audit_ignores_prepare() {
    local line value=false word
    local -a ids=()
    case "$1" in
        allow) return 0 ;;
        warn | deny) ;;
        *)
            echo "ERROR: unused_ignores must be allow, warn or deny, not '$1'." >&2
            exit 1
            ;;
    esac
    mkdir -p "$2/.cargo"
    : > "$2/.cargo/audit.toml"
    RS_IGNORES="[]"
    if [[ -n "${RS_AUDIT_CONFIG}" ]]; then
        while IFS= read -r line; do
            case "${line}" in
                "id "*) ids+=("${line#id }") ;;
                "error "*)
                    echo "ERROR: unused_ignores can't read ${RS_AUDIT_CONFIG}'s advisories.ignore exactly: ${line#error }." >&2
                    echo "  Write it as a list of plain \"...\" or '...' strings under [advisories] (or as advisories.ignore), so the" >&2
                    echo "  ignores can be checked." >&2
                    exit 1
                    ;;
            esac
        done < <(awk -v q="'" -v out="$2/.cargo/audit.toml" "${RS_TOML_AWK}"'
            # scan(text): reads the ignore array from text, printing
            # "id <string>" for each string, and leaves it when a ] closes it.
            function scan(text,    c, rest, quote) {
                while (text != "") {
                    c = substr(text, 1, 1)
                    if (c ~ /[[:space:],]/) { text = substr(text, 2); continue }
                    if (c == "#") { return }
                    if (c == "]") {
                        in_ignore = 0
                        rest = substr(text, 2)
                        sub(/^[[:space:]]*(#.*)?$/, "", rest)
                        if (rest != "") { print "error text after the array closes" }
                        return
                    }
                    if (c == "\"" || c == q) {
                        if (substr(text, 1, 3) == c c c) { print "error a multiline string"; return }
                        quote = c
                        text = substr(text, 2)
                        if (!index(text, quote)) { print "error a string that does not end on its line"; return }
                        rest = substr(text, 1, index(text, quote) - 1)
                        if (quote == "\"" && index(rest, "\\")) { print "error a string with escapes"; return }
                        print "id " rest
                        text = substr(text, index(text, quote) + 1)
                        continue
                    }
                    print "error something other than a string in the array"
                    return
                }
            }
            in_ignore { scan($0); next }
            /^[[:space:]]*\[/ { table = toml_table($0); print > out; next }
            index($0, "=") {
                key = toml_key($0)
                if (key != "" && key != "\\" && table != "\\") {
                    key = table == "" ? key : table "." key
                    if (key == "advisories.ignore") {
                        rest = toml_rest($0)
                        if (substr(rest, 1, 1) != "[") { print "error a value that is not an array"; next }
                        in_ignore = 1
                        scan(substr(rest, 2))
                        next
                    }
                    if (key == "advisories") { print "error an inline advisories table"; next }
                }
            }
            { print > out }
            END { if (in_ignore) { print "error an array that never closes" } }' "${RS_AUDIT_CONFIG}")
        for value in ${ids[@]+"${ids[@]}"}; do
            RS_IGNORES=$(jq -c --arg id "${value}" --arg source "${RS_AUDIT_CONFIG}" '. + [{id: $id, source: $source}]' <<< "${RS_IGNORES}")
        done
    fi
    # --ignore ID and --ignore=ID in extra_args.
    RS_EXTRA_KEEP=()
    value=false
    for word in ${RS_EXTRA[@]+"${RS_EXTRA[@]}"}; do
        if [[ "${value}" == true ]]; then
            value=false
            RS_IGNORES=$(jq -c --arg id "${word}" '. + [{id: $id, source: "extra_args"}]' <<< "${RS_IGNORES}")
        elif [[ "${word}" == --ignore ]]; then
            value=true
        elif [[ "${word}" == --ignore=* ]]; then
            RS_IGNORES=$(jq -c --arg id "${word#--ignore=}" '. + [{id: $id, source: "extra_args"}]' <<< "${RS_IGNORES}")
        else
            RS_EXTRA_KEEP+=("${word}")
        fi
    done
    RS_IGNORE_MATCHES="[]"
}

# rs_audit_ignores_pass DIR JSON INPUT TARGET...: runs cargo audit once more
# for one input, from DIR (see rs_audit_ignores_prepare), with no ignores, no
# fetch and no yanked check (yanked findings carry no advisory ID), against
# the database the audit read, and records in RS_IGNORE_MATCHES which ignores
# matched a finding there: its advisory's ID, or only one of its aliases,
# which cargo-audit 0.22 doesn't match ignores against. TARGET is the
# lockfile (--file ABS) or binary (bin ABS) part of the arguments; JSON is
# the audit's own report, whose settings.ignore must be the ignores
# rs_audit_ignores_prepare read, or the step stops. Returns 1, saying why,
# when the pass doesn't complete.
rs_audit_ignores_pass() {
    local dir=$1 json=$2 input=$3 db=${RS_DB} applied read rc=0 kind value
    local -a args=(audit)
    shift 3
    # shellcheck disable=SC2016 # jq program, not shell
    applied=$(jq -c '[.settings.ignore[]? | tostring] | sort' "${json}")
    read=$(jq -c '[.[].id] | sort' <<< "${RS_IGNORES}")
    if [[ "${applied}" != "${read}" ]]; then
        echo "ERROR: cargo audit applied the ignores ${applied}, but unused_ignores read ${read} from" >&2
        echo "  ${RS_AUDIT_CONFIG:-no config} and extra_args, so it can't tell which are unused." >&2
        return 1
    fi
    if [[ "${db}" != /* ]]; then
        db="$(pwd)/${db}"
    fi
    args+=(--db "${db}" --no-fetch --no-yanked)
    for kind in ${RS_DENIED[@]+"${RS_DENIED[@]}"}; do
        args+=(--deny "${kind}")
    done
    rs_list target_arch "${PARAM_TARGET_ARCH}"
    for value in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
        args+=(--target-arch "${value}")
    done
    rs_list target_os "${PARAM_TARGET_OS}"
    for value in ${RS_LIST[@]+"${RS_LIST[@]}"}; do
        args+=(--target-os "${value}")
    done
    args+=(${RS_EXTRA_KEEP[@]+"${RS_EXTRA_KEEP[@]}"} --json "$@")
    echo "Auditing ${input} again without its ignores, to find the unused ones..."
    rs_show_command "${RS_TOOL##*/}" "${args[@]}"
    (cd "${dir}" && "${RS_TOOL}" "${args[@]}") > "${dir}/pass.json" 2> "${dir}/pass.log" || rc=$?
    if ! rs_json_is "${dir}/pass.json" 'type == "object" and (.vulnerabilities | type == "object")'; then
        echo "ERROR: cargo audit did not complete without the ignores (exit code ${rc}), so their use can't be told. Its output:" >&2
        sed 's/^/  /' "${dir}/pass.log" | tail -n 20 >&2
        return 1
    fi
    # shellcheck disable=SC2016 # jq program, not shell
    RS_IGNORE_MATCHES=$(jq -c --arg input "${input}" --slurpfile pass "${dir}/pass.json" '
        [$pass[0] | (.vulnerabilities.list[]?.advisory), (.warnings[]?[]?.advisory) | select(. != null)
            | {id, aliases: (.aliases // [])}] as $found
        | . + [{input: $input, ids: [$found[].id] | unique,
            aliases: [$found[] | .id as $id | .aliases[] | {alias: ., id: $id}] | unique}]' <<< "${RS_IGNORE_MATCHES}")
}

# rs_advisory_versions DB ID: prints, as JSON, what the advisory database DB
# says of the advisory ID (or one with ID among its aliases): its package,
# patched and unaffected versions, and when it was withdrawn; null when it
# has none. That is usually why an ignore stopped matching.
rs_advisory_versions() {
    local file="" dir
    local -a dirs=()
    # Advisories for crates, and for the Rust toolchain's own (rust/).
    for dir in "$1/crates" "$1/rust"; do
        if [[ -d "${dir}" ]]; then
            dirs+=("${dir}")
        fi
    done
    if [[ ${#dirs[@]} -gt 0 ]]; then
        file=$(find "${dirs[@]}" -name "$2.md" -type f | head -n 1) || file=""
        if [[ -z "${file}" ]]; then
            file=$(grep -rlF -- "\"$2\"" "${dirs[@]}" | head -n 1) || file=""
        fi
    fi
    if [[ -z "${file}" ]]; then
        echo null
        return 0
    fi
    # The advisory's front matter, a TOML block: [advisory] id, package and
    # withdrawn, and [versions] patched and unaffected, arrays that can span
    # lines.
    awk '
        /^```toml/ { front = 1; next }
        front && /^```/ { exit }
        !front { next }
        /^\[/ { table = $0; gsub(/[][[:space:]]/, "", table); key = ""; next }
        index($0, "=") && !collecting {
            key = $0; sub(/[[:space:]]*=.*/, "", key); sub(/^[[:space:]]*/, "", key)
            rest = substr($0, index($0, "=") + 1)
            if (table == "advisory" && (key == "id" || key == "package" || key == "withdrawn")) {
                if (match(rest, /"[^"]*"/)) print table "." key "\t" substr(rest, RSTART + 1, RLENGTH - 2)
                next
            }
            if (table == "versions" && (key == "patched" || key == "unaffected")) { collecting = 1; $0 = rest }
            else next
        }
        collecting {
            line = $0
            sub(/#.*/, "", line)
            while (match(line, /"[^"]*"/)) {
                print table "." key "\t" substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, RSTART + RLENGTH)
            }
            if (index(line, "]")) collecting = 0
        }' "${file}" | jq -Rsc 'split("\n") | map(select(. != "") | split("\t")) as $rows
            | {id: ([$rows[] | select(.[0] == "advisory.id") | .[1]][0]),
               package: ([$rows[] | select(.[0] == "advisory.package") | .[1]][0]),
               patched: [$rows[] | select(.[0] == "versions.patched") | .[1]],
               unaffected: [$rows[] | select(.[0] == "versions.unaffected") | .[1]],
               withdrawn: ([$rows[] | select(.[0] == "advisory.withdrawn") | .[1]][0])}'
}

# rs_audit_ignores_report MODE FILE CLASS: writes FILE, the ignores report:
# each ignore with its source, the inputs it matched a finding in, the
# advisories it names only by an alias, and, for an unused one, what the
# database now says of its advisory. An ignore is unused when it matched no
# finding in any input: one config often covers several lockfiles, and an
# ignore is legitimately unused in those without the crate. Sets
# RS_UNUSED_IGNORES to the unused IDs, as a JSON array, prints them (as
# warnings), and sets RS_IGNORE_CASES to JUnit test cases for them, of
# classname CLASS, failed with MODE deny and skipped with warn.
rs_audit_ignores_report() {
    local report entry advisory line ids=()
    # shellcheck disable=SC2016 # jq program, not shell
    report=$(jq -c --argjson matches "${RS_IGNORE_MATCHES}" 'map(. as $ignore | . + {
            matched_in: [$matches[] | select(.ids | index($ignore.id)) | .input],
            alias_of: ([$matches[].aliases[] | select(.alias == $ignore.id) | .id] | unique)}
        | . + {used: (.matched_in | length > 0)})' <<< "${RS_IGNORES}")
    mapfile -t ids < <(jq -r '.[] | select(.used | not) | .id' <<< "${report}")
    for entry in ${ids[@]+"${ids[@]}"}; do
        advisory=$(rs_advisory_versions "${RS_DB}" "${entry}")
        # shellcheck disable=SC2016 # jq program, not shell
        report=$(jq -c --arg id "${entry}" --argjson advisory "${advisory}" \
            'map(if .id == $id and (.used | not) then . + {advisory: $advisory} else . end)' <<< "${report}")
    done
    # shellcheck disable=SC2016 # jq program, not shell
    jq --arg mode "$1" --argjson inputs "$(jq -c '[.[].input]' <<< "${RS_IGNORE_MATCHES}")" '{mode: $mode, inputs: $inputs,
        ignores: map({id, source, used, matched_in, alias_of, advisory: (.advisory // null)})}' <<< "${report}" > "$2"
    # shellcheck disable=SC2034 # read by the scripts
    RS_UNUSED_IGNORES=$(jq -c '[.ignores[] | select(.used | not) | .id] | unique' "$2")
    while IFS= read -r line; do
        if [[ "$1" == deny ]]; then
            echo "  unused ignore: ${line}"
        else
            echo "WARN: unused ignore: ${line}" >&2
        fi
    done < <(jq -r '.ignores[] | select(.used | not) | "\(.id) (from \(.source)) matches no finding"
        + (if (.alias_of | length) > 0 then "; it names \(.alias_of | join(", ")) by an alias, and cargo audit matches ignores by advisory ID only" else "" end)
        + (if .advisory then "; the database'"'"'s \(.advisory.id) is for \(.advisory.package // "a crate")"
            + (if .advisory.withdrawn then ", withdrawn on \(.advisory.withdrawn)" else "" end)
            + (if (.advisory.patched | length) > 0 then ", patched in \(.advisory.patched | join(" or "))" else ", with no patched version" end)
            + (if (.advisory.unaffected | length) > 0 then ", and leaves out \(.advisory.unaffected | join(" or "))" else "" end)
          else "" end)' "$2")
    # shellcheck disable=SC2034,SC2016 # read by the scripts; jq program, not shell
    RS_IGNORE_CASES=$(jq -c --arg mode "$1" --arg class "$3" '[.ignores[] | select(.used | not) | {
            classname: $class, name: .id, status: (if $mode == "deny" then "failed" else "skipped" end),
            message: ("ignored in \(.source), but no finding matches it"
                + (if (.alias_of | length) > 0 then " (it is an alias of \(.alias_of | join(", ")))" else "" end)),
            detail: (if .advisory then (.advisory | tojson) else "" end)}]' "$2")
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

# rs_audit_cases JSON CLASSNAME CODE: prints a cargo audit JSON report's findings
# as JUnit test cases for rs_junit: vulnerabilities and denied warnings fail,
# other warnings are skipped.
rs_audit_cases() {
    # shellcheck disable=SC2016 # jq program, not shell
    jq -c --argjson denied "$(rs_denied_json)" --argjson config "$(rs_config_denied_json)" --arg class "$2" --argjson code "$3" \
        "${RS_AUDIT_DENIED_JQ}"'
        rs_denied_kinds as $kinds
        | [(.vulnerabilities.list[] | {
            classname: "\($class).vulnerability",
            name: "\(.advisory.id) \(.package.name) \(.package.version)",
            status: "failed",
            message: .advisory.title,
            detail: "\(.advisory.url // ("https://rustsec.org/advisories/" + .advisory.id))\nPatched: \((.versions.patched // []) | join(", ") | if . == "" then "none" else . end)"
        }),
        (.warnings | to_entries[] | .key as $kind | .value[] | {
            classname: "\($class).\($kind)",
            name: "\(.advisory.id // $kind) \(.package.name) \(.package.version)",
            status: (if $kinds | index($kind) then "failed" else "skipped" end),
            message: (.advisory.title // "\($kind) crate"),
            detail: (.advisory.url // "")
        })]' "$1"
}
