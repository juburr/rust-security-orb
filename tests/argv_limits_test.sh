#!/bin/bash
#
# Checks that nothing the orb runs can pass Linux's limit on one argument or
# environment string: MAX_ARG_STRLEN, 32 pages, 131,072 bytes. A program
# started with a longer one never runs: execve fails with E2BIG, and bash
# reports "Argument list too long" with exit code 126, which reads as a broken
# job rather than a verdict. The overall ARG_MAX (2 MiB) is not what binds.
#
#   1. Every jq --arg NAME VALUE and --argjson NAME VALUE in src/scripts has
#      a VALUE that stays small whatever the workspace: plain text, a
#      variable on the SCALARS list below (paths, names, verdicts, versions,
#      SHA strings, exit codes, counts, objects of a fixed shape), a length
#      (${#NAME...}), or a command substitution on the COMMANDS list (a
#      count, a hash, a version). A graph, a lockfile's packages, findings,
#      manifests, reports or any other list goes through a file instead:
#
#        jq --slurpfile nodes <(printf '%s' "${nodes}") '... $nodes[0] ...'
#
#      or on stdin (jq ... <<< "${nodes}"), which have no such limit.
#      Positional parameters ($1, "$@") are refused too, since the check
#      can't tell what a caller passes: give them a scalar's name first
#      (local code=$2). The value must be on the same line as the option.
#      A --slurpfile or --rawfile process substitution only prints a
#      variable: a command in it that fails reaches jq as an empty file,
#      which slurps to [] and reads as no data, where a failed $(...)
#      captured first stops the step under set -e.
#   2. Every file a command includes, whether as an environment variable
#      (SCRIPT_RUST_SECURITY_LIB: << include(scripts/lib/rust_security.sh) >>,
#      which every command passes its step) or as the command itself, stays
#      under BUDGET bytes, below the limit with room to split it before a
#      command fails at step start. The GitHub Actions pass the same files
#      as SCRIPT_* variables through actions/run_script.sh.
#
# Like the shell conventions test, this reads lines, not shell syntax: it
# catches the usual spellings, and review still applies.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
if [[ ! -f "${root}/src/@orb.yml" ]]; then
    echo "ERROR: src/@orb.yml not found in ${root}" >&2
    exit 1
fi

# Linux's MAX_ARG_STRLEN, and the budget an included file must stay under:
# 120 KiB, so a library that grows towards the limit fails here first.
LIMIT=131072
BUDGET=122880

# Variables whose values stay small whatever the workspace.
SCALARS=(
    # Paths, names and other strings a parameter or the orb sets.
    base binary input JSONL lockfile manifest MANIFEST name output path relative role slug SLUG_LIST suite url
    PARAM_REPORT_NAME RS_AUDIT_CONFIG RS_DB RS_DECODER RS_PROGRAM_NAME RS_TREE_LOCKFILE
    INVERT REACHABLE REACHABLE_FROM SUBJECT spec id value word prefix class mode command
    # Verdicts, outcomes, flags and the messages that explain them.
    verdict outcome reason IF_ABSENT REQUIRE_REASONS match present
    # Versions, hashes, times and CI identifiers.
    version RS_TOOL_VERSION sha RS_PROGRAM_SHA256 started
    CIRCLE_BUILD_URL CIRCLE_JOB CIRCLE_SHA1 GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_SHA GITHUB_JOB
    # Exit codes and numbers.
    code rc RC DEPTH package_count
    # JSON objects of a fixed shape: per-check counts, an install record, a
    # tool, the toolchain, the advisory database.
    counts install program tool_json toolchain db_json
)
# Command substitutions whose output stays small, as extended regexes
# matched against the command.
COMMANDS=(
    "^jq '[^']*length' "
    '^rs_sha256 '
    '^pwd$'
    '^date '
    '^(cargo|rustc) --version'
    '^git -C "\$\{RS_DB\}" log -1 --format='
    '^rs_(ci|denied|config_denied)_json$'
    '^rs_tool_json '
)

