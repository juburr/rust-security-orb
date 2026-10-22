#!/usr/bin/env bash
#
# Tests the command scripts offline, against stand-ins for cargo-audit,
# cargo-deny, cargo-vet, cargo-cyclonedx, rust-audit-info, auditable2cdx,
# cargo, rustc and the CircleCI CLI, which record how they were run and
# answer with the scenario each test picks: findings, none, a failure.
# git is real, except that "git clone" copies a local repository.
#
# What the real tools print is checked by test-deploy.yml, which runs every
# command against a fixture workspace.
#
# Run from a checkout:
#   bash tests/commands_test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS="${ROOT}/src/scripts"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
CALLS="${WORK}/calls"
mkdir -p "${STUBS}" "${CALLS}"
REAL_GIT=$(command -v git)
export REAL_GIT CALLS

FAILURES=0
OUTPUT=""
RC=0
CASE=""

begin() {
    echo "--- $1"
}
check() {
    local name=$1
    shift
    if "$@"; then
        echo "  ok: ${name}"
    else
        echo "  FAIL: ${name}"
        tail -n 25 <<< "${OUTPUT}" | while IFS= read -r line; do printf '    | %s\n' "${line}"; done
        FAILURES=$((FAILURES + 1))
    fi
}
succeeded() { [[ "${RC}" -eq 0 ]]; }
failed() { [[ "${RC}" -ne 0 ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
not_said() { ! said "$1"; }
# called TOOL ARGS...: TOOL was run with exactly ARGS (one call, as recorded).
called() {
    local tool=$1 file
    shift
    for file in "${CALLS}/${tool}".*; do
        [[ -f "${file}" ]] || continue
        if [[ "$(cat "${file}")" == "$(printf '%s\n' "$@")" ]]; then
            return 0
        fi
    done
    OUTPUT+=$'\n'"calls of ${tool}:"$'\n'"$(for f in "${CALLS}/${tool}".*; do [[ -f "${f}" ]] && tr '\n' ' ' < "${f}" && echo; done)"
    return 1
}
# called_with TOOL WORD...: some call of TOOL had every WORD among its arguments.
called_with() {
    local tool=$1 file word ok
    shift
    for file in "${CALLS}/${tool}".*; do
        [[ -f "${file}" ]] || continue
        ok=true
        for word in "$@"; do
            grep -qxF -- "${word}" "${file}" || ok=false
        done
        if [[ "${ok}" == true ]]; then
            return 0
        fi
    done
    OUTPUT+=$'\n'"calls of ${tool}:"$'\n'"$(for f in "${CALLS}/${tool}".*; do [[ -f "${f}" ]] && tr '\n' ' ' < "${f}" && echo; done)"
    return 1
}
# not_called_with TOOL WORD...: no call of TOOL had every WORD (OUTPUT is
# left as it was, without the calls called_with appends).
not_called_with() {
    local saved=${OUTPUT}
    if called_with "$@"; then
        return 1
    fi
    OUTPUT=${saved}
}
call_count() { [[ "$(find "${CALLS}" -name "$1.*" | wc -l)" -eq "$2" ]]; }
file_has() { grep -qF -- "$2" "$1"; }
not_file_has() { ! grep -qF -- "$2" "$1"; }
json_is() { [[ "$(jq -r "$2" "$1" 2> /dev/null)" == "$3" ]] || { OUTPUT+=$'\n'"$1: $2 is $(jq -c "$2" "$1" 2>&1)"; return 1; }; }
exists() { [[ -e "$1" ]]; }
absent() { [[ ! -e "$1" ]]; }

# Stand-ins. Each records its arguments, one per line, to CALLS/<tool>.<n>.
record() {
    cat << 'EOF'
n=$(find "${CALLS}" -name "${0##*/}.*" | wc -l)
printf '%s\n' "$@" > "${CALLS}/${0##*/}.$((n + 1))"
EOF
}

cat > "${STUBS}/circleci" << 'EOF'
#!/usr/bin/env bash
# Like `circleci env subst`: expands $NAME and ${NAME} on stdin.
input=$(cat)
output=""
re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
while [[ "${input}" =~ ${re} ]]; do
    name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    output+="${BASH_REMATCH[1]}${!name-}"
    input=${BASH_REMATCH[5]}
done
printf '%s\n' "${output}${input}"
EOF

# cargo-audit: STUB_AUDIT is clean, vuln, warn (an unmaintained crate; exits 1
# when --deny names it), warn-config (the same, denied by .cargo/audit.toml),
# crash, nodata (bin: no dependency information), empty (a lockfile with no
# packages), exit1 (exits 1, reporting nothing), yanked-unchecked (the
# crates.io index was unreachable) or vuln-warn (a vulnerability and an
# unmaintained crate).
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
if [[ "$1" == --version ]]; then echo "cargo-audit 0.22.2"; exit 0; fi
mode=${STUB_AUDIT:-clean}
args=" $* "
if [[ "${mode}" == crash ]]; then echo "error: couldn't load the advisory database" >&2; exit 1; fi
if [[ "${mode}" == nodata && "${args}" == *" bin "* ]]; then
    echo "error: parse error: No dependency information found! Is this a Rust executable built with cargo?" >&2; exit 2
fi
vulns='{"found":false,"count":0,"list":[]}'
warnings='{}'
rc=0
if [[ "${mode}" == vuln-warn ]]; then
    warnings='{"unmaintained":[{"kind":"unmaintained","package":{"name":"ansi_term","version":"0.12.1"},"advisory":{"id":"RUSTSEC-2021-0139","title":"ansi_term is unmaintained"}}]}'
    mode=vuln
fi
if [[ "${mode}" == vuln ]]; then
    vulns='{"found":true,"count":1,"list":[{"advisory":{"id":"RUSTSEC-2021-0003","package":"smallvec","title":"Buffer overflow <in> SmallVec & co","url":"https://example.test/252"},"versions":{"patched":[">=1.6.1"]},"package":{"name":"smallvec","version":"1.6.0"}}]}'
    rc=1
elif [[ "${mode}" == warn || "${mode}" == warn-config ]]; then
    warnings='{"unmaintained":[{"kind":"unmaintained","package":{"name":"ansi_term","version":"0.12.1"},"advisory":{"id":"RUSTSEC-2021-0139","title":"ansi_term is unmaintained"}}]}'
    if [[ "${mode}" == warn-config || "${args}" == *" --deny unmaintained "* || "${args}" == *" --deny warnings "* ]]; then rc=1; fi
elif [[ "${mode}" == exit1 ]]; then
    rc=1
elif [[ "${mode}" == yanked-unchecked && "${args}" != *" --no-yanked "* ]]; then
    echo "error: couldn't check if the package is yanked: not found: No such crate in crates.io index: smallvec" >&2
fi
if [[ "${args}" == *" --format sarif "* && "${args}" != *" --json "* ]]; then
    if [[ "${STUB_SARIF:-}" == crash ]]; then echo "thread 'main' panicked at src/sarif.rs" >&2; exit 101; fi
    echo '{"$schema":"https://json.schemastore.org/sarif-2.1.0.json","version":"2.1.0","runs":[{"tool":{"driver":{"name":"cargo-audit"}},"results":[]}]}'
    exit "${rc}"
fi
count=4
[[ "${mode}" == empty ]] && count=0
printf '{"database":{"advisory-count":3,"last-commit":null,"last-updated":null},"lockfile":{"dependency-count":%s},"vulnerabilities":%s,"warnings":%s}\n' \
    "${count}" "${vulns}" "${warnings}"
exit "${rc}"
EOF
} > "${STUBS}/cargo-audit"

# cargo-deny: STUB_DENY is clean, vuln, banned, crash, ignored-bare,
# ignored-reason, warn or nolabel (a warning about no crate or advisory).
# "list" prints an inventory.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
if [[ "$1" == --version ]]; then echo "cargo-deny 0.20.2"; exit 0; fi
mode=${STUB_DENY:-clean}
args=" $* "
format=human
prev=""
for a in "$@"; do [[ "${prev}" == --format ]] && format=${a}; prev=${a}; done
if [[ "${args}" == *" list "* ]]; then
    if [[ "${mode}" == crash ]]; then echo "error: list failed" >&2; exit 3; fi
    case "${format}:${args}" in
        json:*" --layout license "*) echo '{"licenses":[["Apache-2.0",["smallvec 1.6.0 registry+https://github.com/rust-lang/crates.io-index"]],["MIT",["app 0.1.0 path+file:///app","smallvec 1.6.0 registry+https://github.com/rust-lang/crates.io-index"]]],"unlicensed":[]}' ;;
        json:*) echo '{"smallvec 1.6.0 registry+https://github.com/rust-lang/crates.io-index":{"licenses":["MIT","Apache-2.0"]},"app 0.1.0 path+file:///app":{"licenses":["MIT"]}}' ;;
        tsv:*) printf 'crate\tApache-2.0\tMIT\nsmallvec@1.6.0\tX\tX\napp@0.1.0\t\tX\n' ;;
    esac
    exit 0
fi
if [[ "${mode}" == crash ]]; then
    echo '{"type":"log","fields":{"level":"ERROR","message":"failed to validate configuration file deny.toml"}}' >&2
    exit 1
fi
if [[ "${format}" == sarif ]]; then
    if [[ "${STUB_SARIF:-}" == crash ]]; then echo "thread 'main' panicked at src/sarif.rs" >&2; exit 101; fi
    echo '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"cargo-deny"}},"results":[]}]}'
    exit 0
fi
zero='{"errors":0,"warnings":0,"notes":0,"helps":0}'
adv=${zero} bans=${zero} rc=0
case "${mode}" in
    vuln)
        echo '{"type":"diagnostic","fields":{"severity":"error","code":"vulnerability","message":"Buffer overflow","notes":["ID: RUSTSEC-2021-0003"],"labels":[],"graphs":[{"Krate":{"name":"smallvec","version":"1.6.0"}}],"advisory":{"id":"RUSTSEC-2021-0003"}}}' >&2
        adv='{"errors":1,"warnings":0,"notes":0,"helps":0}'; rc=1 ;;
    banned)
        echo '{"type":"diagnostic","fields":{"severity":"error","code":"banned","message":"crate is explicitly banned","labels":[],"graphs":[{"Krate":{"name":"backend-b","version":"0.1.0"}}]}}' >&2
        bans='{"errors":1,"warnings":0,"notes":0,"helps":0}'; rc=2 ;;
    warn)
        echo '{"type":"diagnostic","fields":{"severity":"warning","code":"unmaintained","message":"ansi_term is unmaintained","labels":[],"graphs":[{"Krate":{"name":"ansi_term","version":"0.12.1"}}],"advisory":{"id":"RUSTSEC-2021-0139"}}}' >&2
        adv='{"errors":0,"warnings":1,"notes":0,"helps":0}' ;;
    ignored-bare)
        echo '{"type":"diagnostic","fields":{"severity":"note","code":"advisory-ignored","message":"advisory was not encountered","labels":[{"message":"advisory ignored here","span":"RUSTSEC-2021-0003"}]}}' >&2 ;;
    nolabel)
        echo '{"type":"diagnostic","fields":{"severity":"warning","code":"license-not-encountered","message":"license was not encountered","labels":[]}}' >&2
        ;;
    ignored-reason)
        echo '{"type":"diagnostic","fields":{"severity":"note","code":"advisory-ignored","message":"advisory was not encountered","labels":[{"message":"advisory ignored here","span":"RUSTSEC-2021-0003"},{"message":"ignore reason","span":"never called"}]}}' >&2 ;;
esac
printf '{"type":"summary","fields":{"advisories":%s,"bans":%s,"licenses":%s,"sources":%s}}\n' "${adv}" "${bans}" "${zero}" "${zero}" >&2
if [[ "${args}" == *" --audit-compatible-output "* ]]; then echo '{"vulnerabilities":[]}'; fi
exit "${rc}"
EOF
} > "${STUBS}/cargo-deny"

# cargo-vet: STUB_VET is success, fail, error or badarg (exits 2 before it
# writes a report). It needs CARGO, as the real
# one does when run outside cargo.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
if [[ "$1" == --version ]]; then echo "cargo-vet 0.10.2"; exit 0; fi
[[ -n "${CARGO:-}" ]] || { echo "thread 'main' panicked: Cargo failed to set \$CARGO, how?" >&2; exit 101; }
out=""
prev=""
for a in "$@"; do [[ "${prev}" == --output-file ]] && out=${a}; prev=${a}; done
case "${STUB_VET:-success}" in
    success) echo '{"conclusion":"success","vetted_fully":[],"vetted_partially":[],"vetted_with_exemptions":[{"name":"smallvec","version":"1.6.0"}]}' > "${out}"; exit 0 ;;
    fail) echo '{"conclusion":"fail (vetting)","failures":[{"name":"smallvec","version":"1.6.0","missing_criteria":["safe-to-deploy"]}],"suggest":null}' > "${out}"; exit 255 ;;
    badarg) echo "error: unexpected argument '--bogus' found" >&2; exit 2 ;;
    error) echo '{"error":{"message":"You must run '"'"'cargo vet init'"'"' (store not found at supply-chain)","severity":"error","causes":[]}}' > "${out}"; exit 255 ;;
