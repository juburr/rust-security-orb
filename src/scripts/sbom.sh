#!/bin/bash
#
# Writes CycloneDX SBOMs from Cargo's metadata with cargo cyclonedx, for the
# sbom command. cargo cyclonedx writes one SBOM beside each workspace
# member's Cargo.toml, and has no option to write them anywhere else, so this
# script moves the ones it wrote into output_dir, keeping their paths
# relative to the workspace root.
#
# cargo cyclonedx runs cargo metadata without --locked, which rewrites a
# Cargo.lock that is out of date, so the SBOM could describe versions the
# committed lockfile doesn't pin. With locked (the default) the lockfile is
# checked first, and an out-of-date one fails the step instead.

set -euo pipefail

if [[ -z "${SCRIPT_RUST_SECURITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_RUST_SECURITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_RUST_SECURITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST_PATH=$(rs_subst "${PARAM_MANIFEST_PATH}")
TARGET=$(rs_subst "${PARAM_TARGET}")
FORMAT=${PARAM_FORMAT}
SPEC_VERSION=${PARAM_SPEC_VERSION}
DESCRIBE=${PARAM_DESCRIBE}
ALL_FEATURES=$(rs_bool all_features "${PARAM_ALL_FEATURES}")
NO_DEFAULT_FEATURES=$(rs_bool no_default_features "${PARAM_NO_DEFAULT_FEATURES}")
TOP_LEVEL=$(rs_bool top_level "${PARAM_TOP_LEVEL}")
OFFLINE=$(rs_bool offline "${PARAM_OFFLINE}")
LOCKED=$(rs_bool locked "${PARAM_LOCKED}")
RUN_RECORD=$(rs_bool run_record "${PARAM_RUN_RECORD}")
EXTRA_ARGS=$(rs_subst "${PARAM_EXTRA_ARGS}")
rs_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${RS_WORDS[@]+"${RS_WORDS[@]}"})
rs_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rs_require_jq
rs_tool cargo-cyclonedx
RS_TOOL_VERSION=$("${RS_TOOL}" cyclonedx --version 2> /dev/null || true)
if ! CARGO=$(command -v cargo); then
    echo "ERROR: cargo is not on the PATH, and cargo cyclonedx needs it. Use a Rust image such as cimg/rust." >&2
    exit 1
fi
# cargo cyclonedx asks rustc for the host target, and panics without it.
if [[ -z "${RUSTC:-}" ]] && ! command -v rustc > /dev/null 2>&1; then
    echo "ERROR: rustc is not on the PATH, and cargo cyclonedx needs it. Use a Rust image such as cimg/rust." >&2
    exit 1
fi
case "${FORMAT}" in
    json | xml) ;;
    *)
        echo "ERROR: format must be json or xml, not '${FORMAT}'." >&2
        exit 1
        ;;
esac
case "${SPEC_VERSION}" in
    1.3 | 1.4 | 1.5) ;;
    *)
        echo "ERROR: spec_version must be 1.3, 1.4 or 1.5, not '${SPEC_VERSION}'." >&2
        exit 1
        ;;
esac
case "${DESCRIBE}" in
    crate | binaries | all-cargo-targets) ;;
    *)
        echo "ERROR: describe must be crate, binaries or all-cargo-targets, not '${DESCRIBE}'." >&2
        exit 1
        ;;
esac
for word in ${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"}; do
    case "${word}" in
        -f | --format | --format=* | --spec-version | --spec-version=* | --override-filename | --override-filename=* \
            | --manifest-path | --manifest-path=*)
            echo "ERROR: extra_args can't set ${word}: use this command's parameters, which it needs to find the SBOMs." >&2
            exit 1
            ;;
    esac
done

CARGO_ARGS=()
if [[ -n "${MANIFEST_PATH}" ]]; then
    CARGO_ARGS+=(--manifest-path "${MANIFEST_PATH}")
fi
if [[ "${OFFLINE}" == true ]]; then
    CARGO_ARGS+=(--offline)
