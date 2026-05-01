#!/usr/bin/env bash
# measure_app_size.sh — measure per-device APK download size with bundletool.
#
# The release AAB is much larger than what Play actually serves to a device,
# because Play splits it by ABI / density / language at install time. The
# `Measure AAB size` step in release.yml catches catastrophic regressions of
# the bundle on disk, but the number a user sees in the Play Store listing
# (and the number issue #131 budgets against — "target < 30 MB AAB download")
# is the per-device combined download. That number can only be obtained by
# replaying Play's split logic with bundletool.
#
# This script downloads bundletool, generates the per-device APK splits, asks
# bundletool for the min/max combined download across every covered device
# spec, and emits a soft warning if the max exceeds the issue's 30 MiB target
# or fails the build if it exceeds the hard ceiling.
#
# Required env vars:
#   AAB_PATH            path to the signed release .aab
#   KEYSTORE_PATH       keystore for build-apks signing (matches the AAB)
#   KEYSTORE_PASSWORD   keystore password
#   KEY_ALIAS           key alias
#   KEY_PASSWORD        key password
#
# Optional env vars:
#   BUNDLETOOL_VERSION    bundletool release tag (default 1.18.3)
#   BUNDLETOOL_SHA256     SHA-256 of bundletool-all-${VERSION}.jar
#                         (default: pinned for 1.18.3)
#   DOWNLOAD_TARGET_MIB   soft warning threshold (default 30; matches #131)
#   DOWNLOAD_CEILING_MIB  hard failure threshold (default 50)
#   WORK_DIR              workspace for the JAR + .apks output
#                         (default: $(mktemp -d))
#   GITHUB_STEP_SUMMARY   GitHub-Actions summary file (optional)

set -euo pipefail

BUNDLETOOL_VERSION="${BUNDLETOOL_VERSION:-1.18.3}"
# BUNDLETOOL_VERSION feeds both the GitHub release URL and the on-disk cache
# filename, so a malformed override (path separators, ../) could redirect
# either. Pin to the tag shape Google actually publishes (digits-and-dots,
# optionally with -alpha/-rc-style suffixes) before any interpolation.
if ! [[ "$BUNDLETOOL_VERSION" =~ ^[0-9]+(\.[0-9]+)*(-[A-Za-z0-9.]+)?$ ]]; then
  echo "Error: BUNDLETOOL_VERSION must look like a release tag (e.g. 1.18.3), got: '$BUNDLETOOL_VERSION'" >&2
  exit 1
fi
# Default SHA pins bundletool 1.18.3 (verified against the JAR Google publishes
# at github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar).
# Bump in lockstep with BUNDLETOOL_VERSION — a tag retarget on Google's release
# would otherwise hand a swapped binary our keystore for build-apks signing.
BUNDLETOOL_SHA256="${BUNDLETOOL_SHA256:-a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29}"
DOWNLOAD_TARGET_MIB="${DOWNLOAD_TARGET_MIB:-30}"
DOWNLOAD_CEILING_MIB="${DOWNLOAD_CEILING_MIB:-50}"

# Auto-clean an internally-allocated WORK_DIR so repeated local invocations
# don't pile up old bundletool jars under /tmp. A caller-supplied WORK_DIR is
# left alone — CI passes ${{ runner.temp }}/bundletool to keep the JAR cached
# across steps in the same job.
if [ -z "${WORK_DIR:-}" ]; then
  WORK_DIR=$(mktemp -d)
  CLEANUP_WORK_DIR=true
else
  CLEANUP_WORK_DIR=false
fi

