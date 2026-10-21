#!/usr/bin/env bash
#
# Runs a command's script the way the command's step runs it: with every
# PARAM_ variable set from the command's parameter defaults, overridden by
# NAME=VALUE arguments, and SCRIPT_RUST_SECURITY_LIB set to the shared
# helpers. test-deploy.yml uses it to check steps that must fail, since a
# failing orb step would fail the test job itself. working_dir, like the
# step's working_directory, is where the script runs.
#
# Usage, from a checkout:
#   bash tests/run_command.sh COMMAND [NAME=VALUE ...]
#
# Exits with the script's exit code.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $# -lt 1 ]]; then
    echo "ERROR: Usage: bash tests/run_command.sh COMMAND [NAME=VALUE ...]" >&2
    exit 2
fi
COMMAND=$1
shift
YML="${ROOT}/src/commands/${COMMAND}.yml"
if [[ ! -f "${YML}" ]]; then
    echo "ERROR: There is no command ${COMMAND} (${YML})." >&2
    exit 2
fi
SCRIPT=$(grep -oE '<< include\(scripts/[a-z_]+\.sh\) >>' "${YML}" | grep -v 'scripts/lib/' | sed -E 's/<< include\((.*)\) >>/\1/' | head -n 1)

# Every parameter's default, as NAME<TAB>VALUE, without the quotes YAML allows.
declare -A VALUES=()
while IFS=$'\t' read -r name value; do
    VALUES[${name}]=${value}
done < <(awk '
    /^parameters:/ { p = 1; next }
    /^[^ ]/ { p = 0 }
    p && /^  [a-z_0-9]+:$/ { name = $1; sub(/:$/, "", name) }
    p && /^    default:/ {
        value = $0
        sub(/^    default: */, "", value)
        if (value ~ /^".*"$/) { value = substr(value, 2, length(value) - 2) }
        printf "%s\t%s\n", name, value
    }' "${YML}")
for setting in "$@"; do
    name=${setting%%=*}
    if [[ "${setting}" != *=* || -z "${VALUES[${name}]+set}" ]]; then
        echo "ERROR: ${COMMAND} has no parameter ${name}." >&2
        exit 2
    fi
    VALUES[${name}]=${setting#*=}
done

ENVIRONMENT=()
while IFS= read -r line; do
    var=${line%%:*}
    name=${line##*parameters.}
    name=${name% >>}
    ENVIRONMENT+=("${var}=${VALUES[${name}]}")
done < <(grep -oE 'PARAM_[A-Z0-9_]+: << parameters\.[a-z0-9_]+ >>' "${YML}")

DIR=${VALUES[working_dir]:-.}
echo "Running ${SCRIPT} in ${DIR} with ${ENVIRONMENT[*]-}"
cd "${DIR}"
STATUS=0
env ${ENVIRONMENT[@]+"${ENVIRONMENT[@]}"} SCRIPT_RUST_SECURITY_LIB="$(cat "${ROOT}/src/scripts/lib/rust_security.sh")" \
    bash "${ROOT}/src/${SCRIPT}" || STATUS=$?
echo "${SCRIPT} exited with ${STATUS}."
exit "${STATUS}"