fi
RS_ARGS=(cyclonedx --format "${FORMAT}" --spec-version "${SPEC_VERSION}" --describe "${DESCRIBE}")
if [[ -n "${MANIFEST_PATH}" ]]; then
    RS_ARGS+=(--manifest-path "${MANIFEST_PATH}")
fi
rs_list features "${PARAM_FEATURES}"
if [[ ${#RS_LIST[@]} -gt 0 ]]; then
    RS_ARGS+=(--features "$(IFS=,; printf '%s' "${RS_LIST[*]}")")
fi
if [[ "${ALL_FEATURES}" == true ]]; then
    RS_ARGS+=(--all-features)
fi
if [[ "${NO_DEFAULT_FEATURES}" == true ]]; then
    RS_ARGS+=(--no-default-features)
fi
ENV_ARGS=(env)
if [[ -n "${TARGET}" ]]; then
    RS_ARGS+=(--target "${TARGET}")
    # cargo cyclonedx lets CARGO_BUILD_TARGET override --target.
    ENV_ARGS+=(-u CARGO_BUILD_TARGET)
fi
if [[ "${TOP_LEVEL}" == true ]]; then
    RS_ARGS+=(--top-level)
fi
if [[ "${OFFLINE}" == true ]]; then
    # cargo cyclonedx has no --offline; cargo honours this instead.
    ENV_ARGS+=(CARGO_NET_OFFLINE=true)
fi
RS_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})

# The workspace members, whose directories cargo cyclonedx writes into.
if ! METADATA=$("${CARGO}" metadata --no-deps --format-version 1 ${CARGO_ARGS[@]+"${CARGO_ARGS[@]}"} 2> "${RS_BASE}.log"); then
    echo "ERROR: cargo metadata failed:" >&2
    sed 's/^/  /' "${RS_BASE}.log" | tail -n 20 >&2
    exit 1
fi
ROOT=$(jq -r '.workspace_root' <<< "${METADATA}")
mapfile -t MEMBER_DIRS < <(jq -r '.workspace_members as $m | .packages[] | select(.id as $id | $m | index($id)) | .manifest_path' <<< "${METADATA}" | sed 's|/[^/]*$||')
RS_INPUTS=()
if [[ -f "${ROOT}/Cargo.lock" ]]; then
    RS_INPUTS+=("lockfile:${ROOT}/Cargo.lock")
fi
rs_manifest_inputs "${METADATA}"
if [[ "${LOCKED}" == true ]]; then
    if ! "${CARGO}" metadata --format-version 1 --locked ${CARGO_ARGS[@]+"${CARGO_ARGS[@]}"} > /dev/null 2> "${RS_BASE}.log"; then
        echo "ERROR: Cargo.lock is missing or out of date, so the SBOM would not describe the versions it pins. cargo says:" >&2
        sed 's/^/  /' "${RS_BASE}.log" | tail -n 20 >&2
        echo "  Commit an up-to-date Cargo.lock, or set locked to false to let cargo update it." >&2
        exit 1
    fi
fi

# Files cargo cyclonedx writes from now on are newer than this marker (made a
# second early for file systems that keep whole seconds).
MARKER="${RS_BASE}.marker"
touch -d "@$(($(date +%s) - 1))" "${MARKER}"
echo "Writing CycloneDX ${SPEC_VERSION} SBOMs (${DESCRIBE}) with ${RS_TOOL_VERSION:-cargo-cyclonedx}..."
RC=0
"${ENV_ARGS[@]}" "${RS_TOOL}" "${RS_ARGS[@]}" > "${RS_BASE}.log" 2>&1 || RC=$?
RS_REPORTS=()
if [[ "${RC}" -ne 0 ]]; then
    rm -f "${MARKER}"
    echo "ERROR: cargo cyclonedx failed (exit code ${RC}). Its output:" >&2
    sed 's/^/  /' "${RS_BASE}.log" | tail -n 40 >&2
    if [[ "${RUN_RECORD}" == true ]]; then
        RS_REPORTS+=("${RS_BASE}.log")
        rs_run_record "${RS_BASE}.run-record.json" sbom error "${RC}" "${STARTED}"
    fi
    exit 1
fi

DEST="${RS_OUT%/}/${PARAM_REPORT_NAME}"
# cdx_xml FILE: whether FILE looks like a whole CycloneDX XML document: after
# its XML declaration and any comments, a bom element in the CycloneDX
# namespace, and </bom> at the end. Without an XML parser, which the orb
# doesn't require, this is the check that catches output cut short or that
# isn't an SBOM.
cdx_xml() {
    local start end
    start=$(head -c 65536 -- "$1" 2> /dev/null) || return 1
    while true; do
        start=${start#"${start%%[![:space:]]*}"}
        case "${start}" in
            '<?'*'?>'*) start=${start#*'?>'} ;;
            '<!--'*'-->'*) start=${start#*'-->'} ;;
            *) break ;;
        esac
    done
    end=$(tail -c 1024 -- "$1" 2> /dev/null) || return 1
    rs_match "${start}" '^<bom[[:space:]][^>]*xmlns="http://cyclonedx\.org/schema/bom/1\.[0-9]+"' \
        && rs_match "${end}" '</bom>[[:space:]]*$'
}

# sbom_error [FILE]: stops the step for output cargo cyclonedx should not
# have written, with an error run record that lists FILE too.
sbom_error() {
    if [[ "${RUN_RECORD}" == true ]]; then
        if [[ $# -gt 0 ]]; then
            RS_REPORTS+=("$1")
        fi
        rs_run_record "${RS_BASE}.run-record.json" sbom error "${RC}" "${STARTED}"
    fi
    exit 1
}
SUMMARY="[]"
for dir in "${MEMBER_DIRS[@]}"; do
    while IFS= read -r -d '' file; do
        relative=${file#"${ROOT%/}/"}
        mkdir -p "$(dirname "${DEST}/${relative}")"
        mv -f "${file}" "${DEST}/${relative}"
        file="${DEST}/${relative}"
        if [[ "${FORMAT}" == json ]]; then
            if ! rs_json_is "${file}" '.bomFormat == "CycloneDX"'; then
                echo "ERROR: ${relative} is not a CycloneDX JSON document." >&2
                sbom_error "${file}"
            fi
            SUMMARY=$(jq -c --arg file "${relative}" --argjson components "$(jq '.components | length' "${file}")" \
                '. + [{file: $file, components: $components}]' <<< "${SUMMARY}")
        else
            if ! cdx_xml "${file}"; then
                echo "ERROR: ${relative} is not a CycloneDX XML document." >&2
                sbom_error "${file}"
            fi
            SUMMARY=$(jq -c --arg file "${relative}" '. + [{file: $file}]' <<< "${SUMMARY}")
        fi
        RS_REPORTS+=("${file}")
    # cargo cyclonedx names every SBOM <name>.cdx.<format>, so a project file
    # written meanwhile, such as a package.json, is never taken for one.
    done < <(find "${dir}" -maxdepth 1 -type f -newer "${MARKER}" -name "*.cdx.${FORMAT}" -print0)
done
rm -f "${MARKER}" "${RS_BASE}.log"
if [[ ${#RS_REPORTS[@]} -eq 0 ]]; then
    echo "ERROR: cargo cyclonedx wrote no SBOM beside any workspace member's Cargo.toml." >&2
    sbom_error
fi
# shellcheck disable=SC2034 # read by rs_run_record
RS_COUNTS=$(jq -c '{sboms: length}' <<< "${SUMMARY}")
jq -r '.[] | "  \(.file)\(if .components then ": \(.components) components" else "" end)"' <<< "${SUMMARY}"
if [[ "${RUN_RECORD}" == true ]]; then
    rs_run_record "${RS_BASE}.run-record.json" sbom passed 0 "${STARTED}"
fi
echo "Wrote ${#RS_REPORTS[@]} SBOMs to ${DEST}."
