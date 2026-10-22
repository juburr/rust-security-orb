# shellcheck shell=bash disable=SC2034 # a fragment: the install contract it is spliced into reads these
# Release binaries downloaded from GitHub (cargo-audit, cargo-deny,
# cargo-auditable, cargo-cyclonedx). On top of the shared contract, the
# download_base_url mirror: it replaces https://github.com in the release URL,
# and what it serves is verified like any download. Then the install record,
# and the glibc an arm64 release that links it needs.
fixture_checks() {
    local mirror="https://mirror.example/artifactory/github" mirror_url listed_file tampered_file
    begin "${TOOL_NAME}: download_base_url"
    # The mirror serves exactly the files served for GitHub (an archive made
    # again would differ in its timestamps).
    listed_file=$(served_file "${LISTED}" "${DEFAULT_ARCH}")
    tampered_file=$(served_file "${TAMPERED}" "${DEFAULT_ARCH}")
    RS_DOWNLOAD_BASE_URL=${mirror}
    cp "${listed_file}" "$(served_file "${LISTED}" "${DEFAULT_ARCH}")"
    cp "${tampered_file}" "$(served_file "${TAMPERED}" "${DEFAULT_ARCH}")"
    mirror_url=$(url "${LISTED}" "${DEFAULT_ARCH}")
    unset RS_DOWNLOAD_BASE_URL
    OUTPUT="mirror URL: ${mirror_url}"
    check "the mirror URL is the GitHub release URL with the mirror in place of https://github.com" \
        test "${mirror_url#"${mirror}"}" = "$(url "${LISTED}" "${DEFAULT_ARCH}" | sed 's|^https://github.com||')"
    new_case
    run_install "PARAM_DOWNLOAD_BASE_URL=${mirror}/"
    check "installs from the mirror" installed
    check "downloads from the mirror alone" downloaded "${mirror_url}"
    check "once" download_count 1
    check "says which mirror it uses" said "download mirror:  ${mirror}"
    new_case
    # shellcheck disable=SC2016 # expanded by install.sh
    run_install 'PARAM_DOWNLOAD_BASE_URL=${ORB_TEST_MIRROR}' "ORB_TEST_MIRROR=${mirror}"
    check "expands environment variables in it" installed
    for mode in strict known_versions; do
        new_case
        run_install "PARAM_DOWNLOAD_BASE_URL=${mirror}" "PARAM_VERSION=${TAMPERED}" "PARAM_VERIFY_CHECKSUMS=${mode}"
        check "${mode}: refuses a tampered asset from the mirror" failed
        check "${mode}: reporting the mismatch" said "Checksum verification failed."
        check "${mode}: and installs nothing" not_installed
    done
    for value in "http://mirror.example" "mirror.example" "https://mirror example"; do
        new_case
        run_install "PARAM_DOWNLOAD_BASE_URL=${value}"
        check "refuses '${value}'" failed
        check "saying it must be an https URL" said "download_base_url must be an https:// URL"
        check "before downloading anything" no_downloads
    done
    new_case
    run_install "PARAM_DOWNLOAD_BASE_URL=http://user:s3cret@mirror.example/github"
    check "refuses credentials in the URL" failed
    check "saying they would show in the log" said "download_base_url must not hold credentials"
    check "without printing them" not_said "s3cret"
    check "before downloading anything" no_downloads
    begin "${TOOL_NAME}: install record"
    new_case
    run_install
    OUTPUT=$(cat "${CASE}/bin/.${TOOL_BINARY}.install.json" 2>&1)
    check "records a prebuilt install beside the binary" said '"method":"prebuilt"'
    check "with the version and the verified checksum" said "\"version\":\"${LISTED}\""
    check "and the installed binary's SHA-512" said "\"binary_sha512\":\"$(sha512sum "${CASE}/bin/${TOOL_BINARY}" | awk '{ print $1 }')\""
    # A tool whose arm64 release links glibc (tool_glibc) is refused on an
    # arm64 system without a glibc that new, before anything is downloaded.
    if declare -F tool_glibc > /dev/null && [[ -n "$(tool_glibc arm64)" ]]; then
        begin "${TOOL_NAME}: glibc for the arm64 release"
        mkdir -p "${WORK}/getconf-musl" "${WORK}/getconf-old"
        printf '#!/bin/sh\necho "getconf: GNU_LIBC_VERSION: unknown variable" >&2\nexit 1\n' > "${WORK}/getconf-musl/getconf"
        printf '#!/bin/sh\necho "glibc 2.17"\n' > "${WORK}/getconf-old/getconf"
        chmod +x "${WORK}/getconf-musl/getconf" "${WORK}/getconf-old/getconf"
        new_case
        run_install FAKE_ARCH=aarch64 "PATH=${WORK}/getconf-musl:${STUBS}:${PATH}"
        check "refuses a system without glibc, such as Alpine" failed
        check "saying what the release needs" said "${TOOL_NAME}'s arm64 release needs glibc $(tool_glibc arm64) or newer, and this system has none"
        check "before downloading anything" no_downloads
        new_case
        run_install FAKE_ARCH=aarch64 "PATH=${WORK}/getconf-old:${STUBS}:${PATH}"
        check "refuses an older glibc" failed
        check "naming it" said "this system has glibc 2.17."
        check "before downloading anything" no_downloads
        new_case
        run_install FAKE_ARCH=x86_64 "PATH=${WORK}/getconf-musl:${STUBS}:${PATH}"
        check "installs the static amd64 release without glibc" installed
    fi
}