failures=0
fail() {
    printf 'FAIL: %s\n' "$*"
    failures=$((failures + 1))
}

declare -A SCALAR=()
for name in "${SCALARS[@]}"; do
    SCALAR[${name}]=1
done

# shell_word TEXT: sets WORD to the shell word TEXT starts with: up to a
# space, tab, ;, | or & outside quotes and substitutions. Quotes nest inside
# $(...), as they do in bash.
shell_word() {
    local text=$1 char i stack=""
    WORD=""
    for ((i = 0; i < ${#text}; i++)); do
        char=${text:i:1}
        case "${stack: -1}" in
            S)
                [[ "${char}" == "'" ]] && stack=${stack%?}
                ;;
            D)
                if [[ "${char}" == "\\" ]]; then
                    WORD+=${char}
                    i=$((i + 1))
                    char=${text:i:1}
                elif [[ "${char}" == '"' ]]; then
                    stack=${stack%?}
                elif [[ "${char}" == '$' && "${text:i+1:1}" == "(" ]]; then
                    stack+=C
                    WORD+="\$("
                    i=$((i + 1))
                    continue
                fi
                ;;
            *)
                case "${char}" in
                    ' ' | $'\t' | ';' | '|' | '&')
                        if [[ -z "${stack}" ]]; then
                            return 0
                        fi
                        ;;
                    \\)
                        WORD+=${char}
                        i=$((i + 1))
                        char=${text:i:1}
                        ;;
                    "'") stack+=S ;;
                    '"') stack+=D ;;
                    '(') stack+=P ;;
                    ')')
                        if [[ -z "${stack}" ]]; then
                            return 0
                        fi
                        stack=${stack%?}
                        ;;
                    '$')
                        if [[ "${text:i+1:1}" == "(" ]]; then
                            stack+=C
                            WORD+="\$("
                            i=$((i + 1))
                            continue
                        fi
                        ;;
                esac
                ;;
        esac
        WORD+=${char}
    done
}

