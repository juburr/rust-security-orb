# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb for the Rust security tools: cargo-audit, cargo-deny and cargo-auditable at the core, and cargo-cyclonedx, cargo-vet, rust-audit-info and auditable2cdx on request. It installs each one checksum-verified and wraps them in commands that check lockfiles, dependency graphs and shipped binaries, and write SARIF, JSON, JUnit, SBOMs and run records. It is security-only: building, testing and caching Rust projects is `circleci/rust`'s job. Each tool's own config (`deny.toml`, `.cargo/audit.toml`, `supply-chain/`) is the policy; the orb adds no policy format of its own.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh src/install/*/*.sh tests/*.sh

# Tests (offline; commands_test.sh needs jq and Python's jsonschema)
for t in tests/*_test.sh; do bash "$t" || break; done

# Run one command's script with its YAML defaults (what test-deploy.yml uses for steps that must fail)
bash tests/run_command.sh audit working_dir=tests/fixtures/app no_fetch=true

# Generate SHA-512 checksum table entries for a new release of one tool
./src/install/<tool>/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/`
  - `install.yml` - Installs the tools named in `tools`, through one `install_<tool>` step per tool, each picked by a `when: condition: matches:` on the `tools` string (`^(.*[ ,])?<tool>([ ,].*)?$`). Its first step, `scripts/install_tools.sh`, rejects unknown names, since a misspelled one would otherwise install nothing.
  - `install_<tool>.yml` - One per tool, in the family's standard install command shape: cache key from `scripts/cache_key.sh`, `restore_cache`, the tool's `install/<tool>/install.sh`, `save_cache`. `ORB_NAME` is `rust-security-orb-<tool>`, so each tool has its own cache directory and key.
  - `fetch_advisory_db`, `audit`, `audit_bin`, `deny`, `licenses`, `auditable_build`, `verify_auditable`, `sbom`, `vet` - One script each in `scripts/`.
- `install/<tool>/install.sh` and `install_hash.sh` - Kept outside `scripts/`, because `tests/shell_conventions_test.sh` exempts only `src/scripts/install.sh`, `install_hash.sh` and `cache_key.sh` by exact path, and the shared install code doesn't follow the command scripts' conventions. orb pack ignores the directory; commands include its files with `<< include(install/<tool>/install.sh) >>`.
- `scripts/lib/rust_security.sh` - Helpers shared by the command scripts, passed to each step as `SCRIPT_RUST_SECURITY_LIB: << include(scripts/lib/rust_security.sh) >>` and `eval`ed after a check that it is set. Only defines functions; no `set` line.
- `examples/` - Usage examples, pinned to the orb's current version
- `../schemas/run-record.v1.json` - The run record's JSON Schema. Its URL is in every run record, so fields are only ever added within v1.

### Install scripts (`src/install/<tool>/install.sh`)

Each follows the layout every juburr orb's install.sh shares: a tool definition, the shared install logic (byte-identical across the orbs; never edit it here alone), and the `sha512sums` table keyed `"<version>/<arch>"`. The tool definition starts with a helper block, `# >>> rust-security-orb install helpers >>>` to `# <<< ... <<<`, which must be identical in all seven scripts (`tests/install_test.sh` checks), and then sets the tool's hooks:

- `rs_download_base_url` reads `download_base_url`, an `https://` mirror that replaces `https://github.com` in release URLs.
- `rs_install_prebuilt` (cargo-audit, cargo-deny: `.tar.gz`/`.tgz` members) and `rs_install_tar_xz` (cargo-auditable, cargo-cyclonedx: `.tar.xz`, needs `xz`; the archive itself is hashed, since the shared logic unpacks only `.tar.gz`). Both first run `rs_require_glibc`, which stops before any download when the tool's `tool_glibc ARCH` names a minimum glibc that `getconf GNU_LIBC_VERSION` doesn't meet. The arm64 releases of cargo-audit (2.18) and cargo-cyclonedx (2.34) link glibc; the others are static. Take the minimum from the newest `GLIBC_` symbol version in the binary, for every version in the table.
- `rs_install_crate` (cargo-vet, rust-audit-info, auditable2cdx: no current binaries) verifies the `.crate` from `static.crates.io` against the table's `noarch` entry, then `cargo install --locked --path` on it, with `CARGO_BUILD_TARGET`, `CARGO_TARGET_DIR`, `CARGO_BUILD_TARGET_DIR`, `RUSTFLAGS`, `CARGO_ENCODED_RUSTFLAGS`, `CARGO_BUILD_RUSTFLAGS` and `RUSTC_WORKSPACE_WRAPPER` unset so the job's settings can't change the build. The cache holds the verified archive; the binary is built in every job.
- `rs_install_record METHOD` writes `.<binary>.install.json` beside the binary: version, arch, `prebuilt` or `source-built`, the verified asset and its SHA-512, `verify_checksums`, and the binary's SHA-512. `rs_tool` in the lib warns when the binary a command finds on the `PATH` doesn't match its record, and `rs_run_record` includes the record only when it matches.
- `tool_version` runs the smoke test and must pass the binary's exit code through (the install contract checks it). cargo-auditable, rust-audit-info and auditable2cdx have no version option, so their checks look for known output and return the exit code, or 1 when the text is missing.

`install_hash.sh` is each tool's `verify_upstream` plus the shared install_hash logic, which sources `install.sh` from its own directory. cargo-deny, cargo-auditable and cargo-cyclonedx check the release's `.sha256`; cargo-cyclonedx also runs `gh attestation verify` when `gh` is installed (the current entries were made without it). The crate tools check the SHA-256 in the crates.io sparse index and refuse yanked versions. cargo-audit publishes nothing to check, so its `verify_upstream` always returns 2 and entries need `-c NONE` (checksum-only).

When a tool's default version changes, change it in `install_<tool>.yml` and in `install.yml`'s `<tool>_version`; `tests/wiring_test.sh` fails when they differ.

### Command scripts (`src/scripts/`)

Every reporting command takes `output_dir` (absolute, not expanded, since `store_artifacts` reads it too), `report_name`, `run_record`, `store_artifacts`, and where the tool allows `sarif`, `junit` (stored with `store_test_results` from `output_dir/junit/<report_name>.xml`, the one file, so two commands sharing `output_dir` don't upload each other's results twice) and `report_only`. Store steps run `when: always`. `git -C` searches parent directories, so anything that dates the advisory database checks for its own `.git` first, and a database whose newest commit is dated more than a day in the future fails (it would never look stale). `fetch_advisory_db` takes `https` URLs only, with paths the url crate leaves unchanged (plain ASCII, no `.` or `..` segments) and ports read as numbers (`:0443` is the default port, which the url crate drops), so its directory name is the one cargo-deny computes; the install commands refuse credentials, a query or a fragment in `download_base_url`, and run records drop userinfo, query and fragment from the database's remote URL, since both would reach the log or an artifact. `rs_deny_inputs` finds the config and lockfile cargo-deny reads for the run records of `deny` and `licenses`, and `rs_deny_db` the database, including one in `deny.toml`'s `db-path`, which `rs_expand_path` expands as cargo-deny 0.20 does (`~`, `$NAME`, `${NAME}`, `${NAME:-default}`). Without `db-urls` that is RustSec's directory; with them, `fetch_advisory_db`'s copy counts only when its `origin` is one of those URLs (compared as `rs_url_key` normalizes them), and otherwise the record says `null` rather than name a database cargo-deny didn't read; with several `db-urls` it says `null` too, since a run record names one database. `vet` records the workspace's `Cargo.lock`, which cargo vet's graph comes from, and the store cargo vet reads: `store_path`, or else the root package's `[package.metadata.vet]` or the `[workspace.metadata.vet]` store path (relative to the directory cargo vet runs in), or else `supply-chain` in the workspace root. Report names for binaries (`<report_name>-<binary>`) take the first free `-<n>` suffix.

The rule every gate follows: findings fail the step unless `report_only` is true; a tool that didn't complete always fails it, with an `error` run record when `run_record` is on (a SARIF pass, auditable2cdx and cargo cyclonedx's output included). Each script tells them apart from the tool's report, not its exit code:

- **cargo-audit** exits 1 for findings and failures alike; a complete run writes a JSON object with `vulnerabilities`. `audit` also refuses a report with `lockfile.dependency-count` 0: cargo audit reads any TOML file without a package list (such as `deny.toml`) as an empty lockfile and passes it. Its JSON doesn't say which warnings it denied: the kinds the `deny` parameter names and the `[output] deny` list of the audit.toml it reads (`rs_audit_config` parses it with awk) count as denied (`rs_audit_config` also reads `[database]` `path`, `fetch` and `stale`: `fetch = false` gets the same staleness check as `no_fetch`; it matches keys by their full dotted name, so `database.fetch` is the same setting, and refuses an inline `database` or `output` table, or a multiline or escaped string in those settings, which it can't read), and when cargo audit exits non-zero with no vulnerabilities and none of those kinds, a config the parser missed must have denied them, so every warning counts as denied (`RS_AUDIT_DENIED_JQ`). `rs_audit_check` fails a run that exits non-zero reporting nothing, and one whose yanked check couldn't reach the crates.io index (cargo-audit 0.22.2 then only logs "couldn't check if the package is yanked" and exits 0) when `deny` covers yanked crates; otherwise it warns.
- **cargo-deny**'s exit code is a bitmask of the checks with errors (advisories 1, bans 2, licenses 4, sources 8). A completed run ends its JSON stream on stderr with a `{"type":"summary"}` line. Its SARIF output exits 0 whatever it finds, so `deny` writes SARIF in a second pass with `--offline` after the JSON pass decided. Options it shares with `list` go before `check` (cargo-deny 0.20). A `--config` that doesn't exist falls back to the default config, which allows no licence, so `deny` and `licenses` check the path first. `-L info` makes it report each `advisory-ignored`/`yanked-ignored` it applied, with an `ignore reason` label when the entry has a reason, which is what `require_ignore_reasons` reads. 0.20 has no `--disable-fetch`: only `--offline` stops its database fetch, and it also stops cargo metadata's downloads and the fetch of `std-replacement-data` from github.com.
- **cargo-vet** exits 255 for both; its JSON report has `conclusion` when vetting ran and `error` when it couldn't. It writes no report when it stops at argument parsing (exit 2), so `vet` deletes the old one first. It needs `CARGO` set (cargo sets it when run as `cargo vet`), takes its options after the subcommand, and `--frozen` needs `--locked`.

Per script:

- **`fetch_advisory_db.sh`** clones the database shallowly (`git clone --depth 1`), or imports a directory or `.tar.gz`, validates it (`crates/`, advisories, git history, and files exactly the commit's, by `git status` with untracked and ignored files, since run records name the commit), and swaps it into `$CARGO_HOME/advisory-dbs/<last URL path segment>-<hash>` atomically. The hash is cargo-deny's: XXH64 with seed `0xca80de71` of the lowercased canonical URL, `%016x`; `rs_xxh64` implements it in bash (the RustSec default is `advisory-db-3157b0e258782691`). It removes `.git/FETCH_HEAD` and sets `.git/HEAD`'s mtime to the newest commit's time, since cargo-deny dates the database by those files, so both tools date it by its newest commit. A private mirror's `Authorization` header reaches git through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0`, never the command line. Exports `RUSTSEC_ADVISORY_DB`.
- **`audit.sh` / `audit_bin.sh`** share `rs_audit_options` (database, `no_fetch`, staleness, `deny`, targets, `no_yanked`). cargo-audit checks a database's age only when it fetches, so with `no_fetch` `rs_db_fresh` applies its 90-day rule. `audit_bin` audits one binary per cargo audit call (its JSON doesn't say which binary a finding came from), lets only the first call fetch, names reports apart when two binaries share a name, and with `require_auditable` reads each binary with rust-audit-info first. cargo-audit has no config flag (`-c` is colour); it reads `.cargo/audit.toml` in the working directory or `$CARGO_HOME/audit.toml`. `--json` overrides `--format`, and a repeated `--no-fetch` is an error. `rs_audit_extra_args` refuses `--no-fetch` and `--db` in `extra_args`, also inside grouped short options such as `-qn`, since the staleness check and the run record follow the `no_fetch` and `db_path` parameters.
- **`licenses.sh`** runs `cargo deny list --layout <crate|license> --format <json|tsv>`.
- **`auditable_build.sh`** runs `cargo auditable <build|install|rustc>` with `extra_args`, and warns when cargo would run a `cargo-auditable` from `$CARGO_HOME/bin` (cargo searches it first when it isn't on the `PATH`) instead of the verified one. The `.dep-v0` section survives GNU `strip`, not `llvm-strip` or `--strip-section-headers`.
- **`verify_auditable.sh`** decodes each binary with rust-audit-info, optionally converts with auditable2cdx (CycloneDX 1.3), and fails after checking them all.
- **`sbom.sh`**: cargo cyclonedx writes each SBOM beside its member's `Cargo.toml`, has no output option and no `--locked`, rewrites an out-of-date lockfile, and lets `CARGO_BUILD_TARGET` override `--target`. So the script checks `cargo metadata --locked` first, refuses `--manifest-path` in `extra_args`, runs it with `CARGO_BUILD_TARGET` unset when `target` is set (and `CARGO_NET_OFFLINE` for `offline`), and moves the files newer than a marker into `output_dir/<report_name>/<path in the workspace>`. JSON SBOMs are checked with jq; XML ones, without a parser the orb could require, by a CycloneDX `bom` root element and a closing `</bom>`.
- **`vet.sh`** runs the verified binary as `cargo-vet vet check ... --output-format json --output-file`, with `CARGO` set, and refuses `--store-path` and `--manifest-path` in `extra_args`, since the run record follows the parameters.

### Shared helpers (`scripts/lib/rust_security.sh`)

- `rs_subst` expands environment variables by piping the value to `circleci env subst` on stdin, and uses the value as is without the CLI. `rs_list` substitutes and splits on commas and spaces; `rs_words` splits `extra_args` with `split_shell_words` (the same parser container-ops-orb, oras-orb, crane-orb and skopeo-orb use), refusing `$(...)`, backticks and shell operators outside quotes.
- `rs_bool`, `rs_env_var_name`, `rs_export` (`printf 'export %s=%q\n'` to `$BASH_ENV`), `rs_tool` (and `rs_tool_verified NAME PATH`, its install-record check, for binaries a command runs besides its tool), `rs_require_jq`, `rs_output` (absolute `output_dir`, a `report_name` that is a plain file name), `rs_sha256`.
- `rs_match VALUE REGEX` is `[[ VALUE =~ REGEX ]]` in the C locale. Bash's `=~` follows the locale, and in `en_US.UTF-8`, which the cimg images set in `LANG` and `LC_ALL`, a range such as `[a-z]` also matches letters such as `é`. So every check of user input with a range uses `rs_match`.
- `rs_json_is FILE FILTER [JQ_OPTION...]` checks a report. The scripts must work with jq 1.6, which `cimg/python` (the `test-commands` image) and Ubuntu 22.04 ship, and where `jq -e` exits 0 on an empty file and takes its status from the last input (so a `select` over JSONL fails unless the last line matches); raw slurped input also loses a trailing NUL. So never use `jq -e` on a tool's output in the scripts; in `test-deploy.yml`, slurp JSONL (`jq -s -e 'any(.[]; ...)'`).
- `rs_junit FILE SUITE CASES_JSON` writes JUnit from `{classname, name, status: passed|failed|skipped, message, detail}` cases, escaping with jq's `@html`, with one passing case when there are none.
- `rs_gate FINDINGS REPORT_ONLY SUMMARY` ends the step.
- `rs_run_record FILE COMMAND OUTCOME EXIT_CODE STARTED` writes the run record from `RS_TOOL`, `RS_TOOL_VERSION`, `RS_OTHER_TOOLS` (other binaries the command ran: auditable2cdx, and rust-audit-info for `audit_bin`), `RS_ARGS` (passed to jq NUL-separated, so arguments starting with `-` never reach jq's option parsing), `RS_INPUTS` (`role:path`; `rs_manifest_inputs` adds the workspace's `Cargo.toml` files from `cargo metadata --no-deps`, for `sbom`, `vet`, and `deny`/`licenses` without `metadata_path`), `RS_REPORTS`, `RS_DB` and `RS_COUNTS`. A run record that can't be written is a warning, never a failure. Keep `schemas/run-record.v1.json` in step with it; `tests/commands_test.sh` validates every run record it writes.

### CI Pipeline (`.circleci/`)

- `config.yml` - Setup workflow: `test-install` (`tests/install_test.sh`: the shared install contract, a copy of `tests/install_contract.sh`, run once per tool against fixtures from `tests/install_fixtures/`), `test-env-subst` (env subst and shell conventions), `test-commands` (`tests/commands_test.sh` against stand-ins for every tool, then `tests/wiring_test.sh`, on `cimg/python` for jsonschema), orb-tools lint, pack and review (`orb_name: rust-security`), shellcheck.
- `test-deploy.yml` - Runs against the fixture workspace in `tests/fixtures/app`: its default feature links smallvec 1.6.0 (RUSTSEC-2021-0003), its `backend-a`/`backend-b` features must never be combined (`deny-backend-<x>.toml` bans the other), and it has a `supply-chain/` store that passes cargo vet and a `supply-chain-unvetted/` one that doesn't. Jobs: `install-test` (every tool on amd64, install records, a second install from the cache), `checksum-test` (unlisted cargo-deny 0.19.4 and rust-audit-info 0.5.3 fail closed; `known_versions`; a local HTTPS mirror serving the real cargo-deny release, then a tampered one), `arm64-test` (every tool on an Arm Docker executor), `detection-test`, `auditable-test`, `bans-test` (a matrix over the backends), `offline-test` (a machine executor with no Rust, `github.com` and crates.io blocked in `/etc/hosts`, the database archive and `cargo metadata` from `detection-test` and the binaries from `auditable-test`, and a stale database), `supply-chain-test` (vet and sbom), and `reports-test` (every SARIF file against the OASIS SARIF 2.1.0 schema, pinned by SHA-256, plus JUnit, run records and CycloneDX, with `tests/validate_reports.py`). Steps that must fail run through `tests/run_command.sh`. Publishing runs on `v*` tags.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline; the fixture fragments in `tests/install_fixtures/` carry a `# shellcheck shell=bash` directive.

Scripts pass parameter values to `circleci env subst` on stdin, as `rs_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them (`tests/run_command.sh` sets them from the YAML).
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. Bash 4.0 also treats an empty `"$@"` as unbound, even inside `${@+"$@"}`, so the test runners copy `"$@"` into an array only when `$#` is non-zero. `tests/commands_test.sh` passes with bash 4.0, 4.3 and 5 first on the `PATH`; the shared install contract needs 4.3.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_RUST_SECURITY_LIB}"`). Secrets never go on a command line, and curl that sends credentials or fetches trusted content uses `--fail` and `--proto '=https'`.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script (a second `trap ... EXIT` replaces the first).

## Naming

Command names say what they check (`audit`, `deny`, `vet`) or make (`sbom`, `licenses`, `auditable_build`), in snake_case. Parameters that map onto one tool flag take its long name in snake_case (`no_fetch`, `no_yanked`, `metadata_path`, `exclude_dev`, `filter_graph`); where tools disagree, the parameter keeps the flag of the tool the command runs (`offline` for cargo-deny, `no_fetch` for cargo-audit). Plumbing matches the other juburr orbs: variables a command reads are `<thing>_env_var`, pass-through arguments are `extra_args`, and lists take commas or spaces.

## Not yet included

`unsafe_report` (cargo-geiger: experimental, counts vary with features and targets, needs Rust 1.97+ and OpenSSL to build, and runs `cargo clean`), `summarize`, a signed database bundle (the `archive` plus cosign-orb covers it), and macOS executors. The README's "Not Yet Included" section says why; keep it current.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh src/install/*/*.sh tests/*.sh` to lint shell scripts
- Run every `tests/*_test.sh`, also under `LC_ALL=en_US.UTF-8` (as CI does) when the system has that locale
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml` to validate the orb structure
- For changes to a command, also run it with the real tools against `tests/fixtures/app` through `tests/run_command.sh`, as `test-deploy.yml` does