esac
EOF
} > "${STUBS}/cargo-vet"

# cargo-cyclonedx writes an SBOM beside every member's Cargo.toml (members
# from STUB_MEMBERS, relative to the working directory); STUB_CDX=crash fails,
# STUB_CDX=busy also writes other JSON and XML files meanwhile, STUB_CDX=bad
# writes an SBOM that isn't one, and STUB_CDX=none writes nothing.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
if [[ "$2" == --version ]]; then echo "cargo-cyclonedx-cyclonedx 0.5.9"; exit 0; fi
if [[ "${STUB_CDX:-}" == crash ]]; then echo "Error: cargo metadata failed" >&2; exit 1; fi
if [[ "${STUB_CDX:-}" == none ]]; then exit 0; fi
format=xml
prev=""
for a in "$@"; do [[ "${prev}" == --format ]] && format=${a}; prev=${a}; done
for member in ${STUB_MEMBERS:-.}; do
    name=$(basename "$(cd "${member}" && pwd)")
    # STUB_CDX=busy: another process writes project files meanwhile.
    if [[ "${STUB_CDX:-}" == busy ]]; then echo '{"name":"web"}' > "${member}/package.json"; echo '<x/>' > "${member}/pom.xml"; fi
    if [[ "${STUB_CDX:-}" == bad ]]; then
        echo '{"name":"not an sbom"}' > "${member}/${name}.cdx.${format}"
    elif [[ "${format}" == json ]]; then
        printf '{"bomFormat":"CycloneDX","specVersion":"1.5","components":[{"name":"dep"}],"target":"%s","offline":"%s"}\n' \
            "${CARGO_BUILD_TARGET:-unset}" "${CARGO_NET_OFFLINE:-unset}" > "${member}/${name}.cdx.json"
    else
        echo '<bom/>' > "${member}/${name}.cdx.xml"
    fi
done
EOF
} > "${STUBS}/cargo-cyclonedx"

# rust-audit-info reads a file that holds "AUDITABLE"; any other file has no data.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
if [[ $# -eq 0 ]]; then echo "Usage: rust-audit-info FILE [INPUT_SIZE_LIMIT] [OUTPUT_SIZE_LIMIT]" >&2; exit 1; fi
if grep -q AUDITABLE "$1" 2> /dev/null; then
    printf '{"packages":[{"name":"app","version":"0.1.0","source":"local","dependencies":[1],"root":true},{"name":"smallvec","version":"1.6.0","source":"crates.io"}],"format":1}'
    exit 0
fi
echo "No audit data found in the binary! Was it built with 'cargo auditable'?" >&2
exit 1
EOF
} > "${STUBS}/rust-audit-info"

{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
if [[ "${STUB_A2C:-}" == crash ]]; then echo "Error: invalid dependency list" >&2; exit 2; fi
printf '{"bomFormat":"CycloneDX","specVersion":"1.3","metadata":{"component":{"name":"app"}},"components":[{"name":"smallvec"}]}'
EOF
} > "${STUBS}/auditable2cdx"

{
    echo '#!/usr/bin/env bash'
    echo 'echo "cargo-auditable stand-in: should be invoked through Cargo"; exit 1'
} > "${STUBS}/cargo-auditable"

# cargo: --version, metadata (STUB_LOCK=stale fails --locked; the workspace
# root is the working directory, the members STUB_MEMBERS, and the workspace's
# and root package's metadata tables STUB_WORKSPACE_METADATA and
# STUB_PACKAGE_METADATA), locate-project and auditable.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
case "$1" in
    --version) echo "cargo 1.99.0 (stand-in)"; exit 0 ;;
    auditable) [[ "${STUB_BUILD:-}" == fail ]] && { echo "error: could not compile" >&2; exit 101; }; echo "built"; exit 0 ;;
    metadata)
        if [[ " $* " == *" --locked "* && "${STUB_LOCK:-}" == stale ]]; then
            echo "error: the lock file Cargo.lock needs to be updated but --locked was passed to prevent this" >&2; exit 101
        fi
        root=$(pwd)
        packages=""
        members=""
        for member in ${STUB_MEMBERS:-.}; do
            dir=$(cd "${member}" && pwd)
            id="path+file://${dir}#$(basename "${dir}")@0.1.0"
            metadata=null
            [[ "${dir}" == "${root}" ]] && metadata=${STUB_PACKAGE_METADATA:-null}
            packages+="${packages:+,}{\"id\":\"${id}\",\"manifest_path\":\"${dir}/Cargo.toml\",\"metadata\":${metadata}}"
            members+="${members:+,}\"${id}\""
        done
        printf '{"workspace_root":"%s","workspace_members":[%s],"packages":[%s],"metadata":%s}\n' \
            "${root}" "${members}" "${packages}" "${STUB_WORKSPACE_METADATA:-null}"
        exit 0 ;;
    locate-project)
        manifest="$(pwd)/Cargo.toml"
        [[ "$2 $3 $4" == "--message-format plain --manifest-path" ]] && manifest=$(cd "$(dirname "$5")" && pwd)/${5##*/}
        echo "${manifest}"
        exit 0 ;;
esac
echo "cargo stand-in: unexpected $*" >&2
exit 2
EOF
} > "${STUBS}/cargo"

printf '#!/usr/bin/env bash\necho "rustc 1.99.0 (stand-in)"\n' > "${STUBS}/rustc"

# git: "clone" copies the repository FAKE_REMOTE (whatever the URL), recording
# its arguments and whether an Authorization header came through the
# environment; everything else is the real git.
{
    echo '#!/usr/bin/env bash'
    cat << 'EOF'
if [[ "$1" == clone ]]; then
    n=$(find "${CALLS}" -name "git-clone.*" | wc -l)
    { printf '%s\n' "$@"; printf 'header=%s\n' "${GIT_CONFIG_VALUE_0:-}"; } > "${CALLS}/git-clone.$((n + 1))"
    [[ -n "${FAKE_CLONE_FAIL:-}" ]] && { echo "fatal: repository not found" >&2; exit 128; }
    exec "${REAL_GIT}" clone --quiet "${FAKE_REMOTE}" "${@: -1}"
fi
exec "${REAL_GIT}" "$@"
EOF
} > "${STUBS}/git"
chmod +x "${STUBS}"/*
# Install records like the ones the install command writes, so the commands
# take the stand-ins for verified tools.
for stub in "${STUBS}"/*; do
    printf '{"tool":"%s","version":"0","arch":"amd64","method":"prebuilt","asset":"a","asset_sha512":"","verify_checksums":"false","binary_sha512":"%s"}\n' \
        "${stub##*/}" "$(sha512sum "${stub}" | awk '{ print $1 }')" > "${STUBS}/.${stub##*/}.install.json"
done

SCRIPT_RUST_SECURITY_LIB=$(cat "${SCRIPTS}/lib/rust_security.sh")
export SCRIPT_RUST_SECURITY_LIB

# new_case: a fresh HOME, working directory, output_dir and record of calls.
new_case() {
    CASE=$(mktemp -d "${WORK}/case.XXXXXX")
    mkdir -p "${CASE}/home" "${CASE}/work"
    : > "${CASE}/bash_env"
    rm -f "${CALLS}"/*
}

# run SCRIPT [VAR=value ...]: runs SCRIPT in CASE/work with DEFAULTS, the
# given settings overriding them, and sets RC and OUTPUT.
run() {
    local script=$1 settings=()
    shift
    # Bash 4.0 calls an empty "$@" unbound under set -u, even as ${@+"$@"}.
    if [[ $# -gt 0 ]]; then
        settings=("$@")
    fi
    OUTPUT=$(cd "${CASE}/work" && env -u CARGO_HOME -u RUSTSEC_ADVISORY_DB -u CARGO_BUILD_TARGET \
        PATH="${STUBS}:${PATH}" HOME="${CASE}/home" BASH_ENV="${CASE}/bash_env" \
        "${DEFAULTS[@]}" ${settings[@]+"${settings[@]}"} bash "${SCRIPTS}/${script}" 2>&1)
    RC=$?
}

# set_default NAME=VALUE: replaces NAME's entry in DEFAULTS.
set_default() {
    local i
    for i in "${!DEFAULTS[@]}"; do
        if [[ "${DEFAULTS[i]}" == "${1%%=*}="* ]]; then
            DEFAULTS[i]=$1
            return 0
        fi
    done
    DEFAULTS+=("$1")
}

# path_without TOOL...: a PATH with every stand-in but TOOL, and no real
# Rust tools.
path_without() {
    local dir file
    dir=$(mktemp -d "${WORK}/path.XXXXXX")
    for file in "${STUBS}"/*; do
        if [[ " $* " != *" ${file##*/} "* ]]; then
            ln -s "${file}" "${dir}/${file##*/}"
        fi
    done
    printf '%s:/usr/bin:/bin' "${dir}"
}

# A local advisory database: a git repository with one advisory, committed
# DAYS_AGO days ago (default 1).
make_db() {
    local dir=$1 days=${2:-1} when
    mkdir -p "${dir}/crates/smallvec"
    echo "# RUSTSEC-2021-0003" > "${dir}/crates/smallvec/RUSTSEC-2021-0003.md"
    when=$(($(date +%s) - days * 86400))
    (cd "${dir}" && "${REAL_GIT}" init -q && "${REAL_GIT}" add . \
        && GIT_COMMITTER_DATE="@${when}" GIT_AUTHOR_DATE="@${when}" \
            "${REAL_GIT}" -c user.name=t -c user.email=t@example.test commit -q -m db)
}

# --- fetch_advisory_db
REMOTE="${WORK}/remote-db"
make_db "${REMOTE}" 3
export FAKE_REMOTE="${REMOTE}"
DEFAULTS=(PARAM_URL=https://github.com/RustSec/advisory-db PARAM_IMPORT= PARAM_DB_DIR= PARAM_ARCHIVE=
    PARAM_AUTH_HEADER_ENV_VAR=)
DB_NAME=advisory-db-3157b0e258782691

