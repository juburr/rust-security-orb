#!/bin/bash
#
# Fetches the RustSec advisory database (a shallow git clone of url), or
# imports a copy staged earlier (a directory or a .tar.gz), for the
# fetch_advisory_db command, so cargo audit and cargo deny read the very same
# copy.
#
# The copy goes where cargo-deny looks for it without any configuration:
# <db_dir>/<last part of url>-<hash of url>, db_dir defaulting to
# $CARGO_HOME/advisory-dbs. cargo-deny names that directory with the 64-bit
# xxHash (XXH64, seed 0xca80de71) of the lowercased URL, which rs_xxh64
# computes, and cargo audit is pointed at it through RUSTSEC_ADVISORY_DB,
# which the audit and audit_bin commands read.
#
# Both tools then judge the database's age without fetching: cargo-deny by
# .git/FETCH_HEAD's time, or else the newest commit's time or .git/HEAD's,
# whichever is later; the audit commands by the newest commit's time. So
# FETCH_HEAD is removed and .git/HEAD is given the newest commit's time, and
# both measure the same thing: how old the newest advisory is, not when this
# copy was made.

set -euo pipefail

if [[ -z "${SCRIPT_RUST_SECURITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_RUST_SECURITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_RUST_SECURITY_LIB}"

URL=$(rs_subst "${PARAM_URL}")
IMPORT=$(rs_subst "${PARAM_IMPORT}")
DB_DIR=$(rs_subst "${PARAM_DB_DIR}")
ARCHIVE=$(rs_subst "${PARAM_ARCHIVE}")
AUTH_ENV_VAR=${PARAM_AUTH_HEADER_ENV_VAR}

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

# The URL as cargo-deny sees it: lowercased, then normalized the way the url
# crate does for the URLs a database is served from (the default port
# dropped, an empty path written as "/").
CANONICAL=${URL,,}
# Only https: over plain http, anyone on the network path could serve a
# database with advisories left out, and see the Authorization header. The
# path is limited to characters the url crate leaves as they are, without .
# or .. segments, which it would resolve: otherwise its directory name would
# not be the one cargo-deny looks for.
URL_RE='^(https)://([a-z0-9.-]+)(:[0-9]+)?(/[a-z0-9._~%/+:@!$&()*,;=-]*)?$'
if ! rs_match "${CANONICAL}" "${URL_RE}"; then
    echo "ERROR: url must be an https URL with a host and a path of plain ASCII, and no user, query or fragment." >&2
    exit 1
fi
SCHEME=${BASH_REMATCH[1]}
HOST=${BASH_REMATCH[2]}
PORT=${BASH_REMATCH[3]}
URL_PATH=${BASH_REMATCH[4]:-/}
if [[ "${URL_PATH}/" =~ /(\.|\.\.|%2e|%2e%2e|\.%2e|%2e\.)/ ]]; then
    echo "ERROR: url's path must not have . or .. segments." >&2
    exit 1
fi
# The url crate reads the port as a number, so :0443 is https's default port,
# which it leaves out, and :08080 is :8080.
if [[ -n "${PORT}" ]]; then
    PORT=${PORT#:}
    PORT=${PORT#"${PORT%%[!0]*}"}
    if [[ ${#PORT} -gt 5 ]] || (( 10#${PORT:-0} > 65535 )); then
        echo "ERROR: url's port must be 65535 or less." >&2
        exit 1
    fi
    PORT=":$((10#${PORT:-0}))"
fi
if [[ "${SCHEME}:${PORT}" == "https::443" ]]; then
    PORT=""
fi
CANONICAL="${SCHEME}://${HOST}${PORT}${URL_PATH}"
NAME="${URL_PATH##*/}-$(rs_xxh64 $((0xca80de71)) "${CANONICAL}")"

# shellcheck disable=SC2088 # matches a literal ~/ the shell didn't expand
if [[ -z "${DB_DIR}" ]]; then
    if [[ -z "${CARGO_HOME:-}" && -z "${HOME:-}" ]]; then
        echo "ERROR: Neither CARGO_HOME nor HOME is set, so db_dir has no default. Set db_dir." >&2
        exit 1
    fi
    DB_DIR="${CARGO_HOME:-${HOME}/.cargo}/advisory-dbs"
elif [[ "${DB_DIR}" == "~/"* ]]; then
    DB_DIR="${HOME:?HOME is not set, so ~/ in db_dir cannot be expanded}/${DB_DIR#"~/"}"
fi
if [[ "${DB_DIR}" != /* ]]; then
    DB_DIR="$(pwd)/${DB_DIR}"
fi
DEST="${DB_DIR%/}/${NAME}"
if ! command -v git > /dev/null 2>&1; then
    echo "ERROR: git is not on the PATH. Fetching the database, and judging its age, need it." >&2
    exit 1
fi
mkdir -p "${DB_DIR}"
WORK_DIR=$(mktemp -d "${DB_DIR%/}/.${NAME}.XXXXXX")
trap 'rm -rf "${WORK_DIR}"' EXIT
STAGED="${WORK_DIR}/db"

if [[ -n "${IMPORT}" ]]; then
    if [[ -d "${IMPORT}" ]]; then
        echo "Importing the advisory database from the directory ${IMPORT}..."
        mkdir -p "${STAGED}"
        cp -a "${IMPORT%/}/." "${STAGED}/"
    elif [[ -f "${IMPORT}" ]]; then
        echo "Importing the advisory database from the archive ${IMPORT} (SHA-256 $(rs_sha256 "${IMPORT}"))..."
        mkdir -p "${STAGED}"
        if ! tar -xzf "${IMPORT}" -o -C "${STAGED}"; then
            echo "ERROR: Could not unpack ${IMPORT}. It must be a .tar.gz of the database's directory, such as fetch_advisory_db's archive writes." >&2
            exit 1
        fi
    else
        echo "ERROR: import names ${IMPORT}, which is neither a directory nor a file." >&2
        exit 1
    fi
else
    echo "Fetching the advisory database from ${URL}..."
    GIT_ENV=(env GIT_TERMINAL_PROMPT=0)
    if [[ -n "${AUTH_ENV_VAR}" ]]; then
        rs_env_var_name auth_header_env_var "${AUTH_ENV_VAR}"
        if [[ -z "${!AUTH_ENV_VAR:-}" ]]; then
            echo "ERROR: auth_header_env_var names ${AUTH_ENV_VAR}, which is empty or not set." >&2
            exit 1
        fi
        # The header reaches git through its environment, never its command
        # line, and nothing here prints it.
        GIT_ENV+=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader "GIT_CONFIG_VALUE_0=Authorization: ${!AUTH_ENV_VAR}")
    fi
    if ! "${GIT_ENV[@]}" git clone --quiet --depth 1 -- "${URL}" "${STAGED}"; then
        echo "ERROR: Could not clone ${URL}. Check the URL and the job's network access; re-run the job if the host was failing." >&2
        exit 1
    fi
fi

if [[ ! -d "${STAGED}/crates" ]]; then
    echo "ERROR: The advisory database has no crates/ directory, so it isn't a RustSec advisory database." >&2
    exit 1
fi
ADVISORIES=$(find "${STAGED}/crates" -name '*.md' -type f | wc -l)
if [[ "${ADVISORIES}" -eq 0 ]]; then
    echo "ERROR: The advisory database has no advisories in crates/." >&2
    exit 1
fi
# git -C searches parent directories, so a copy without its own .git inside
# another work tree would be dated by that repository.
if [[ ! -e "${STAGED}/.git" ]] || ! COMMIT=$(git -C "${STAGED}" log -1 --format=%H 2> /dev/null) || [[ -z "${COMMIT}" ]]; then
    echo "ERROR: The advisory database is not a git checkout, so its age can't be told. Import a copy with its .git directory," >&2
    echo "  such as the archive fetch_advisory_db writes." >&2
    exit 1
fi
# cargo-deny names a database's directory after its URL, so an imported copy
# of another repository would be read as url's database. Only an https origin
# can be compared; a local path or ssh remote says nothing about the URL.
if [[ -n "${IMPORT}" ]]; then
    ORIGIN=$(git -C "${STAGED}" remote get-url origin 2> /dev/null || true)
    ORIGIN=$(sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@#\1#' <<< "${ORIGIN}")
    ORIGIN=${ORIGIN%%[?#]*}
    if [[ "${ORIGIN,,}" == https://* && "$(rs_url_key "${ORIGIN}")" != "$(rs_url_key "${URL}")" ]]; then
        echo "ERROR: The imported database is a copy of ${ORIGIN}, not of url (${URL}), and cargo-deny would read it as url's." >&2
        echo "  Set url to ${ORIGIN} (and deny.toml's db-urls to it, if it names a database), or import a copy of ${URL}." >&2
        exit 1
    fi
fi
# cargo-audit and cargo-deny scan the files as they are, and run records name
# the commit, so the files must be exactly the commit's.
if ! CHANGES=$(git -C "${STAGED}" status --porcelain --untracked-files=all --ignored 2> /dev/null); then
    echo "ERROR: Could not compare the advisory database's files with its commit ${COMMIT}." >&2
    exit 1
fi
if [[ -n "${CHANGES}" ]]; then
    echo "ERROR: The advisory database's files differ from its commit ${COMMIT}, so a run record naming that commit" >&2
    echo "  would not describe what was scanned. Import a clean copy, such as the archive fetch_advisory_db writes. The first changes:" >&2
    sed -n '1,10s/^/  /p' <<< "${CHANGES}" >&2
    exit 1
fi
COMMITTED=$(git -C "${STAGED}" log -1 --format=%ct)
# A commit dated in the future would never look stale to either tool. A day
# covers clock skew.
if ((COMMITTED - $(date +%s) > 86400)); then
    echo "ERROR: The advisory database's newest commit is dated in the future ($(git -C "${STAGED}" log -1 --format=%cI))," >&2
    echo "  so cargo-audit and cargo-deny could never tell it is stale. Check the clock of whatever made the copy." >&2
    exit 1
fi
rm -f "${STAGED}/.git/FETCH_HEAD"
touch -d "@${COMMITTED}" "${STAGED}/.git/HEAD"

# The new copy replaces any old one in a single rename, so a reader never
# sees half of each.
if [[ -e "${DEST}" ]]; then
    mv "${DEST}" "${WORK_DIR}/old"
fi
mv "${STAGED}" "${DEST}"

echo "Advisory database ready in ${DEST}:"
echo "  commit:     ${COMMIT}"
echo "  committed:  $(git -C "${DEST}" log -1 --format=%cI) ($(( ($(date +%s) - COMMITTED) / 86400 )) days ago)"
echo "  advisories: ${ADVISORIES}"
rs_export RUSTSEC_ADVISORY_DB "${DEST}"
echo "Exported RUSTSEC_ADVISORY_DB for the audit commands; cargo deny finds it there by itself."
if [[ -n "${CARGO_HOME:-}" && "${DB_DIR%/}" != "${CARGO_HOME%/}/advisory-dbs" ]] \
    || [[ -z "${CARGO_HOME:-}" && "${DB_DIR%/}" != "${HOME:-}/.cargo/advisory-dbs" ]]; then
    echo "WARN: db_dir is not cargo-deny's default (\$CARGO_HOME/advisory-dbs), so cargo deny reads this copy only if" >&2
    echo "WARN: deny.toml sets db-path to ${DB_DIR} under [advisories]." >&2
fi

if [[ -n "${ARCHIVE}" ]]; then
    mkdir -p "$(dirname "${ARCHIVE}")"
    tar -czf "${ARCHIVE}" -C "${DEST}" .
    echo "Wrote ${ARCHIVE} (SHA-256 $(rs_sha256 "${ARCHIVE}")), to import in later jobs."
fi
