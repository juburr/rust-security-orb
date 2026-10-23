# shellcheck shell=bash disable=SC2034 # a fragment: the install contract it is spliced into reads these
# Built from the crate's source archive. The checksum table covers the
# archive, and a stand-in cargo "builds" it by copying the stand-in binary the
# archive holds. On top of the shared contract: the build runs cargo install
# --locked on the unpacked archive, and fails clearly without cargo, without a
# Cargo.lock, or when the build fails.
FIXTURE_CRATE_LOCKFILE=1

fixture_make_asset() {
    local dir="${WORK}/crate.$$.${RANDOM}" pkg="${TOOL_NAME}-$1"
    mkdir -p "${dir}/${pkg}"
    printf '[package]\nname = "%s"\nversion = "%s"\n' "${TOOL_NAME}" "$1" > "${dir}/${pkg}/Cargo.toml"
    if [[ "${FIXTURE_CRATE_LOCKFILE}" == 1 ]]; then
        printf '# stand-in lockfile\n' > "${dir}/${pkg}/Cargo.lock"
    fi
    cp "$4" "${dir}/${pkg}/stand-in-binary"
    tar -czf "$3" -C "${dir}" "${pkg}"
    rm -rf "${dir}"
    printf '%s\n' "$3"
}

fixture_setup() {
    cat > "$1/cargo" << 'STUB'
#!/bin/bash
# Stand-in cargo: "install --locked --path DIR --root ROOT ..." copies
# DIR/stand-in-binary to ROOT/bin/$ORB_TEST_BINARY. Calls go to CARGO_LOG.
printf '%s\n' "$*" >> "${CARGO_LOG:-/dev/null}"
case "$1" in
    --version) echo "cargo 1.99.0 (stand-in)"; exit 0 ;;
    install) ;;
    *) echo "stand-in cargo: unexpected arguments: $*" >&2; exit 2 ;;
esac
if [[ -n "${ORB_TEST_CARGO_FAIL:-}" ]]; then
    echo "error: could not compile the stand-in" >&2
    exit 101
fi
path="" root=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --path) path=$2; shift ;;
        --root) root=$2; shift ;;
    esac
    shift
done
mkdir -p "${root}/bin" && cp "${path}/stand-in-binary" "${root}/bin/${ORB_TEST_BINARY}" && chmod +x "${root}/bin/${ORB_TEST_BINARY}"
STUB
    chmod +x "$1/cargo"
}

fixture_env() {
    printf 'ORB_TEST_BINARY=%s\n' "${TOOL_BINARY}"
    printf 'CARGO_LOG=%s/cargo.log\n' "$1"
}

fixture_checks() {
    begin "${TOOL_NAME}: building the verified source archive"
    new_case
    run_install
    check "succeeds" succeeded
    check "says it builds from source" said "Building ${TOOL_NAME} ${LISTED} from source with cargo 1.99.0 (stand-in)"
    check "runs cargo install --locked on the unpacked archive" \
        grep -qE -- "^install --locked --path .*/crate/${TOOL_NAME}-${LISTED} --root " "${CASE}/cargo.log"
    OUTPUT=$(cat "${CASE}/bin/.${TOOL_BINARY}.install.json" 2>&1)
    check "records a source-built install beside the binary" said '"method":"source-built"'
    new_case
    run_install ORB_TEST_CARGO_FAIL=1
    check "a failed build fails" failed
    check "saying so" said "Could not build ${TOOL_NAME} ${LISTED}"
    check "with the end of cargo's output" said "could not compile the stand-in"
    check "and installs nothing" not_installed
    new_case
    run_install "PATH=$(path_without cargo)"
    check "fails without cargo" failed
    check "saying it needs cargo" said "needs cargo"
    check "before downloading anything" no_downloads
    FIXTURE_CRATE_LOCKFILE=0
    fixture_make_asset "${UNLISTED}" noarch "$(served_file "${UNLISTED}" noarch)" "${WORK}/good-noarch" > /dev/null
    FIXTURE_CRATE_LOCKFILE=1
    new_case
    run_install "PARAM_VERSION=${UNLISTED}" PARAM_VERIFY_CHECKSUMS=known_versions
    check "refuses a source archive without a Cargo.lock" failed
    check "saying its dependencies can't be pinned" said "has no Cargo.lock"
    check "and installs nothing" not_installed
}