# check_value WHERE OPTION VALUE: fails unless VALUE stays small.
check_value() {
    local where=$1 option=$2 value=$3 command pattern rest name ok
    if [[ "${value}" == *'`'* ]]; then
        fail "${where}: ${option} takes a backtick substitution, which this check can't read: use \$(...)"
        return 0
    fi
    if [[ "${value}" == *"\$("* ]]; then
        if [[ "${value}" =~ ^\"\$\((.*)\)\"$ ]]; then
            command=${BASH_REMATCH[1]}
            ok=false
            for pattern in "${COMMANDS[@]}"; do
                if [[ "${command}" =~ ${pattern} ]]; then
                    ok=true
                fi
            done
            if [[ "${ok}" == true ]]; then
                return 0
            fi
            fail "${where}: ${option} takes \$(${command}), whose output can grow past the 128 KiB of one argument." \
                "Pass it through a file: --slurpfile NAME <(${command})"
            return 0
        fi
        fail "${where}: ${option} takes ${value}, a command substitution inside other text, which this check can't read"
        return 0
    fi
    rest=${value}
    while [[ "${rest}" =~ \$(\{(#?)([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?!-])|([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?!-]))(.*)$ ]]; do
        rest=${BASH_REMATCH[5]}
        if [[ -n "${BASH_REMATCH[2]}" ]]; then
            # ${#NAME}, ${#NAME[@]}: a length.
            continue
        fi
        name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
        if [[ "${name}" =~ ^[0-9@*#?!-]$ ]]; then
            fail "${where}: ${option} takes \$${name}, a positional or special parameter, whose size this check can't tell." \
                "Name it first (local code=\$${name}), with a name on the SCALARS list if it is one."
        elif [[ -z "${SCALAR[${name}]:-}" ]]; then
            fail "${where}: ${option} takes \${${name}}, which is not on the SCALARS list of small values." \
                "If it can grow with the graph, the lockfile, the manifests or the reports, pass it through a file:" \
                "--slurpfile NAME <(printf '%s' \"\${${name}}\"), then \$NAME[0]. If it can't, add it to SCALARS."
        fi
    done
}

# 1. jq's --arg and --argjson.
checked=0
while IFS= read -r file; do
    lineno=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$((lineno + 1))
        # Comments, and lines without the options.
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        if [[ "${line}" =~ --(slurpfile|rawfile)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+\<\((.*)$ ]]; then
            option="--${BASH_REMATCH[1]}"
            rest=${BASH_REMATCH[2]}
            if [[ ! "${rest}" =~ ^printf\ \'%s\'\ \"\$\{[A-Za-z_][A-Za-z0-9_]*(:-[a-z]+)?\}\"\) ]]; then
                fail "${file#"${root}"/}:${lineno}: ${option} reads <(${rest%%)*}...), a command whose failure jq would read as no data." \
                    "Capture it first (value=\$(command)), then pass <(printf '%s' \"\${value}\")."
            fi
        fi
        [[ "${line}" == *--arg* ]] || continue
        rest=${line}
        while [[ "${rest}" =~ (^|[[:space:]])--(arg|argjson)([[:space:]]+|$)(.*)$ ]]; do
            option="--${BASH_REMATCH[2]}"
            rest=${BASH_REMATCH[4]}
            where="${file#"${root}"/}:${lineno}"
            if [[ ! "${rest}" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+([^[:space:]\\].*)$ ]]; then
                fail "${where}: ${option} without its name and value on the same line"
                break
            fi
            option="${option} ${BASH_REMATCH[1]}"
            shell_word "${BASH_REMATCH[2]}"
            rest=${BASH_REMATCH[2]:${#WORD}}
            check_value "${where}" "${option}" "${WORD}"
            checked=$((checked + 1))
        done
    done < "${file}"
done < <(find "${root}/src/scripts" -name '*.sh' | sort)
if [[ "${checked}" -lt 50 ]]; then
    fail "only ${checked} --arg and --argjson options were found in src/scripts, so the check is not reading them"
fi
echo "Checked ${checked} --arg and --argjson values."

# 2. Files the commands include.
declare -A INCLUDED=()
while IFS= read -r included; do
    INCLUDED[${included}]=1
done < <(grep -rhoE '<< *include\([^)]+\) *>>' "${root}/src/commands" | sed -E 's/^<< *include\(([^)]+)\) *>>$/\1/' | sort -u)
if [[ ${#INCLUDED[@]} -eq 0 ]]; then
    fail "no << include(...) >> found in src/commands"
fi
for included in "${!INCLUDED[@]}"; do
    file="${root}/src/${included}"
    if [[ ! -f "${file}" ]]; then
        fail "src/commands includes ${included}, which does not exist"
        continue
    fi
    # NAME=VALUE and its NUL: the longest name a command gives it, plus the
    # file. A command's own script counts the same, conservatively.
    size=$(($(wc -c < "${file}") + 64))
    if [[ "${size}" -gt "${BUDGET}" ]]; then
        fail "src/${included} is $(wc -c < "${file}") bytes. A command passes it to its step in one environment variable or" \
            "command, which Linux caps at ${LIMIT} bytes (exit 126 at step start); this check stops at ${BUDGET}." \
            "Split it, as scripts/lib/cargo_tree.sh is split from scripts/lib/rust_security.sh."
    fi
done
largest=$(for included in "${!INCLUDED[@]}"; do printf '%s %s\n' "$(wc -c < "${root}/src/${included}" 2> /dev/null || echo 0)" "${included}"; done | sort -n | tail -n 1)
echo "Largest included file: src/${largest#* } (${largest%% *} of ${BUDGET} bytes allowed, ${LIMIT} the limit)."

if [[ "${failures}" -gt 0 ]]; then
    echo "ERROR: ${failures} check(s) failed." >&2
    exit 1
fi
echo "ok: no argument or environment string can pass ${LIMIT} bytes"