begin "fetch_advisory_db: names the directory as cargo-deny does"
# rs_xxh64 against the reference XXH64 test vectors.
XXH=$(sed -n '/^rs_xxh64() {$/,/^}$/p' "${SCRIPTS}/fetch_advisory_db.sh")
for vector in ":0:ef46db3751d8e999" "a:0:d24ec4f1a98c6e5b" "abc:0:44bc2cf5ad770999" \
    "Nobody inspects the spammish repetition:0:fbcea83c8a378bf1"; do
    input=${vector%%:*}
    rest=${vector#*:}
    OUTPUT=$(bash -c "${XXH}"$'\n''rs_xxh64 "$1" "$2"' _ "${rest%%:*}" "${input}" 2>&1)
    check "XXH64(\"${input}\") is ${rest#*:}" test "${OUTPUT}" = "${rest#*:}"
done
for spec in "https://github.com/RustSec/advisory-db:${DB_NAME}" \
    "https://github.com/rustsec/advisory-db.git:advisory-db.git-ec6cac7151e04d4b" \
    "https://github.com/rustsec/advisory-db/:-a4901529771e07b1" \
    "HTTPS://GitHub.com:443/RustSec/advisory-db:${DB_NAME}"; do
    new_case
    run fetch_advisory_db.sh "PARAM_URL=${spec%:*}"
    check "${spec%:*} goes in ${spec##*:}" exists "${CASE}/home/.cargo/advisory-dbs/${spec##*:}/crates"
done

begin "fetch_advisory_db: fetching"
new_case
run fetch_advisory_db.sh
DEST="${CASE}/home/.cargo/advisory-dbs/${DB_NAME}"
check "succeeds" succeeded
check "clones the URL, shallow" called_with git-clone clone --quiet --depth 1 -- https://github.com/RustSec/advisory-db
check "into \$HOME/.cargo/advisory-dbs, where cargo-deny looks" exists "${DEST}/crates/smallvec/RUSTSEC-2021-0003.md"
check "exports RUSTSEC_ADVISORY_DB for the audit commands" file_has "${CASE}/bash_env" "export RUSTSEC_ADVISORY_DB=$(printf '%q' "${DEST}")"
check "says how old it is" said "(3 days ago)"
check "gives .git/HEAD the newest commit's time" test "$(stat -c %Y "${DEST}/.git/HEAD")" = "$(git -C "${DEST}" log -1 --format=%ct)"
check "leaves no FETCH_HEAD" absent "${DEST}/.git/FETCH_HEAD"
check "leaves nothing else in advisory-dbs" test "$(ls -A "${CASE}/home/.cargo/advisory-dbs")" = "${DB_NAME}"
run fetch_advisory_db.sh
check "fetching again replaces the copy" succeeded
check "and still leaves nothing else" test "$(ls -A "${CASE}/home/.cargo/advisory-dbs")" = "${DB_NAME}"
new_case
run fetch_advisory_db.sh "CARGO_HOME=${CASE}/cargo"
check "uses CARGO_HOME when it is set" exists "${CASE}/cargo/advisory-dbs/${DB_NAME}/crates"
new_case
run fetch_advisory_db.sh "PARAM_DB_DIR=${CASE}/elsewhere"
check "puts it in db_dir" exists "${CASE}/elsewhere/${DB_NAME}/crates"
check "warning that cargo deny reads it only through db-path" said "deny.toml sets db-path"
new_case
run fetch_advisory_db.sh FAKE_CLONE_FAIL=1
check "a failed clone fails" failed
check "saying so" said "ERROR: Could not clone https://github.com/RustSec/advisory-db"
for url in "git@github.com:rustsec/advisory-db" "https://github.com/rustsec/advisory-db?x=1" "https://user@github.com/rustsec/advisory-db" \
    "ftp://example.test/db" "http://mirror.example.test/advisory-db" "https://mirror.example.test/café" \
    "https://mirror.example.test/x/../advisory-db" "https://mirror.example.test/./advisory-db"; do
    new_case
    run fetch_advisory_db.sh "PARAM_URL=${url}"
    check "refuses the url ${url}" failed
    check "before cloning" call_count git-clone 0
done

begin "fetch_advisory_db: a private mirror's Authorization header"
new_case
run fetch_advisory_db.sh PARAM_AUTH_HEADER_ENV_VAR=MIRROR_AUTH "MIRROR_AUTH=Bearer s3cret-value"
check "succeeds" succeeded
check "reaches git through its environment" called_with git-clone "header=Authorization: Bearer s3cret-value"
check "not its arguments" not_called_with git-clone "Authorization: Bearer s3cret-value"
check "and is never printed" not_said "s3cret-value"
new_case
run fetch_advisory_db.sh PARAM_AUTH_HEADER_ENV_VAR=MIRROR_AUTH
check "an unset variable fails" failed
check "saying so" said "names MIRROR_AUTH, which is empty or not set"
new_case
run fetch_advisory_db.sh "PARAM_AUTH_HEADER_ENV_VAR=not a name"
check "a name that can't be a variable fails" failed

begin "fetch_advisory_db: archive and import"
new_case
run fetch_advisory_db.sh "PARAM_ARCHIVE=${CASE}/out/advisory-db.tar.gz"
check "writes the archive" exists "${CASE}/out/advisory-db.tar.gz"
ARCHIVE="${CASE}/out/advisory-db.tar.gz"
new_case
run fetch_advisory_db.sh "PARAM_IMPORT=${ARCHIVE}"
DEST="${CASE}/home/.cargo/advisory-dbs/${DB_NAME}"
check "imports the archive" succeeded
check "without cloning" call_count git-clone 0
check "into the same directory" exists "${DEST}/crates/smallvec/RUSTSEC-2021-0003.md"
check "with its history" test "$(git -C "${DEST}" log -1 --format=%H)" = "$(git -C "${REMOTE}" log -1 --format=%H)"
check "and the newest commit's time on .git/HEAD" test "$(stat -c %Y "${DEST}/.git/HEAD")" = "$(git -C "${REMOTE}" log -1 --format=%ct)"
new_case
cp -a "${REMOTE}" "${CASE}/staged"
touch "${CASE}/staged/.git/FETCH_HEAD"
run fetch_advisory_db.sh "PARAM_IMPORT=${CASE}/staged"
check "imports a directory" exists "${CASE}/home/.cargo/advisory-dbs/${DB_NAME}/crates"
check "dropping its FETCH_HEAD, which cargo-deny would date it by" absent "${CASE}/home/.cargo/advisory-dbs/${DB_NAME}/.git/FETCH_HEAD"
new_case
mkdir -p "${CASE}/plain/crates/x"
echo "# RUSTSEC-0000-0000" > "${CASE}/plain/crates/x/RUSTSEC-0000-0000.md"
run fetch_advisory_db.sh "PARAM_IMPORT=${CASE}/plain"
check "refuses a copy without git history, whose age can't be told" failed
check "saying so" said "is not a git checkout"
check "leaving nothing behind" absent "${CASE}/home/.cargo/advisory-dbs/${DB_NAME}"
make_db "${CASE}/future" -30
run fetch_advisory_db.sh "PARAM_IMPORT=${CASE}/future"
check "refuses a database dated in the future, which would never look stale" failed
check "saying so" said "newest commit is dated in the future"
make_db "${CASE}/repo" 1
run fetch_advisory_db.sh "PARAM_IMPORT=${CASE}/plain" "PARAM_DB_DIR=${CASE}/repo/dbs"
check "even into a db_dir inside another repository" failed
check "saying so" said "is not a git checkout"
new_case
mkdir -p "${CASE}/empty"
"${REAL_GIT}" -C "${CASE}/empty" init -q
run fetch_advisory_db.sh "PARAM_IMPORT=${CASE}/empty"
check "refuses a repository with no crates/ directory" failed
check "saying it isn't an advisory database" said "has no crates/ directory"
new_case
run fetch_advisory_db.sh "PARAM_IMPORT=${CASE}/missing"
check "refuses an import that doesn't exist" failed
new_case
echo "not an archive" > "${CASE}/bad.tar.gz"
run fetch_advisory_db.sh "PARAM_IMPORT=${CASE}/bad.tar.gz"
check "refuses a file that isn't a .tar.gz" failed
check "saying so" said "Could not unpack"

# --- audit
DEFAULTS=(PARAM_LOCKFILE=Cargo.lock PARAM_DB_PATH= PARAM_NO_FETCH=false PARAM_ALLOW_STALE=false PARAM_NO_YANKED=false
    PARAM_DENY= PARAM_TARGET_ARCH= PARAM_TARGET_OS= PARAM_EXTRA_ARGS= PARAM_OUTPUT_DIR=/will/be/set
    PARAM_REPORT_NAME=cargo-audit PARAM_SARIF=1 PARAM_JUNIT=0 PARAM_REPORT_ONLY=0 PARAM_RUN_RECORD=0)
audit_case() {
    new_case
    echo "# lockfile" > "${CASE}/work/Cargo.lock"
    set_default "PARAM_OUTPUT_DIR=${CASE}/out"
}

begin "audit: a clean lockfile"
audit_case
run audit.sh
check "succeeds" succeeded
check "audits the lockfile as JSON" called cargo-audit audit --file Cargo.lock --json
check "then as SARIF, from the same database without fetching" called cargo-audit audit --file Cargo.lock --no-fetch --format sarif
check "writes the JSON report" json_is "${CASE}/out/cargo-audit.json" '.vulnerabilities.count' 0
check "writes the SARIF report" json_is "${CASE}/out/cargo-audit.sarif" '.version' 2.1.0
check "says it passed" said "Passed: cargo audit found 0 vulnerabilities and 0 denied warnings in Cargo.lock."
check "writes no JUnit unless asked" absent "${CASE}/out/junit"
check "writes no run record unless asked" absent "${CASE}/out/cargo-audit.run-record.json"
audit_case
run audit.sh PARAM_SARIF=0
check "sarif false runs cargo audit once" call_count cargo-audit 2
check "and writes no SARIF" absent "${CASE}/out/cargo-audit.sarif"

begin "audit: vulnerabilities"
audit_case
run audit.sh STUB_AUDIT=vuln PARAM_JUNIT=1 PARAM_RUN_RECORD=1
check "fail the step" failed
check "with the count" said "ERROR: cargo audit found 1 vulnerabilities and 0 denied warnings in Cargo.lock."
check "list the advisory" said "vulnerability  RUSTSEC-2021-0003  smallvec 1.6.0"
check "and still write the reports" exists "${CASE}/out/cargo-audit.sarif"
check "JUnit has a failed case for it" file_has "${CASE}/out/junit/cargo-audit.xml" 'failures="1"'
check "named by advisory and crate" file_has "${CASE}/out/junit/cargo-audit.xml" 'name="RUSTSEC-2021-0003 smallvec 1.6.0"'
check "with the title escaped for XML" file_has "${CASE}/out/junit/cargo-audit.xml" 'message="Buffer overflow &lt;in&gt; SmallVec &amp; co"'
check "the run record says findings" json_is "${CASE}/out/cargo-audit.run-record.json" .outcome findings
check "with cargo audit's exit code" json_is "${CASE}/out/cargo-audit.run-record.json" .exit_code 1
check "and the counts" json_is "${CASE}/out/cargo-audit.run-record.json" .counts.vulnerabilities 1
audit_case
run audit.sh STUB_AUDIT=vuln PARAM_REPORT_ONLY=1 PARAM_RUN_RECORD=1
check "report_only passes" succeeded
check "with a warning" said "WARN: cargo audit found 1 vulnerabilities"
check "the run record says findings-reported" json_is "${CASE}/out/cargo-audit.run-record.json" .outcome findings-reported

begin "audit: warnings"
audit_case
run audit.sh STUB_AUDIT=warn PARAM_JUNIT=1
check "pass when deny doesn't name them" succeeded
check "listed" said "unmaintained  RUSTSEC-2021-0139  ansi_term 0.12.1"
check "as skipped JUnit cases" file_has "${CASE}/out/junit/cargo-audit.xml" 'skipped="1"'
audit_case
run audit.sh STUB_AUDIT=warn PARAM_JUNIT=1 "PARAM_DENY=unmaintained, unsound"
check "fail when deny names them" failed
check "passing each kind to --deny" called_with cargo-audit --deny unmaintained --deny unsound
check "counted as denied warnings" said "and 1 denied warnings"
check "as failed JUnit cases" file_has "${CASE}/out/junit/cargo-audit.xml" 'failures="1"'
audit_case
run audit.sh STUB_AUDIT=warn PARAM_DENY=warnings
check "deny warnings covers every kind" failed
audit_case
run audit.sh PARAM_DENY=notice
check "deny refuses a kind cargo audit can't deny" failed
check "saying which it takes" said "deny takes warnings, unmaintained, unsound and yanked"
check "before running cargo audit" call_count cargo-audit 0

audit_case
run audit.sh STUB_AUDIT=warn-config PARAM_JUNIT=1 PARAM_RUN_RECORD=1
check "warnings .cargo/audit.toml denies fail" failed
check "counted as denied" said "ERROR: cargo audit found 0 vulnerabilities and 1 denied warnings in Cargo.lock."
check "saying cargo audit's config denied them" said "the deny list in .cargo/audit.toml"
check "as failed JUnit cases" file_has "${CASE}/out/junit/cargo-audit.xml" 'failures="1"'
check "and in the run record" json_is "${CASE}/out/cargo-audit.run-record.json" .counts.denied_warnings 1

audit_case
mkdir -p "${CASE}/work/.cargo"
printf '[output]\ndeny = [\n  "unmaintained", # reviewed: these fail\n]\n' > "${CASE}/work/.cargo/audit.toml"
run audit.sh STUB_AUDIT=vuln-warn PARAM_JUNIT=1 PARAM_RUN_RECORD=1
check "with a vulnerability too, warnings .cargo/audit.toml denies still count as denied" said "1 vulnerabilities and 1 denied warnings"
check "and fail in JUnit" file_has "${CASE}/out/junit/cargo-audit.xml" 'failures="2"'
check "the run record names the config" json_is "${CASE}/out/cargo-audit.run-record.json" '.inputs[] | select(.role == "config") | .path' "${CASE}/work/.cargo/audit.toml"
audit_case
run audit.sh STUB_AUDIT=vuln-warn PARAM_JUNIT=1
check "without a config denying them, they are only reported" said "1 vulnerabilities and 0 denied warnings"
check "as skipped JUnit cases" file_has "${CASE}/out/junit/cargo-audit.xml" 'skipped="1"'

begin "audit: a cargo audit that doesn't complete"
audit_case
run audit.sh STUB_AUDIT=crash PARAM_REPORT_ONLY=1 PARAM_RUN_RECORD=1
check "fails the step even with report_only" failed
check "saying it didn't complete" said "ERROR: cargo audit did not complete (exit code 1)"
check "with cargo audit's own error" said "couldn't load the advisory database"
check "the run record says error" json_is "${CASE}/out/cargo-audit.run-record.json" .outcome error
audit_case
run audit.sh STUB_AUDIT=empty PARAM_REPORT_ONLY=1 PARAM_RUN_RECORD=1
check "a lockfile with no packages fails even with report_only" failed
check "saying it is not a Cargo.lock" said "ERROR: cargo audit found no packages in Cargo.lock, so it is not a Cargo.lock"
check "the run record says error" json_is "${CASE}/out/cargo-audit.run-record.json" .outcome error
audit_case
run audit.sh STUB_AUDIT=exit1 PARAM_REPORT_ONLY=1 PARAM_RUN_RECORD=1
check "a non-zero exit with nothing reported fails even with report_only" failed
check "saying so" said "ERROR: cargo audit exited with 1 but reported no vulnerability or warning."
check "the run record says error" json_is "${CASE}/out/cargo-audit.run-record.json" .outcome error
audit_case
run audit.sh STUB_SARIF=crash PARAM_REPORT_ONLY=1 PARAM_RUN_RECORD=1
check "a SARIF pass that fails fails the step even with report_only" failed
check "saying so, with its output" said "thread 'main' panicked at src/sarif.rs"
check "the run record says error" json_is "${CASE}/out/cargo-audit.run-record.json" .outcome error
check "with the SARIF pass's exit code" json_is "${CASE}/out/cargo-audit.run-record.json" .exit_code 101
check "and the report and log" json_is "${CASE}/out/cargo-audit.run-record.json" '[.reports[].path | split("/")[-1]] | join(" ")' "cargo-audit.json cargo-audit.log"
audit_case
run audit.sh STUB_AUDIT=yanked-unchecked
check "a yanked check that couldn't run passes" succeeded
check "with a warning naming the crate" said "WARN:   error: couldn't check if the package is yanked: not found: No such crate in crates.io index: smallvec"
audit_case
run audit.sh STUB_AUDIT=yanked-unchecked PARAM_DENY=yanked PARAM_REPORT_ONLY=1
check "but fails, even with report_only, when deny covers yanked crates" failed
check "saying why" said "ERROR: cargo audit could not check for yanked crates, which deny makes fail the step:"
audit_case
mkdir -p "${CASE}/work/.cargo"
printf '[output]\ndeny = ["yanked"]\n' > "${CASE}/work/.cargo/audit.toml"
run audit.sh STUB_AUDIT=yanked-unchecked
check "and when .cargo/audit.toml denies yanked crates" failed
audit_case
run audit.sh STUB_AUDIT=yanked-unchecked PARAM_NO_YANKED=1
check "no_yanked skips the check, and the warning" not_said "could not check for yanked crates"
audit_case
rm "${CASE}/work/Cargo.lock"
run audit.sh
check "a missing lockfile fails" failed
check "saying so" said "Cargo.lock does not exist"
check "before running cargo audit" call_count cargo-audit 0

begin "audit: options"
audit_case
run audit.sh "PARAM_TARGET_ARCH=x86_64 aarch64" PARAM_TARGET_OS=linux PARAM_NO_YANKED=1 PARAM_ALLOW_STALE=1 \
    'PARAM_EXTRA_ARGS=--ignore "RUSTSEC-2020-0071"'
check "passes targets, --no-yanked, --stale and extra_args" \
    called cargo-audit audit --file Cargo.lock --stale --target-arch x86_64 --target-arch aarch64 --target-os linux --no-yanked \
    --ignore RUSTSEC-2020-0071 --json
for word in --json --format=sarif; do
    audit_case
    run audit.sh "PARAM_EXTRA_ARGS=${word}"
    check "refuses ${word} in extra_args" failed
done
for word in --no-fetch -n -qn --db --db=/elsewhere -d/elsewhere -qd; do
    audit_case
    run audit.sh "PARAM_EXTRA_ARGS=${word}"
    check "refuses ${word} in extra_args, which the staleness check and run record wouldn't follow" failed
    check "naming the parameter to use" said "use the $([[ "${word}" == *d* ]] && echo db_path || echo no_fetch) parameter"
    check "before running cargo audit" call_count cargo-audit 0
done
for word in -q -cnever "--color never"; do
    audit_case
    run audit.sh "PARAM_EXTRA_ARGS=${word}"
    check "takes ${word}" succeeded
done
audit_case
# shellcheck disable=SC2016 # expanded by the script
run audit.sh 'PARAM_LOCKFILE=${LOCK_NAME}' LOCK_NAME=Cargo.lock
check "expands variables in lockfile" called_with cargo-audit --file Cargo.lock

begin "audit: the advisory database"
audit_case
run audit.sh "RUSTSEC_ADVISORY_DB=${CASE}/db"
check "uses the one fetch_advisory_db exported" called_with cargo-audit --db "${CASE}/db" --json
audit_case
run audit.sh "RUSTSEC_ADVISORY_DB=${CASE}/db" "PARAM_DB_PATH=${CASE}/mine"
check "db_path wins over it" called_with cargo-audit --db "${CASE}/mine" --json
audit_case
make_db "${CASE}/db" 10
run audit.sh "PARAM_DB_PATH=${CASE}/db" PARAM_NO_FETCH=1
check "no_fetch with a fresh database succeeds" succeeded
check "passing --no-fetch once" called cargo-audit audit --file Cargo.lock --db "${CASE}/db" --no-fetch --json
check "and once to the SARIF pass" called cargo-audit audit --file Cargo.lock --db "${CASE}/db" --no-fetch --format sarif
check "saying how old it is" said "(10 days old)"
audit_case
make_db "${CASE}/db" 120
run audit.sh "PARAM_DB_PATH=${CASE}/db" PARAM_NO_FETCH=1
check "no_fetch with a database 90 days old or more fails" failed
check "saying it is stale" said "newest commit is 120 days old"
check "before running cargo audit" call_count cargo-audit 0
run audit.sh "PARAM_DB_PATH=${CASE}/db" PARAM_NO_FETCH=1 PARAM_ALLOW_STALE=1
check "unless allow_stale is true" succeeded
check "with a warning" said "allow_stale is true, so it is used anyway"
audit_case
make_db "${CASE}/db" -30
run audit.sh "PARAM_DB_PATH=${CASE}/db" PARAM_NO_FETCH=1
check "no_fetch with a database dated in the future fails, since it would never look stale" failed
check "saying so" said "days in the future, so its age can't be told"
run audit.sh "PARAM_DB_PATH=${CASE}/db" PARAM_NO_FETCH=1 PARAM_ALLOW_STALE=1
check "unless allow_stale is true" succeeded
audit_case
mkdir -p "${CASE}/db/crates"
run audit.sh "PARAM_DB_PATH=${CASE}/db" PARAM_NO_FETCH=1
check "no_fetch with a database whose age can't be read fails" failed
check "saying why" said "is not a git checkout"
audit_case
make_db "${CASE}/project" 1
mkdir -p "${CASE}/project/db/crates/x"
echo "# RUSTSEC-0000-0000" > "${CASE}/project/db/crates/x/RUSTSEC-0000-0000.md"
run audit.sh "PARAM_DB_PATH=${CASE}/project/db" PARAM_NO_FETCH=1
check "no_fetch doesn't date a database by the repository around it" failed
check "saying it is not a git checkout" said "is not a git checkout"
audit_case
make_db "${CASE}/db" 120
mkdir -p "${CASE}/work/.cargo"
printf '[database]\npath = "%s" # the staged copy\nfetch = false\n' "${CASE}/db" > "${CASE}/work/.cargo/audit.toml"
run audit.sh PARAM_RUN_RECORD=1
check "a stale database fails when .cargo/audit.toml turns fetching off" failed
check "saying so" said "newest commit is 120 days old"
check "after saying the config turned fetching off" said "turns fetching off ([database] fetch = false)"
check "before running cargo audit" call_count cargo-audit 0
printf '[database]\npath = "%s"\nfetch = false\nstale = true\n' "${CASE}/db" > "${CASE}/work/.cargo/audit.toml"
run audit.sh PARAM_RUN_RECORD=1
check "unless it also allows stale databases" succeeded
check "the run record names the database the config points to" json_is "${CASE}/out/cargo-audit.run-record.json" .advisory_db.path "${CASE}/db"
audit_case
make_db "${CASE}/home/.cargo/advisory-db" 1
run audit.sh PARAM_NO_FETCH=1
check "no_fetch checks cargo audit's default database" said "(1 days old)"

begin "audit: run records"
audit_case
mkdir -p "${CASE}/bin"
cp "${STUBS}/cargo-audit" "${CASE}/bin/cargo-audit"
printf '{"tool":"cargo-audit","version":"0.22.2","method":"prebuilt","binary_sha512":"%s"}\n' \
    "$(sha512sum "${CASE}/bin/cargo-audit" | awk '{ print $1 }')" > "${CASE}/bin/.cargo-audit.install.json"
run audit.sh "PATH=${CASE}/bin:${STUBS}:${PATH}" PARAM_RUN_RECORD=1 CIRCLE_BUILD_URL=https://circleci.example/1 CIRCLE_SHA1=abc CIRCLE_JOB=audit
RECORD="${CASE}/out/cargo-audit.run-record.json"
check "names the binary that ran" json_is "${RECORD}" .tool.path "${CASE}/bin/cargo-audit"
check "with its SHA-512" json_is "${RECORD}" .tool.sha512 "$(sha512sum "${CASE}/bin/cargo-audit" | awk '{ print $1 }')"
check "and the install record that matches it" json_is "${RECORD}" .tool.install.method prebuilt
check "and no other tools" json_is "${RECORD}" '.other_tools | length' 0
check "records the lockfile's SHA-256" json_is "${RECORD}" '.inputs[0].sha256' "$(sha256sum "${CASE}/work/Cargo.lock" | awk '{ print $1 }')"
check "records the arguments" json_is "${RECORD}" '.arguments | join(" ")' "audit --file Cargo.lock"
check "records the CircleCI job" json_is "${RECORD}" .ci.build_url https://circleci.example/1
check "records each report's SHA-256" json_is "${RECORD}" '.reports | length' 2
check "records cargo's version" json_is "${RECORD}" .toolchain.cargo "cargo 1.99.0 (stand-in)"
echo "changed" >> "${CASE}/bin/cargo-audit"
run audit.sh "PATH=${CASE}/bin:${STUBS}:${PATH}" PARAM_RUN_RECORD=1
check "leaves out an install record that doesn't match the binary" json_is "${RECORD}" .tool.install null
check "and warns that the binary is not one the install command verified" \
    said "WARN: ${CASE}/bin/cargo-audit is not the cargo-audit this orb's install command verified against its checksum table."
audit_case
run audit.sh
check "a verified binary gets no such warning" not_said "install command verified"
audit_case
mkdir -p "${CASE}/nosha"
printf '#!/bin/sh\necho "sha512sum: not available" >&2\nexit 127\n' > "${CASE}/nosha/sha512sum"
chmod +x "${CASE}/nosha/sha512sum"
run audit.sh "PATH=${CASE}/nosha:${STUBS}:${PATH}" PARAM_RUN_RECORD=1
check "without a working sha512sum, the step still passes" succeeded
check "and the run record has no SHA-512 for the tool" json_is "${CASE}/out/cargo-audit.run-record.json" .tool.sha512 null

# --- audit_bin
DEFAULTS=(PARAM_BINARIES="app" PARAM_REQUIRE_AUDITABLE=0 PARAM_DB_PATH= PARAM_NO_FETCH=false PARAM_ALLOW_STALE=false
    PARAM_NO_YANKED=false PARAM_DENY= PARAM_TARGET_ARCH= PARAM_TARGET_OS= PARAM_EXTRA_ARGS= PARAM_OUTPUT_DIR=/will/be/set
    PARAM_REPORT_NAME=cargo-audit-bin PARAM_SARIF=1 PARAM_JUNIT=0 PARAM_REPORT_ONLY=0 PARAM_RUN_RECORD=0)
bin_case() {
    new_case
    mkdir -p "${CASE}/work/target/release" "${CASE}/work/dist"
    echo AUDITABLE > "${CASE}/work/app"
    echo AUDITABLE > "${CASE}/work/target/release/app"
    echo AUDITABLE > "${CASE}/work/target/release/tool"
    echo plain > "${CASE}/work/dist/plain"
    set_default "PARAM_OUTPUT_DIR=${CASE}/out"
}

begin "audit_bin"
bin_case
mkdir -p "${CASE}/work/x" "${CASE}/work/a" "${CASE}/work/b"
for f in x/app-2 a/app b/app; do echo AUDITABLE > "${CASE}/work/${f}"; done
run audit_bin.sh "PARAM_BINARIES=x/app-2 a/app b/app"
check "names each binary's reports apart, even when <name>-2 is taken" \
    json_is "${CASE}/out/cargo-audit-bin.json" '[.binaries[].report | split("/")[-1]] | join(" ")' \
    "cargo-audit-bin-app-2.json cargo-audit-bin-app.json cargo-audit-bin-app-3.json"
bin_case
run audit_bin.sh "PARAM_BINARIES=app target/release/*" PARAM_RUN_RECORD=1
check "succeeds" succeeded
check "audits each binary on its own" call_count cargo-audit 7
check "the first may fetch the database" called cargo-audit audit --json bin app
check "the others read that copy" called cargo-audit audit --no-fetch --json bin target/release/tool
check "SARIF reads it too" called cargo-audit audit --no-fetch --format sarif bin app
check "writes a report per binary" exists "${CASE}/out/cargo-audit-bin-tool.json"
check "and an index of them" json_is "${CASE}/out/cargo-audit-bin.json" '[.binaries[].binary] | join(" ")' "app target/release/app target/release/tool"
check "naming a second binary called app apart" exists "${CASE}/out/cargo-audit-bin-app-2.json"
check "with each binary's SHA-256" json_is "${CASE}/out/cargo-audit-bin.json" '.binaries[0].sha256' "$(sha256sum "${CASE}/work/app" | awk '{ print $1 }')"
check "the run record lists each binary as an input" json_is "${CASE}/out/cargo-audit-bin.run-record.json" '[.inputs[] | select(.role == "binary")] | length' 3
check "and the arguments without them" json_is "${CASE}/out/cargo-audit-bin.run-record.json" '.arguments | join(" ")' "audit bin"
bin_case
run audit_bin.sh STUB_AUDIT=vuln PARAM_JUNIT=1
check "vulnerabilities fail the step" failed
check "naming the binary" said "app: 1 vulnerabilities"
check "JUnit names the binary's class" file_has "${CASE}/out/junit/cargo-audit-bin.xml" 'classname="cargo-audit-bin.app.vulnerability"'
bin_case
run audit_bin.sh STUB_AUDIT=vuln PARAM_REPORT_ONLY=1
check "report_only passes" succeeded
bin_case
run audit_bin.sh STUB_AUDIT=nodata PARAM_REPORT_ONLY=1 PARAM_RUN_RECORD=1
check "a binary with no dependency information fails even with report_only" failed
check "the run record says error" json_is "${CASE}/out/cargo-audit-bin.run-record.json" .outcome error
check "saying to build it with cargo auditable" said "build it with cargo auditable"
bin_case
run audit_bin.sh STUB_AUDIT=warn-config
check "warnings .cargo/audit.toml denies fail" failed
check "saying cargo audit's config denied them" said "the deny list in .cargo/audit.toml"
bin_case
run audit_bin.sh STUB_AUDIT=exit1 PARAM_REPORT_ONLY=1
check "a non-zero exit with nothing reported fails even with report_only" failed
bin_case
run audit_bin.sh "PARAM_BINARIES=app dist/plain" PARAM_REQUIRE_AUDITABLE=1 PARAM_JUNIT=1
check "require_auditable fails on a binary without cargo-auditable data" failed
check "naming it" said "1 carry no cargo-auditable data (require_auditable): dist/plain"
check "listing it in the index" json_is "${CASE}/out/cargo-audit-bin.json" '.without_auditable_data[0]' dist/plain
check "and in JUnit" file_has "${CASE}/out/junit/cargo-audit-bin.xml" 'classname="cargo-audit-bin.auditable" name="dist/plain"'
bin_case
run audit_bin.sh PARAM_REQUIRE_AUDITABLE=1 PARAM_RUN_RECORD=1
check "require_auditable's run record names rust-audit-info as well" \
    json_is "${CASE}/out/cargo-audit-bin.run-record.json" '.other_tools[0].install.tool' rust-audit-info
bin_case
mkdir -p "${CASE}/bin"
cp "${STUBS}/rust-audit-info" "${CASE}/bin/rust-audit-info"
echo "# changed" >> "${CASE}/bin/rust-audit-info"
run audit_bin.sh PARAM_REQUIRE_AUDITABLE=1 "PATH=${CASE}/bin:${STUBS}:${PATH}"
check "and warns about one the install command didn't verify" \
    said "WARN: ${CASE}/bin/rust-audit-info is not the rust-audit-info this orb's install command verified"
bin_case
run audit_bin.sh PARAM_REQUIRE_AUDITABLE=1 "PATH=$(path_without rust-audit-info)"
check "require_auditable needs rust-audit-info" failed
check "saying how to install it" said "require_auditable needs rust-audit-info"
bin_case
run audit_bin.sh "PARAM_BINARIES=missing/*"
check "a pattern that matches nothing fails" failed
check "saying so" said "matches no file"
bin_case
run audit_bin.sh PARAM_BINARIES=
check "no binaries fails" failed
bin_case
run audit_bin.sh STUB_SARIF=crash PARAM_RUN_RECORD=1
check "a SARIF pass that fails fails the step" failed
check "saying so" said "ERROR: cargo audit bin did not write a SARIF report for app."
check "the run record says error" json_is "${CASE}/out/cargo-audit-bin.run-record.json" .outcome error
check "with the SARIF pass's exit code" json_is "${CASE}/out/cargo-audit-bin.run-record.json" .exit_code 101
check "and its log" json_is "${CASE}/out/cargo-audit-bin.run-record.json" '[.reports[].path | split("/")[-1]] | join(" ")' "cargo-audit-bin-app.json cargo-audit-bin-app.sarif.log"

# --- deny
DEFAULTS=(PARAM_CHECKS= PARAM_MANIFEST_PATH= PARAM_CONFIG_PATH= PARAM_METADATA_PATH= PARAM_FEATURES= PARAM_ALL_FEATURES=false
    PARAM_NO_DEFAULT_FEATURES=false PARAM_TARGET= PARAM_OFFLINE=false PARAM_LOCKED=false PARAM_FROZEN=false PARAM_WORKSPACE=false
    PARAM_EXCLUDE= PARAM_EXCLUDE_DEV=false PARAM_ALLOW= PARAM_WARN= PARAM_DENY= PARAM_REQUIRE_IGNORE_REASONS=false
    PARAM_AUDIT_COMPATIBLE_OUTPUT=false PARAM_EXTRA_ARGS= PARAM_OUTPUT_DIR=/will/be/set PARAM_REPORT_NAME=cargo-deny
    PARAM_SARIF=true PARAM_JUNIT=false PARAM_REPORT_ONLY=false PARAM_RUN_RECORD=false)
deny_case() {
    new_case
    mkdir -p "${CASE}/work/app"
    echo "[package]" > "${CASE}/work/app/Cargo.toml"
    echo "# lockfile" > "${CASE}/work/Cargo.lock"
    echo "[advisories]" > "${CASE}/work/deny.toml"
    set_default "PARAM_OUTPUT_DIR=${CASE}/out"
}

begin "deny: no findings"
deny_case
run deny.sh
check "succeeds" succeeded
check "checks with JSON diagnostics at info level" called cargo-deny --format json --log-level info check
check "then writes SARIF in a second pass, offline" called cargo-deny --format sarif --offline check
check "keeps the JSON diagnostics" file_has "${CASE}/out/cargo-deny.jsonl" '"type":"summary"'
check "writes the SARIF report" json_is "${CASE}/out/cargo-deny.sarif" .version 2.1.0
check "says it passed" said "Passed: cargo deny found no errors."
check "with each check's counts" said "  bans: 0 errors, 0 warnings"
check "writes no audit-compatible report unless asked" absent "${CASE}/out/cargo-deny.audit.json"
deny_case
run deny.sh PARAM_SARIF=false
check "sarif false runs cargo deny once" call_count cargo-deny 2
check "and writes no SARIF" absent "${CASE}/out/cargo-deny.sarif"

begin "deny: findings"
deny_case
run deny.sh STUB_DENY=vuln PARAM_JUNIT=true PARAM_RUN_RECORD=true
check "an advisory fails the step" failed
check "naming the failed check" said "ERROR: cargo deny failed: advisories."
check "listing the finding" said "error[vulnerability] RUSTSEC-2021-0003 smallvec 1.6.0: Buffer overflow"
check "still writes the SARIF report" exists "${CASE}/out/cargo-deny.sarif"
check "JUnit has a failed case for it" file_has "${CASE}/out/junit/cargo-deny.xml" 'classname="cargo-deny.vulnerability" name="RUSTSEC-2021-0003 smallvec 1.6.0"><failure'
check "with its notes" file_has "${CASE}/out/junit/cargo-deny.xml" 'ID: RUSTSEC-2021-0003</failure>'
check "the run record says findings" json_is "${CASE}/out/cargo-deny.run-record.json" .outcome findings
check "with the counts per check" json_is "${CASE}/out/cargo-deny.run-record.json" .counts.advisories.errors 1
deny_case
run deny.sh STUB_DENY=banned PARAM_RUN_RECORD=true
check "a banned crate fails the step" failed
check "naming bans" said "cargo deny failed: bans."
check "the run record keeps cargo deny's exit code" json_is "${CASE}/out/cargo-deny.run-record.json" .exit_code 2
deny_case
run deny.sh STUB_DENY=banned PARAM_REPORT_ONLY=true PARAM_RUN_RECORD=true
check "report_only passes" succeeded
check "with a warning" said "WARN: cargo deny failed: bans."
check "the run record says findings-reported" json_is "${CASE}/out/cargo-deny.run-record.json" .outcome findings-reported
deny_case
run deny.sh STUB_DENY=warn PARAM_JUNIT=true
check "warnings pass" succeeded
check "listed" said "warning[unmaintained] RUSTSEC-2021-0139 ansi_term 0.12.1"
check "as skipped JUnit cases" file_has "${CASE}/out/junit/cargo-deny.xml" 'skipped="1"'

deny_case
run deny.sh STUB_DENY=nolabel PARAM_JUNIT=true
check "a diagnostic about no crate or advisory" succeeded
check "is a JUnit case named by its code" file_has "${CASE}/out/junit/cargo-deny.xml" 'classname="cargo-deny.license-not-encountered" name="license-not-encountered"><skipped'

begin "deny: a cargo deny that doesn't complete"
deny_case
run deny.sh STUB_DENY=crash PARAM_REPORT_ONLY=true PARAM_RUN_RECORD=true
check "fails the step even with report_only" failed
check "saying it didn't complete" said "ERROR: cargo deny did not complete (exit code 1)"
check "with cargo deny's own error" said "failed to validate configuration file deny.toml"
check "without a SARIF pass" call_count cargo-deny 2
check "the run record says error" json_is "${CASE}/out/cargo-deny.run-record.json" .outcome error
deny_case
run deny.sh STUB_SARIF=crash PARAM_REPORT_ONLY=true PARAM_RUN_RECORD=true
check "a SARIF pass that fails fails the step even with report_only" failed
check "saying so" said "ERROR: cargo deny did not write a SARIF report."
check "the run record says error" json_is "${CASE}/out/cargo-deny.run-record.json" .outcome error
check "with the SARIF pass's exit code" json_is "${CASE}/out/cargo-deny.run-record.json" .exit_code 101
check "and its log" json_is "${CASE}/out/cargo-deny.run-record.json" '[.reports[].path | split("/")[-1]] | join(" ")' "cargo-deny.jsonl cargo-deny.sarif.log"
deny_case
run deny.sh PARAM_CONFIG_PATH=missing.toml
check "a config_path that doesn't exist fails" failed
check "saying so, rather than fall back to cargo deny's default config" said "config_path missing.toml does not exist"
check "before running cargo deny" not_called_with cargo-deny check
deny_case
run deny.sh PARAM_METADATA_PATH=missing.json
check "a metadata_path that doesn't exist fails" failed
deny_case
run deny.sh PARAM_CHECKS=advisory
check "checks refuses a check cargo deny doesn't have" failed
check "saying which it takes" said "checks takes advisories, bans, licenses, sources and all"
for word in --format=sarif -fjson; do
    deny_case
    run deny.sh "PARAM_EXTRA_ARGS=${word}"
    check "refuses ${word} in extra_args" failed
done

begin "deny: ignored advisories"
deny_case
run deny.sh STUB_DENY=ignored-bare PARAM_REQUIRE_IGNORE_REASONS=true PARAM_JUNIT=true PARAM_RUN_RECORD=true
check "require_ignore_reasons fails on an ignore without a reason" failed
check "naming the advisory" said "Ignored without a reason in deny.toml: RUSTSEC-2021-0003"
check "and why the step failed" said "1 ignored advisories have no reason in deny.toml (require_ignore_reasons)"
check "as a failed JUnit case" file_has "${CASE}/out/junit/cargo-deny.xml" 'classname="cargo-deny.ignore-reason" name="RUSTSEC-2021-0003"'
check "counted in the run record" json_is "${CASE}/out/cargo-deny.run-record.json" .counts.ignores_without_reason 1
deny_case
run deny.sh STUB_DENY=ignored-reason PARAM_REQUIRE_IGNORE_REASONS=true
check "an ignore with a reason passes" succeeded
deny_case
run deny.sh STUB_DENY=ignored-bare
check "an ignore without a reason passes unless require_ignore_reasons is true" succeeded
check "quietly" not_said "Ignored without a reason"

begin "deny: options"
deny_case
run deny.sh PARAM_MANIFEST_PATH=app/Cargo.toml PARAM_CONFIG_PATH=deny.toml "PARAM_FEATURES=a, b" PARAM_WORKSPACE=true \
    "PARAM_EXCLUDE=x y" PARAM_EXCLUDE_DEV=true PARAM_TARGET=x86_64-unknown-linux-gnu PARAM_OFFLINE=true PARAM_LOCKED=true \
    "PARAM_CHECKS=advisories bans" PARAM_ALLOW=unmaintained "PARAM_WARN=duplicate" "PARAM_DENY=unlicensed,yanked" \
    'PARAM_EXTRA_ARGS=--hide-inclusion-graph'
check "puts the graph options before check, and the rest after" \
    called cargo-deny --format json --log-level info --manifest-path app/Cargo.toml --config deny.toml --workspace \
    --exclude x --exclude y --exclude-dev --features a,b --target x86_64-unknown-linux-gnu --offline --locked \
    check advisories bans --allow unmaintained --warn duplicate --deny unlicensed --deny yanked --hide-inclusion-graph
check "and passes them to the SARIF pass, offline once" \
    called cargo-deny --format sarif --manifest-path app/Cargo.toml --config deny.toml --workspace \
    --exclude x --exclude y --exclude-dev --features a,b --target x86_64-unknown-linux-gnu --offline --locked \
    check advisories bans --allow unmaintained --warn duplicate --deny unlicensed --deny yanked --hide-inclusion-graph
deny_case
run deny.sh PARAM_FROZEN=true PARAM_OFFLINE=true PARAM_LOCKED=true PARAM_ALL_FEATURES=true PARAM_NO_DEFAULT_FEATURES=true
check "frozen stands for offline and locked" called cargo-deny --format json --log-level info --all-features --no-default-features --frozen check
check "including in the SARIF pass" called cargo-deny --format sarif --all-features --no-default-features --frozen check
deny_case
run deny.sh PARAM_AUDIT_COMPATIBLE_OUTPUT=true
check "audit_compatible_output passes --audit-compatible-output" called_with cargo-deny --audit-compatible-output
check "and keeps that report" json_is "${CASE}/out/cargo-deny.audit.json" '.vulnerabilities | length' 0

begin "deny: run records"
deny_case
make_db "${CASE}/home/.cargo/advisory-dbs/${DB_NAME}" 2
run deny.sh PARAM_MANIFEST_PATH=app/Cargo.toml PARAM_RUN_RECORD=true
RECORD="${CASE}/out/cargo-deny.run-record.json"
check "records the deny.toml cargo deny finds above the manifest" json_is "${RECORD}" '.inputs[] | select(.role == "config") | .path' "${CASE}/work/deny.toml"
check "and the lockfile" json_is "${RECORD}" '.inputs[] | select(.role == "lockfile") | .sha256' "$(sha256sum "${CASE}/work/Cargo.lock" | awk '{ print $1 }')"
check "records the database cargo deny reads" json_is "${RECORD}" .advisory_db.commit "$(git -C "${CASE}/home/.cargo/advisory-dbs/${DB_NAME}" log -1 --format=%H)"
check "records every report" json_is "${RECORD}" '[.reports[].path | split("/")[-1]] | join(" ")' "cargo-deny.jsonl cargo-deny.sarif"
deny_case
make_db "${CASE}/home/.cargo/advisory-dbs/${DB_NAME}" 2
"${REAL_GIT}" -C "${CASE}/home/.cargo/advisory-dbs/${DB_NAME}" remote add origin "https://ci:s3cret-token@mirror.example.test/advisory-db"
run deny.sh PARAM_RUN_RECORD=true
check "records the database's remote without the credentials in its URL" \
    json_is "${CASE}/out/cargo-deny.run-record.json" .advisory_db.url "https://mirror.example.test/advisory-db"
check "anywhere in the run record" not_file_has "${CASE}/out/cargo-deny.run-record.json" "s3cret-token"
"${REAL_GIT}" -C "${CASE}/home/.cargo/advisory-dbs/${DB_NAME}" remote set-url origin "https://mirror.example.test/advisory-db?access_token=s3cret-token#x"
run deny.sh PARAM_RUN_RECORD=true
check "nor in its query or fragment" \
    json_is "${CASE}/out/cargo-deny.run-record.json" .advisory_db.url "https://mirror.example.test/advisory-db"
check "which reach the run record nowhere" not_file_has "${CASE}/out/cargo-deny.run-record.json" "s3cret-token"
check "records the arguments" json_is "${RECORD}" '.arguments | join(" ")' "--manifest-path app/Cargo.toml check"
deny_case
mkdir -p "${CASE}/home/dbs"
make_db "${CASE}/home/dbs/advisory-db-3157b0e258782691" 2
printf '[advisories]\ndb-path = "~/dbs"\n' > "${CASE}/work/deny.toml"
run deny.sh PARAM_RUN_RECORD=true "RUSTSEC_ADVISORY_DB=${CASE}/home/dbs/advisory-db-3157b0e258782691"
check "records a database in deny.toml's db-path" json_is "${CASE}/out/cargo-deny.run-record.json" '.advisory_db.path' "${CASE}/home/dbs/advisory-db-3157b0e258782691"
check "with its commit" json_is "${CASE}/out/cargo-deny.run-record.json" '.advisory_db.commit | length' 40
deny_case
mkdir -p "${CASE}/ci/dbs"
make_db "${CASE}/ci/dbs/advisory-db-3157b0e258782691" 2
# shellcheck disable=SC2016 # a literal reference, which cargo-deny expands
printf '[advisories]\ndb-path = "${CI_PROJECT_DIR:-/nowhere}/dbs"\n' > "${CASE}/work/deny.toml"
run deny.sh PARAM_RUN_RECORD=true "CI_PROJECT_DIR=${CASE}/ci"
check "expands variables in db-path as cargo-deny does" json_is "${CASE}/out/cargo-deny.run-record.json" '.advisory_db.path' "${CASE}/ci/dbs/advisory-db-3157b0e258782691"
deny_case
make_db "${CASE}/home/.cargo/advisory-dbs/${DB_NAME}" 2
printf '[advisories]\ndb-path = "dbs"\n' > "${CASE}/work/deny.toml"
run deny.sh PARAM_RUN_RECORD=true
check "leaves the database out for a relative db-path, rather than name the wrong one" json_is "${CASE}/out/cargo-deny.run-record.json" .advisory_db null
deny_case
make_db "${CASE}/home/.cargo/advisory-dbs/${DB_NAME}" 2
printf '[advisories]\ndb-urls = ["https://mirror.example.test/advisory-db"]\n' > "${CASE}/work/deny.toml"
run deny.sh PARAM_RUN_RECORD=true
check "and the RustSec default's copy when deny.toml names other db-urls" json_is "${CASE}/out/cargo-deny.run-record.json" .advisory_db null
for urls in '["https://mirror.example.test/advisory-db"]' $'[\n  "https://other.example.test/db", # first\n  \'https://mirror.example.test/advisory-db\',\n]'; do
    deny_case
    make_db "${CASE}/home/.cargo/advisory-dbs/advisory-db-0123456789abcdef" 2
    "${REAL_GIT}" -C "${CASE}/home/.cargo/advisory-dbs/advisory-db-0123456789abcdef" remote add origin "https://Mirror.Example.Test:443/advisory-db"
    printf '[advisories]\ndb-urls = %s\n' "${urls}" > "${CASE}/work/deny.toml"
    run deny.sh PARAM_RUN_RECORD=true "RUSTSEC_ADVISORY_DB=${CASE}/home/.cargo/advisory-dbs/advisory-db-0123456789abcdef"
    check "records fetch_advisory_db's copy of a URL db-urls names (${urls//$'\n'/ })" \
        json_is "${CASE}/out/cargo-deny.run-record.json" .advisory_db.path "${CASE}/home/.cargo/advisory-dbs/advisory-db-0123456789abcdef"
done
deny_case
make_db "${CASE}/home/.cargo/advisory-dbs/advisory-db-0123456789abcdef" 2
"${REAL_GIT}" -C "${CASE}/home/.cargo/advisory-dbs/advisory-db-0123456789abcdef" remote add origin "https://github.com/rustsec/advisory-db"
printf '[advisories]\ndb-urls = ["https://mirror.example.test/advisory-db"]\n' > "${CASE}/work/deny.toml"
run deny.sh PARAM_RUN_RECORD=true "RUSTSEC_ADVISORY_DB=${CASE}/home/.cargo/advisory-dbs/advisory-db-0123456789abcdef"
check "but not its copy of another URL, which cargo deny doesn't read" json_is "${CASE}/out/cargo-deny.run-record.json" .advisory_db null
deny_case
make_db "${CASE}/home/.cargo/advisory-dbs/advisory-db-0123456789abcdef" 2
"${REAL_GIT}" -C "${CASE}/home/.cargo/advisory-dbs/advisory-db-0123456789abcdef" remote add origin "https://mirror.example.test/advisory-db"
run deny.sh PARAM_RUN_RECORD=true "RUSTSEC_ADVISORY_DB=${CASE}/home/.cargo/advisory-dbs/advisory-db-0123456789abcdef"
check "nor a mirror's copy without db-urls, when cargo deny reads RustSec's" json_is "${CASE}/out/cargo-deny.run-record.json" .advisory_db null
deny_case
mkdir -p "${CASE}/home/.cargo/advisory-dbs/${DB_NAME}"
run deny.sh PARAM_RUN_RECORD=true
check "a database without git history leaves its commit null" json_is "${CASE}/out/cargo-deny.run-record.json" '.advisory_db | "\(.path | split("/")[-1]) \(.commit)"' "${DB_NAME} null"

# --- licenses
DEFAULTS=("PARAM_FORMATS=json,tsv" PARAM_LAYOUT=crate PARAM_MANIFEST_PATH= PARAM_CONFIG_PATH= PARAM_METADATA_PATH= PARAM_FEATURES=
    PARAM_ALL_FEATURES=false PARAM_NO_DEFAULT_FEATURES=false PARAM_TARGET= PARAM_OFFLINE=false PARAM_LOCKED=false
    PARAM_OUTPUT_DIR=/will/be/set PARAM_REPORT_NAME=licenses PARAM_RUN_RECORD=false)

begin "licenses"
deny_case
run licenses.sh PARAM_RUN_RECORD=true
check "succeeds" succeeded
check "lists licences per crate as JSON" called cargo-deny list --layout crate --format json
check "and as TSV" called cargo-deny list --layout crate --format tsv
check "writes the JSON inventory" json_is "${CASE}/out/licenses.json" 'keys | length' 2
check "writes the TSV inventory" file_has "${CASE}/out/licenses.tsv" $'smallvec@1.6.0\tX\tX'
check "prints each crate's licences" said "smallvec 1.6.0: MIT, Apache-2.0"
check "counts them in the run record" json_is "${CASE}/out/licenses.run-record.json" '.counts | "\(.crates) \(.licenses)"' "2 2"
check "records the deny.toml cargo deny finds, which can clarify licences" \
    json_is "${CASE}/out/licenses.run-record.json" '.inputs[] | select(.role == "config") | .path' "${CASE}/work/deny.toml"
deny_case
run licenses.sh PARAM_LAYOUT=license PARAM_FORMATS=json PARAM_MANIFEST_PATH=app/Cargo.toml "PARAM_FEATURES=a b" PARAM_OFFLINE=true \
    PARAM_TARGET=aarch64-unknown-linux-gnu
check "layout license lists crates per licence, with the graph options first" \
    called cargo-deny --manifest-path app/Cargo.toml --features a,b --target aarch64-unknown-linux-gnu --offline list --layout license --format json
check "prints each licence's crates" said "MIT: 2 crates"
check "writes only the formats asked for" absent "${CASE}/out/licenses.tsv"
deny_case
run licenses.sh STUB_DENY=crash PARAM_RUN_RECORD=true
check "a failing cargo deny list fails" failed
check "with its error" said "error: list failed"
check "and a run record that says so" json_is "${CASE}/out/licenses.run-record.json" .outcome error
check "with cargo deny's exit code" json_is "${CASE}/out/licenses.run-record.json" .exit_code 3
for bad in "PARAM_FORMATS=csv" "PARAM_FORMATS=" "PARAM_LAYOUT=tree" "PARAM_CONFIG_PATH=missing.toml"; do
    deny_case
    run licenses.sh "${bad}"
    check "refuses ${bad#PARAM_}" failed
    check "before running cargo deny list" not_called_with cargo-deny list
done

# --- auditable_build
DEFAULTS=(PARAM_SUBCOMMAND=build PARAM_EXTRA_ARGS=)

begin "auditable_build"
new_case
run auditable_build.sh 'PARAM_EXTRA_ARGS=--release --locked --features "a b"'
check "succeeds" succeeded
check "builds with cargo auditable, passing extra_args" called cargo auditable build --release --locked --features "a b"
check "says what it built with" said "with cargo 1.99.0 (stand-in) and ${STUBS}/cargo-auditable"
check "without a warning" not_said "WARN:"
new_case
run auditable_build.sh PARAM_SUBCOMMAND=install 'PARAM_EXTRA_ARGS=--path . --root /tmp/x'
check "runs install" called cargo auditable install --path . --root /tmp/x
new_case
run auditable_build.sh STUB_BUILD=fail
check "a failed build fails" failed
check "with cargo's error" said "error: could not compile"
new_case
run auditable_build.sh PARAM_SUBCOMMAND=test
check "refuses another subcommand" failed
check "before building" call_count cargo 0
new_case
mkdir -p "${CASE}/home/.cargo/bin"
printf '#!/bin/sh\nexit 0\n' > "${CASE}/home/.cargo/bin/cargo-auditable"
chmod +x "${CASE}/home/.cargo/bin/cargo-auditable"
run auditable_build.sh
check "warns when cargo would run another cargo-auditable" said "WARN: cargo will run ${CASE}/home/.cargo/bin/cargo-auditable"
new_case
run auditable_build.sh "PATH=$(path_without cargo-auditable)"
check "needs cargo-auditable" failed
check "saying so" said "cargo-auditable"
new_case
run auditable_build.sh 'PARAM_EXTRA_ARGS=--release; rm -rf /'
check "refuses shell operators in extra_args" failed

# --- verify_auditable
DEFAULTS=(PARAM_BINARIES=app PARAM_CYCLONEDX=false PARAM_OUTPUT_DIR=/will/be/set PARAM_REPORT_NAME=auditable PARAM_JUNIT=false
    PARAM_RUN_RECORD=false)

begin "verify_auditable"
bin_case
run verify_auditable.sh "PARAM_BINARIES=app target/release/*" PARAM_JUNIT=true
check "succeeds" succeeded
check "reads each binary with rust-audit-info" called rust-audit-info target/release/tool
check "says what each holds" said "app: ok, app 0.1.0, 2 packages"
check "writes each binary's dependency list" json_is "${CASE}/out/auditable-tool.audit.json" '.packages | length' 2
check "naming a second binary called app apart" exists "${CASE}/out/auditable-app-2.audit.json"
check "and an index" json_is "${CASE}/out/auditable.json" '[.binaries[] | select(.auditable)] | length' 3
check "JUnit has a passing case per binary" file_has "${CASE}/out/junit/auditable.xml" 'tests="3" failures="0"'
check "says it passed" said "Passed: every binary carries cargo-auditable data that decodes."
bin_case
mkdir -p "${CASE}/work/x" "${CASE}/work/a" "${CASE}/work/b"
for f in x/app-2 a/app b/app; do echo AUDITABLE > "${CASE}/work/${f}"; done
echo plain > "${CASE}/work/b/app"
run verify_auditable.sh "PARAM_BINARIES=x/app-2 a/app b/app" PARAM_RUN_RECORD=true
check "names each binary's reports apart, even when <name>-2 is taken" exists "${CASE}/out/auditable-app-2.audit.json"
check "so a failing binary leaves the others' reports alone" json_is "${CASE}/out/auditable.json" '[.binaries[].report // empty | split("/")[-1]] | join(" ")' \
    "auditable-app-2.audit.json auditable-app.audit.json"
check "the run record has no arguments" json_is "${CASE}/out/auditable.run-record.json" '.arguments | length' 0
bin_case
run verify_auditable.sh PARAM_CYCLONEDX=true
check "cyclonedx turns it into a CycloneDX SBOM" json_is "${CASE}/out/auditable-app.cdx.json" .specVersion 1.3
check "with auditable2cdx" called auditable2cdx app
check "listed in the index" json_is "${CASE}/out/auditable.json" '.binaries[0].sbom' "${CASE}/out/auditable-app.cdx.json"
bin_case
run verify_auditable.sh PARAM_CYCLONEDX=true PARAM_RUN_RECORD=true STUB_A2C=crash
check "an auditable2cdx that fails fails the step" failed
check "with its error" said "Error: invalid dependency list"
check "the run record says error" json_is "${CASE}/out/auditable.run-record.json" .outcome error
check "with auditable2cdx's exit code" json_is "${CASE}/out/auditable.run-record.json" .exit_code 2
bin_case
run verify_auditable.sh PARAM_CYCLONEDX=true PARAM_RUN_RECORD=true
check "the run record names auditable2cdx as well" json_is "${CASE}/out/auditable.run-record.json" '.other_tools[0].path' "${STUBS}/auditable2cdx"
check "with its SHA-512" json_is "${CASE}/out/auditable.run-record.json" '.other_tools[0].sha512' "$(sha512sum "${STUBS}/auditable2cdx" | awk '{ print $1 }')"
check "and its install record" json_is "${CASE}/out/auditable.run-record.json" '.other_tools[0].install.tool' auditable2cdx
bin_case
mkdir -p "${CASE}/bin"
cp "${STUBS}/auditable2cdx" "${CASE}/bin/auditable2cdx"
echo "# changed" >> "${CASE}/bin/auditable2cdx"
run verify_auditable.sh PARAM_CYCLONEDX=true PARAM_RUN_RECORD=true "PATH=${CASE}/bin:${STUBS}:${PATH}"
check "an auditable2cdx the install command didn't verify gets the warning" \
    said "WARN: ${CASE}/bin/auditable2cdx is not the auditable2cdx this orb's install command verified against its checksum table."
check "and no install record in the run record" json_is "${CASE}/out/auditable.run-record.json" '.other_tools[0].install' null
bin_case
run verify_auditable.sh "PARAM_BINARIES=app dist/plain" PARAM_JUNIT=true PARAM_RUN_RECORD=true
check "a binary without the data fails" failed
check "naming it" said "ERROR: 1 of 2 binaries carry no cargo-auditable data that decodes: dist/plain."
check "saying what removes it" said "llvm-strip or --strip-section-headers"
check "with rust-audit-info's reason" said "dist/plain: FAILED: No audit data found in the binary!"
check "still checks the rest" exists "${CASE}/out/auditable-app.audit.json"
check "JUnit has a failed case for it" file_has "${CASE}/out/junit/auditable.xml" 'name="dist/plain"><failure'
check "the index records it" json_is "${CASE}/out/auditable.json" '.binaries[1].auditable' false
check "the run record says findings" json_is "${CASE}/out/auditable.run-record.json" .outcome findings
bin_case
run verify_auditable.sh PARAM_CYCLONEDX=true "PATH=$(path_without auditable2cdx)"
check "cyclonedx needs auditable2cdx" failed
check "saying how to install it" said "Add auditable2cdx to the install command's"
check "before reading any binary" call_count rust-audit-info 0
bin_case
run verify_auditable.sh "PARAM_BINARIES=target/debug/*"
check "a pattern that matches nothing fails" failed
check "saying so" said "matches no file"
bin_case
run verify_auditable.sh PARAM_BINARIES=target
check "a directory fails" failed
check "saying it isn't a file" said "target is not a file"

# --- sbom
DEFAULTS=(PARAM_MANIFEST_PATH= PARAM_FORMAT=json PARAM_SPEC_VERSION=1.5 PARAM_DESCRIBE=crate PARAM_FEATURES= PARAM_ALL_FEATURES=false
    PARAM_NO_DEFAULT_FEATURES=false PARAM_TARGET= PARAM_TOP_LEVEL=false PARAM_OFFLINE=false PARAM_LOCKED=true PARAM_EXTRA_ARGS=
    PARAM_OUTPUT_DIR=/will/be/set PARAM_REPORT_NAME=sbom PARAM_RUN_RECORD=false "STUB_MEMBERS=. crates/a")
sbom_case() {
    new_case
    mkdir -p "${CASE}/work/crates/a"
    echo "[workspace]" > "${CASE}/work/Cargo.toml"
    echo "[package]" > "${CASE}/work/crates/a/Cargo.toml"
    echo "# lockfile" > "${CASE}/work/Cargo.lock"
    set_default "PARAM_OUTPUT_DIR=${CASE}/out"
}

begin "sbom"
sbom_case
echo '{"bomFormat":"CycloneDX"}' > "${CASE}/work/crates/a/old.cdx.json"
touch -d '2 days ago' "${CASE}/work/crates/a/old.cdx.json"
run sbom.sh PARAM_RUN_RECORD=true
check "succeeds" succeeded
check "checks the lockfile is up to date first" called cargo metadata --format-version 1 --locked
check "runs cargo cyclonedx" called cargo-cyclonedx cyclonedx --format json --spec-version 1.5 --describe crate
check "moves each member's SBOM into output_dir, by its path in the workspace" json_is "${CASE}/out/sbom/crates/a/a.cdx.json" .bomFormat CycloneDX
check "the root's too" exists "${CASE}/out/sbom/work.cdx.json"
check "leaving none in the workspace" absent "${CASE}/work/crates/a/a.cdx.json"
check "leaves an SBOM it didn't write where it was" exists "${CASE}/work/crates/a/old.cdx.json"
check "and out of output_dir" absent "${CASE}/out/sbom/crates/a/old.cdx.json"
check "says how many components each has" said "crates/a/a.cdx.json: 1 components"
check "says how many it wrote" said "Wrote 2 SBOMs to ${CASE}/out/sbom."
check "records them in the run record" json_is "${CASE}/out/sbom.run-record.json" '.reports | length' 2
check "leaves CARGO_BUILD_TARGET alone without target" json_is "${CASE}/out/sbom/work.cdx.json" .target unset
sbom_case
run sbom.sh STUB_CDX=busy
check "leaves other JSON files written meanwhile in the workspace" exists "${CASE}/work/crates/a/package.json"
check "and out of output_dir" absent "${CASE}/out/sbom/crates/a/package.json"
sbom_case
run sbom.sh STUB_CDX=busy PARAM_FORMAT=xml
check "and other XML files" exists "${CASE}/work/crates/a/pom.xml"
check "moving only the SBOMs" said "Wrote 2 SBOMs"
sbom_case
run sbom.sh STUB_LOCK=stale
check "an out-of-date Cargo.lock fails" failed
check "saying the SBOM would not describe it" said "Cargo.lock is missing or out of date"
check "before cargo cyclonedx can rewrite it" not_called_with cargo-cyclonedx --format
sbom_case
run sbom.sh STUB_LOCK=stale PARAM_LOCKED=false
check "unless locked is false" succeeded
sbom_case
run sbom.sh PARAM_FORMAT=xml PARAM_SPEC_VERSION=1.4 PARAM_DESCRIBE=binaries "PARAM_FEATURES=a b" PARAM_NO_DEFAULT_FEATURES=true \
    PARAM_TOP_LEVEL=true PARAM_TARGET=x86_64-unknown-linux-gnu CARGO_BUILD_TARGET=aarch64-unknown-linux-gnu
check "passes the options" called cargo-cyclonedx cyclonedx --format xml --spec-version 1.4 --describe binaries --features a,b \
    --no-default-features --target x86_64-unknown-linux-gnu --top-level
check "moves XML SBOMs" exists "${CASE}/out/sbom/crates/a/a.cdx.xml"
sbom_case
run sbom.sh PARAM_TARGET=x86_64-unknown-linux-gnu CARGO_BUILD_TARGET=aarch64-unknown-linux-gnu
check "target unsets CARGO_BUILD_TARGET, which would override it" json_is "${CASE}/out/sbom/work.cdx.json" .target unset
sbom_case
run sbom.sh PARAM_OFFLINE=true PARAM_MANIFEST_PATH=Cargo.toml
check "offline keeps cargo metadata off the network" called cargo metadata --format-version 1 --locked --manifest-path Cargo.toml --offline
check "and cargo cyclonedx's cargo too" json_is "${CASE}/out/sbom/work.cdx.json" .offline true
sbom_case
run sbom.sh STUB_CDX=crash PARAM_RUN_RECORD=true
check "a failing cargo cyclonedx fails" failed
check "with its error" said "Error: cargo metadata failed"
check "the run record says error" json_is "${CASE}/out/sbom.run-record.json" .outcome error
check "with its exit code and log" json_is "${CASE}/out/sbom.run-record.json" '"\(.exit_code) \([.reports[].path | split("/")[-1]] | join(" "))"' "1 sbom.log"
sbom_case
run sbom.sh STUB_CDX=bad PARAM_RUN_RECORD=true
check "an SBOM that isn't one fails" failed
check "naming it" said "ERROR: work.cdx.json is not a CycloneDX JSON document."
check "with an error run record that lists it" json_is "${CASE}/out/sbom.run-record.json" '"\(.outcome) \([.reports[].path | split("/")[-1]] | join(" "))"' "error work.cdx.json"
sbom_case
run sbom.sh STUB_CDX=none PARAM_RUN_RECORD=true
check "no SBOM at all fails" failed
check "saying so" said "ERROR: cargo cyclonedx wrote no SBOM"
check "with an error run record" json_is "${CASE}/out/sbom.run-record.json" .outcome error
for bad in PARAM_FORMAT=spdx PARAM_SPEC_VERSION=1.6 PARAM_DESCRIBE=all PARAM_EXTRA_ARGS=--override-filename=x; do
    sbom_case
    run sbom.sh "${bad}"
    check "refuses ${bad#PARAM_}" failed
    check "before running cargo cyclonedx" not_called_with cargo-cyclonedx --format
done

# --- vet
DEFAULTS=(PARAM_MANIFEST_PATH= PARAM_STORE_PATH= PARAM_FILTER_GRAPH= PARAM_LOCKED=false PARAM_FROZEN=false PARAM_FEATURES=
    PARAM_NO_DEFAULT_FEATURES=false PARAM_NO_ALL_FEATURES=false PARAM_EXTRA_ARGS= PARAM_OUTPUT_DIR=/will/be/set
    PARAM_REPORT_NAME=cargo-vet PARAM_JUNIT=false PARAM_REPORT_ONLY=false PARAM_RUN_RECORD=false)
vet_case() {
    new_case
    mkdir -p "${CASE}/work/supply-chain"
    echo "# lockfile" > "${CASE}/work/Cargo.lock"
    echo "[cargo-vet]" > "${CASE}/work/supply-chain/config.toml"
    echo "" > "${CASE}/work/supply-chain/audits.toml"
    set_default "PARAM_OUTPUT_DIR=${CASE}/out"
}

begin "vet"
vet_case
run vet.sh PARAM_RUN_RECORD=true
check "succeeds" succeeded
check "runs cargo-vet with the job's cargo, writing JSON" called cargo-vet vet check --output-format json --output-file "${CASE}/out/cargo-vet.json"
check "writes the report" json_is "${CASE}/out/cargo-vet.json" .conclusion success
check "says it passed" said "Passed: cargo vet: success."
check "records the store's files" json_is "${CASE}/out/cargo-vet.run-record.json" '[.inputs[] | select(.role == "store")] | length' 2
check "and the counts" json_is "${CASE}/out/cargo-vet.run-record.json" .counts.vetted_with_exemptions 1
check "and the workspace's Cargo.lock, which cargo vet's graph comes from" \
    json_is "${CASE}/out/cargo-vet.run-record.json" '.inputs[] | select(.role == "lockfile") | .path' "${CASE}/work/Cargo.lock"
for table in WORKSPACE PACKAGE; do
    vet_case
    mkdir -p "${CASE}/work/audit-store"
    echo "[cargo-vet]" > "${CASE}/work/audit-store/config.toml"
    run vet.sh PARAM_RUN_RECORD=true "STUB_${table}_METADATA={\"vet\":{\"store\":{\"path\":\"audit-store\"}}}"
    check "records the store ${table,,} metadata sets, which cargo vet reads" \
        json_is "${CASE}/out/cargo-vet.run-record.json" '[.inputs[] | select(.role == "store") | .path] | join(" ")' "${CASE}/work/audit-store/config.toml"
done
vet_case
mkdir -p "${CASE}/work/given"
echo "[cargo-vet]" > "${CASE}/work/given/config.toml"
run vet.sh PARAM_RUN_RECORD=true PARAM_STORE_PATH=given 'STUB_WORKSPACE_METADATA={"vet":{"store":{"path":"audit-store"}}}'
check "store_path wins over metadata, as --store-path does" \
    json_is "${CASE}/out/cargo-vet.run-record.json" '[.inputs[] | select(.role == "store") | .path] | join(" ")' "${CASE}/work/given/config.toml"
vet_case
run vet.sh STUB_VET=fail PARAM_JUNIT=true
check "unvetted crates fail the step" failed
check "naming them" said "unvetted: smallvec 1.6.0, missing safe-to-deploy"
check "JUnit has a failed case for each" file_has "${CASE}/out/junit/cargo-vet.xml" 'classname="cargo-vet.unvetted" name="smallvec 1.6.0"><failure message="missing criteria: safe-to-deploy"'
vet_case
run vet.sh STUB_VET=fail PARAM_REPORT_ONLY=true PARAM_RUN_RECORD=true
check "report_only passes" succeeded
check "the run record says findings-reported" json_is "${CASE}/out/cargo-vet.run-record.json" .outcome findings-reported
vet_case
run vet.sh STUB_VET=error PARAM_REPORT_ONLY=true PARAM_RUN_RECORD=true
check "a cargo vet that can't run fails even with report_only" failed
check "with its error" said "You must run 'cargo vet init'"
check "the run record says error" json_is "${CASE}/out/cargo-vet.run-record.json" .outcome error
vet_case
run vet.sh
run vet.sh STUB_VET=badarg
check "a cargo vet that stops before writing a report fails" failed
check "rather than read the last run's report" said "ERROR: cargo vet did not complete (exit code 2)"
check "with its error" said "unexpected argument"
vet_case
run vet.sh PARAM_FROZEN=true PARAM_MANIFEST_PATH=Cargo.toml PARAM_STORE_PATH=supply-chain "PARAM_FEATURES=a,b" \
    PARAM_NO_DEFAULT_FEATURES=true PARAM_NO_ALL_FEATURES=true PARAM_FILTER_GRAPH='include(name(app))'
check "passes the options after the subcommand, with --locked for frozen" \
    called cargo-vet vet check --manifest-path Cargo.toml --store-path supply-chain --locked --frozen --features "a b" \
    --no-default-features --no-all-features --filter-graph 'include(name(app))' --output-format json --output-file "${CASE}/out/cargo-vet.json"
vet_case
run vet.sh PARAM_EXTRA_ARGS=--output-format=human
check "refuses --output-format in extra_args" failed
vet_case
run vet.sh "PATH=$(path_without cargo)"
check "needs cargo" failed
check "saying so" said "cargo is not on the PATH"

# --- the helpers
begin "helpers"
LIB_TEST() {
    OUTPUT=$(PATH="${STUBS}:${PATH}" bash -c 'set -euo pipefail; eval "${SCRIPT_RUST_SECURITY_LIB}"; '"$1" 2>&1)
    RC=$?
}
# shellcheck disable=SC2016 # expanded by the helpers
LIB_TEST 'rs_list features "a, b,,c  \${X}"; printf "<%s>" "${RS_LIST[@]}"' X=d
check "rs_list splits on commas and spaces" said "<a><b><c>"
# shellcheck disable=SC2016 # expanded by the helpers
OUTPUT=$(X=d PATH="${STUBS}:${PATH}" bash -c 'set -euo pipefail; eval "${SCRIPT_RUST_SECURITY_LIB}"; rs_list features "a \${X}"; printf "<%s>" "${RS_LIST[@]}"' 2>&1)
check "and expands variables" said "<a><d>"
# shellcheck disable=SC2016 # expanded by the helpers' shell
LIB_TEST 'rs_list features "$(printf "a\nb")"'
check "rs_list refuses newlines" failed
LIB_TEST 'rs_output relative/dir name'
check "rs_output refuses a relative output_dir" failed
LIB_TEST "rs_output ${WORK}/o '../x'"
check "rs_output refuses a report_name that is a path" failed
LIB_TEST "rs_output ${WORK}/o 'café'"
check "and one with a letter outside ASCII, in any locale" failed
LIB_TEST 'rs_env_var_name digest_env_var café'
check "rs_env_var_name refuses a name with a letter outside ASCII, in any locale" said "ERROR: digest_env_var must name an environment variable"
LIB_TEST "rs_output ${WORK}/o/ name; echo \"\${RS_BASE}\""
check "rs_output drops a trailing slash" said "${WORK}/o/name"
# shellcheck disable=SC2016 # expanded by the helper
LIB_TEST 'X=/x; unset NOPE; for p in "~/a" "\$X/b" "\${X}c" "\${NOPE:-/d}/e" "\$CARGO_HOME/f" "\${CARGO_HOME}"; do printf "<%s>" "$(HOME=/h; unset CARGO_HOME; rs_expand_path "$p")"; done'
check "rs_expand_path expands db-path as cargo-deny does" said "</h/a></x/b></xc></d/e></h/.cargo/f></h/.cargo>"
# shellcheck disable=SC2016 # expanded by the helper
LIB_TEST 'unset NOPE; rs_expand_path "\$NOPE/x" || echo unset-fails; rs_expand_path "\${bad-name}" || echo malformed-fails; rs_expand_path "\${X" || echo unbalanced-fails'
check "and fails where cargo-deny fails" said "unset-fails"
check "on malformed and unbalanced references too" said "malformed-fails"
check "and unbalanced braces" said "unbalanced-fails"
LIB_TEST 'rs_bool sarif yes'
check "rs_bool refuses anything but true and false" said "ERROR: sarif must be true or false, not 'yes'."
LIB_TEST "rs_words extra_args '--a \"b c\" '\\''d'\\'''; printf '<%s>' \"\${RS_WORDS[@]}\""
check "rs_words splits like the shell, without expanding" said "<--a><b c><d>"
# shellcheck disable=SC2016 # passed to the helpers as text
LIB_TEST 'rs_words extra_args "--a \$(id)"'
check "rs_words refuses \$(...)" said "has a \$(...) or backtick outside quotes"
LIB_TEST "rs_junit ${WORK}/j/empty.xml suite '[]'"
check "rs_junit writes a passing case when there are no findings" file_has "${WORK}/j/empty.xml" 'tests="1" failures="0" skipped="0"'
check "a well-formed one" python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "${WORK}/j/empty.xml"
LIB_TEST "rs_junit ${WORK}/j/odd.xml 'a\"b' '[{\"classname\":\"c\",\"name\":\"<&>\\\"'\\''\",\"status\":\"failed\",\"message\":\"m\",\"detail\":\"x]]>y\"}]'"
check "and escapes what XML needs escaped" python3 -c 'import sys, xml.dom.minidom; d = xml.dom.minidom.parse(sys.argv[1]); assert d.getElementsByTagName("testcase")[0].getAttribute("name") == "<&>\"'"'"'"' "${WORK}/j/odd.xml"

begin "run records follow schemas/run-record.v1.json"
mapfile -t RECORDS < <(find "${WORK}" -name '*.run-record.json' | sort)
check "the tests wrote run records for every command" test "$(for f in "${RECORDS[@]}"; do jq -r .command "${f}"; done | sort -u | tr '\n' ' ')" \
    = "audit audit_bin deny licenses sbom verify_auditable vet "
OUTPUT=$(python3 -I - "${ROOT}/schemas/run-record.v1.json" "${RECORDS[@]}" 2>&1 << 'PY'
import json, sys
try:
    import jsonschema
except ImportError:
    sys.exit("jsonschema is not installed: pip install jsonschema")
schema = json.load(open(sys.argv[1]))
jsonschema.Draft202012Validator.check_schema(schema)
validator = jsonschema.Draft202012Validator(schema)
bad = 0
for path in sys.argv[2:]:
    for error in validator.iter_errors(json.load(open(path))):
        bad += 1
        print(f"{path}: {'/'.join(map(str, error.absolute_path))}: {error.message}")
sys.exit(1 if bad else 0)
PY
)
RC=$?
check "all ${#RECORDS[@]} of them" succeeded

echo
if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed"
    exit 1
fi
echo "ok: every check passed"
