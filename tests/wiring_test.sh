#!/usr/bin/env bash
#
# Checks how the command YAML and the scripts fit together, offline:
#
#   - every PARAM_ variable a script reads is set by each command that runs
#     it, from the parameter of the same name, and every parameter a command
#     declares is passed on to its script (or used in its steps);
#   - every script that reads a SCRIPT_<NAME>_LIB (or _PY) variable gets it,
#     from scripts/lib/<name>.sh (or .py);
#   - every reporting command stores output_dir as artifacts under
#     rust-security-reports/ with when: always, and stores JUnit results
#     only when junit is true;
#   - the install command offers every tool there is an install_<tool>
#     command for, with that command's default version;
#   - the README documents every command, and names each install_<tool>.
#
# Run from a checkout:
#   bash tests/wiring_test.sh

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT}"
FAILURES=0
fail() {
    printf 'FAIL: %s\n' "$*"
    FAILURES=$((FAILURES + 1))
}

# param_vars SCRIPT: the PARAM_ variables SCRIPT reads. The install helpers
# are the same in every tool's script, so only the ones a tool calls count:
# download_base_url is read by the four that download GitHub releases.
param_vars() {
    local body
    body=$(sed '/^# >>> rust-security-orb install helpers >>>$/,/^# <<< rust-security-orb install helpers <<<$/d' "$1")
    grep -oE '\$\{PARAM_[A-Z0-9_]+' <<< "${body}" | sed 's/^\${//'
    if grep -qE '^ +rs_install_(prebuilt|tar_xz)\b' <<< "${body}"; then
        echo PARAM_DOWNLOAD_BASE_URL
    fi
}

# params FILE: the parameters a command declares.
params() {
    awk '/^parameters:/ { p = 1; next } /^[^ ]/ { p = 0 } p && /^  [a-z_0-9]+:$/ { sub(/:$/, ""); print $1 }' "$1"
}

for yml in src/commands/*.yml; do
    command=${yml##*/}
    command=${command%.yml}
    mapfile -t declared < <(params "${yml}")
    mapfile -t scripts < <(grep -oE '<< include\((scripts|install)/[^)]+\.sh\) >>' "${yml}" | sed -E 's/<< include\(([^)]+)\) >>/\1/' \
        | grep -v '^scripts/lib/' | sort -u)
    passed=$(grep -oE 'PARAM_[A-Z0-9_]+: << parameters\.[a-z0-9_]+ >>' "${yml}" || true)
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        var=${line%%:*}
        name=${line##*parameters.}
        name=${name% >>}
        if [[ "${var}" != "PARAM_${name^^}" ]]; then
            fail "${command}: ${var} is set from parameters.${name}"
        fi
    done <<< "${passed}"
    for script in ${scripts[@]+"${scripts[@]}"}; do
        mapfile -t read_vars < <(param_vars "src/${script}" | sort -u)
        for var in ${read_vars[@]+"${read_vars[@]}"}; do
            if ! grep -qE "^ +${var}: << parameters\.[a-z0-9_]+ >>$" "${yml}"; then
                fail "${command}: src/${script} reads ${var}, which ${command}.yml doesn't set"
            fi
        done
        # Parameters a script reads indirectly, as PARAM_${level^^}.
        # shellcheck disable=SC2016 # matched literally
        if grep -q 'var="PARAM_${level^^}"' "src/${script}"; then
            for level in allow warn deny; do
                grep -qE "^ +PARAM_${level^^}: << parameters\.${level} >>$" "${yml}" \
                    || fail "${command}: src/${script} reads PARAM_${level^^}, which ${command}.yml doesn't set"
            done
        fi
        while IFS= read -r var; do
            [[ -z "${var}" ]] && continue
            name=${var#SCRIPT_}
            case "${name}" in
                *_LIB) file="scripts/lib/${name%_LIB}.sh" ;;
                *_PY) file="scripts/lib/${name%_PY}.py" ;;
                *) continue ;;
            esac
            file=${file,,}
            if ! grep -qF "${var}: << include(${file}) >>" "${yml}"; then
                fail "${command}: src/${script} needs ${var}, which ${command}.yml doesn't pass from ${file}"
            fi
        done < <(grep -oE '\$\{SCRIPT_[A-Z0-9_]+' "src/${script}" | sed 's/^\${//' | sort -u)
    done
    for name in ${declared[@]+"${declared[@]}"}; do
        if ! grep -qE "<< parameters\.${name} >>" "${yml}"; then
            fail "${command}: the parameter ${name} is never used"
        fi
    done
    if grep -q 'parameters.output_dir' "${yml}"; then
        if ! grep -qE '^ +destination: rust-security-reports$' "${yml}" || ! grep -qE '^ +path: << parameters\.output_dir >>$' "${yml}"; then
            fail "${command}: doesn't store output_dir as artifacts under rust-security-reports/"
        fi
        if [[ "$(grep -c 'when: always' "${yml}")" -lt "$(grep -cE '^ +- store_(artifacts|test_results):' "${yml}")" ]]; then
            fail "${command}: a store step doesn't run when the step fails (when: always)"
        fi
    fi
    if grep -q 'store_test_results' "${yml}" && ! grep -q 'condition: << parameters.junit >>' "${yml}"; then
        fail "${command}: stores test results whatever junit says"
    fi
    if [[ "${command}" == install_* ]]; then
        if ! grep -q "\`${command}\`" README.md 2> /dev/null; then
            fail "${command}: the README doesn't name it"
        fi
    elif ! grep -q "### \`rust-security/${command}\`" README.md 2> /dev/null; then
        fail "${command}: the README has no section for it"
    fi
done

# The install command and the per-tool install commands.
for yml in src/commands/install_*.yml; do
    tool=${yml##*/install_}
    tool=${tool%.yml}
    default=$(awk '/^  version:/ { p = 1 } p && /^    default:/ { gsub(/"/, "", $2); print $2; exit }' "${yml}")
    install_default=$(awk -v name="  ${tool}_version:" '$0 == name { p = 1 } p && /^    default:/ { gsub(/"/, "", $2); print $2; exit }' src/commands/install.yml)
    if [[ "${default}" != "${install_default}" ]]; then
        fail "install offers ${tool//_/-} ${install_default:-nothing}, but install_${tool} defaults to ${default}"
    fi
    if ! grep -q -- "- install_${tool}:" src/commands/install.yml; then
        fail "install never runs install_${tool}"
    fi
    if ! grep -qE "^KNOWN=.*\b${tool//_/-}\b" src/scripts/install_tools.sh; then
        fail "install_tools.sh doesn't know ${tool//_/-}"
    fi
    if ! grep -q "pattern: \"\^(\.\*\[ ,\])?${tool//_/-}(\[ ,\]\.\*)?\\$\"" src/commands/install.yml; then
        fail "install doesn't pick install_${tool} with the pattern for ${tool//_/-}"
    fi
done

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "ok: every command passes every parameter its scripts read, uses every parameter it declares, and stores its reports"
