# The release is a .tar.xz archive, which the shared install logic doesn't
# unpack: the checksum table covers the archive as a whole, and the tool
# definition unpacks it after verifying it.
fixture_make_asset() {
    local dir member
    member="${TOOL_BINARY}-$(tool_target "$2")/${TOOL_BINARY}"
    dir=$(mktemp -d "${WORK}/asset.XXXXXX")
    mkdir -p "${dir}/${member%/*}"
    cp "$4" "${dir}/${member}"
    chmod 0755 "${dir}/${member}"
    tar -cJf "$3" -C "${dir}" "${member}"
    printf '%s\n' "$3"
}