# Sensitive scratch dir for keystore/key password files. Always private to the
# current run and always cleaned up — see the build-apks invocation for why
# passwords go to disk instead of the command line.
PASS_DIR=$(mktemp -d)
# Path to a partial bundletool download; assigned by the download block below
# and emptied once the .jar is renamed into place. The cleanup trap removes
# whatever it points at so an interrupted run doesn't leave a half-downloaded
# .tmp behind.
TMP_JAR=""
cleanup() {
  rm -rf "$PASS_DIR"
  if [ -n "$TMP_JAR" ]; then
    rm -f "$TMP_JAR"
  fi
  if [ "$CLEANUP_WORK_DIR" = true ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

for var in AAB_PATH KEYSTORE_PATH KEYSTORE_PASSWORD KEY_ALIAS KEY_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "Error: required env var $var is empty" >&2
    exit 1
  fi
done

# Threshold env vars feed `$(( ... ))` arithmetic below; a non-integer (e.g.
# "30.0") would crash with a confusing parse error under `set -e`. Reject
# early with a clear message instead.
for var in DOWNLOAD_TARGET_MIB DOWNLOAD_CEILING_MIB; do
  if ! [[ "${!var}" =~ ^[0-9]+$ ]] || [ "${!var}" -le 0 ]; then
    echo "Error: $var must be a positive integer (MiB), got: '${!var}'" >&2
    exit 1
  fi
done

# Guard the soft-warn ≤ hard-fail invariant so an inverted override doesn't
# silently break the warn-then-fail semantics — TARGET > CEILING would skip
# the warning entirely and only ever fail.
if [ "$DOWNLOAD_TARGET_MIB" -gt "$DOWNLOAD_CEILING_MIB" ]; then
  echo "Error: DOWNLOAD_TARGET_MIB ($DOWNLOAD_TARGET_MIB) must be ≤ DOWNLOAD_CEILING_MIB ($DOWNLOAD_CEILING_MIB)" >&2
  exit 1
fi

if [ ! -f "$AAB_PATH" ]; then
  echo "Error: AAB_PATH '$AAB_PATH' does not exist" >&2
  exit 1
fi

if [ ! -f "$KEYSTORE_PATH" ]; then
  echo "Error: KEYSTORE_PATH '$KEYSTORE_PATH' does not exist" >&2
  exit 1
fi

mkdir -p "$WORK_DIR"
BUNDLETOOL_JAR="$WORK_DIR/bundletool-${BUNDLETOOL_VERSION}.jar"

# Verifying the bundletool JAR before `java -jar` runs is the point of the
# whole download dance — catching a swap after the JVM already started reading
# class bytes would be too late. CI is Linux (sha256sum, GNU coreutils); we
# also support `shasum -a 256` for macOS dev boxes and fall back to `openssl`
# where neither is in PATH.
compute_jar_sha() {
  local jar="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$jar" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$jar" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r "$jar" | awk '{print $1}'
  else
    echo "<unknown — need sha256sum, shasum, or openssl>"
    return 1
  fi
}

verify_jar_sha() {
  local jar="$1"
  local actual
  actual=$(compute_jar_sha "$jar") || return $?
  [ "$actual" = "$BUNDLETOOL_SHA256" ]
}

# A cached JAR that no longer matches the expected SHA (interrupted prior run,
# version bump, on-disk corruption) is removed up front so the download path
# is self-healing rather than dying with a confusing checksum error.
if [ -f "$BUNDLETOOL_JAR" ] && ! verify_jar_sha "$BUNDLETOOL_JAR"; then
  echo "Cached bundletool JAR failed SHA check — refetching"
  rm -f "$BUNDLETOOL_JAR"
fi

if [ ! -f "$BUNDLETOOL_JAR" ]; then
  # Download to a sibling .tmp and only rename into place after SHA verifies.
  # If curl is killed mid-download (network drop, runner timeout, disk full),
  # the cleanup trap removes the .tmp instead of leaving a partial JAR that a
  # later run would skip re-downloading and then fail to verify.
  TMP_JAR="${BUNDLETOOL_JAR}.tmp.$$"
  # --connect-timeout / --max-time bound the worst case so a stalled GitHub
  # release mirror can't park the entire release workflow indefinitely. The
  # JAR is ~32 MB and routinely downloads in <5s; 60s is generous headroom.
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 \
    "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" \
    -o "$TMP_JAR"
  if ! verify_jar_sha "$TMP_JAR"; then
    echo "Error: bundletool SHA mismatch on download: expected $BUNDLETOOL_SHA256, got $(compute_jar_sha "$TMP_JAR")" >&2
    exit 1
  fi
  mv "$TMP_JAR" "$BUNDLETOOL_JAR"
  TMP_JAR=""
fi
echo "${BUNDLETOOL_JAR}: SHA verified"

APKS_PATH="$WORK_DIR/app-release.apks"

# build-apks materialises the per-device APK splits Play would serve. Signing
# is required so the splits are marked installable; we reuse the keystore the
# AAB itself was signed with so the measured sizes include the v2/v3 sig
# blocks the user actually downloads.
#
# Passwords go through `file:` rather than `pass:` so $KEYSTORE_PASSWORD /
# $KEY_PASSWORD never appear in the runner's `ps aux` listing — bundletool
# reads the first line of each file and the cleanup trap removes them when
# the script exits. PASS_DIR was created by `mktemp -d` (mode 0700) and we
# umask 0077 inside the subshell that writes the files, so they land at
# mode 0600. (Plain `rm -rf`, not secure overwrite — the runner's tmpfs is
# already process-private, so a multi-pass shred would buy little.)
KS_PASS_FILE="$PASS_DIR/ks_pass"
KEY_PASS_FILE="$PASS_DIR/key_pass"
( umask 077; printf '%s' "$KEYSTORE_PASSWORD" > "$KS_PASS_FILE" )
( umask 077; printf '%s' "$KEY_PASSWORD"      > "$KEY_PASS_FILE" )

java -jar "$BUNDLETOOL_JAR" build-apks \
  --bundle="$AAB_PATH" \
  --output="$APKS_PATH" \
  --overwrite \
  --ks="$KEYSTORE_PATH" \
  --ks-pass="file:$KS_PASS_FILE" \
  --ks-key-alias="$KEY_ALIAS" \
  --key-pass="file:$KEY_PASS_FILE"

# get-size total emits CSV ("MIN,MAX\n<bytes>,<bytes>"): the smallest and
# largest combined download across every (sdk, abi, density, language) device
# spec the bundle covers. MAX is the worst-case device — that's what the
# budget should track.
SIZE_CSV=$(java -jar "$BUNDLETOOL_JAR" get-size total --apks="$APKS_PATH")
echo "$SIZE_CSV"

# Take the last numeric "<min>,<max>" row — robust to header ordering and to
# any future extra rows from --dimensions expansion. The `|| true` keeps a
# no-match grep from tripping `set -euo pipefail` before we can print a
# useful error with the raw output.
SIZE_ROW=$(printf '%s\n' "$SIZE_CSV" | { grep -E '^[0-9]+,[0-9]+$' || true; } | tail -n1)
if [ -z "$SIZE_ROW" ]; then
  echo "Error: could not parse a numeric MIN,MAX row from bundletool output:" >&2
  printf '%s\n' "$SIZE_CSV" >&2
  exit 1
fi

DOWNLOAD_MIN=$(printf '%s' "$SIZE_ROW" | cut -d',' -f1)
DOWNLOAD_MAX=$(printf '%s' "$SIZE_ROW" | cut -d',' -f2)
DOWNLOAD_MIN_MIB=$(awk "BEGIN { printf \"%.2f\", $DOWNLOAD_MIN / 1048576 }")
DOWNLOAD_MAX_MIB=$(awk "BEGIN { printf \"%.2f\", $DOWNLOAD_MAX / 1048576 }")

echo "Per-device download size: min=${DOWNLOAD_MIN_MIB} MiB, max=${DOWNLOAD_MAX_MIB} MiB"
echo "::notice title=Per-device download::min ${DOWNLOAD_MIN_MIB} MiB, max ${DOWNLOAD_MAX_MIB} MiB (target ${DOWNLOAD_TARGET_MIB} MiB, ceiling ${DOWNLOAD_CEILING_MIB} MiB)"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo ""
    echo "### Per-device download size (bundletool)"
    echo ""
    echo "- **Min:** ${DOWNLOAD_MIN_MIB} MiB (${DOWNLOAD_MIN} bytes)"
    echo "- **Max:** ${DOWNLOAD_MAX_MIB} MiB (${DOWNLOAD_MAX} bytes)"
    echo "- Target: ${DOWNLOAD_TARGET_MIB} MiB (#131)"
    echo "- Hard ceiling: ${DOWNLOAD_CEILING_MIB} MiB"
  } >> "$GITHUB_STEP_SUMMARY"
fi

DOWNLOAD_TARGET_BYTES=$((DOWNLOAD_TARGET_MIB * 1048576))
DOWNLOAD_CEILING_BYTES=$((DOWNLOAD_CEILING_MIB * 1048576))

if [ "$DOWNLOAD_MAX" -gt "$DOWNLOAD_CEILING_BYTES" ]; then
  echo "::error title=Per-device download exceeded ceiling::${DOWNLOAD_MAX_MIB} MiB > ${DOWNLOAD_CEILING_MIB} MiB ceiling"
  echo "Error: per-device download ${DOWNLOAD_MAX} bytes exceeds hard ceiling ${DOWNLOAD_CEILING_BYTES} bytes (${DOWNLOAD_CEILING_MIB} MiB)" >&2
  exit 1
fi

if [ "$DOWNLOAD_MAX" -gt "$DOWNLOAD_TARGET_BYTES" ]; then
  echo "::warning title=Per-device download exceeded #131 target::${DOWNLOAD_MAX_MIB} MiB > ${DOWNLOAD_TARGET_MIB} MiB target"
fi
