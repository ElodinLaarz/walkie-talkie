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
# Default SHA pins bundletool 1.18.3 (verified against the JAR Google publishes
# at github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar).
# Bump in lockstep with BUNDLETOOL_VERSION — a tag retarget on Google's release
# would otherwise hand a swapped binary our keystore for build-apks signing.
BUNDLETOOL_SHA256="${BUNDLETOOL_SHA256:-a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29}"
DOWNLOAD_TARGET_MIB="${DOWNLOAD_TARGET_MIB:-30}"
DOWNLOAD_CEILING_MIB="${DOWNLOAD_CEILING_MIB:-50}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"

for var in AAB_PATH KEYSTORE_PATH KEYSTORE_PASSWORD KEY_ALIAS KEY_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "Error: required env var $var is empty" >&2
    exit 1
  fi
done

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

if [ ! -f "$BUNDLETOOL_JAR" ]; then
  curl -fsSL --retry 3 \
    "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" \
    -o "$BUNDLETOOL_JAR"
fi
# Verify before invoking — catching a swap after `java -jar` would be too late.
echo "${BUNDLETOOL_SHA256}  ${BUNDLETOOL_JAR}" | sha256sum -c -

APKS_PATH="$WORK_DIR/app-release.apks"

# build-apks materialises the per-device APK splits Play would serve. Signing
# is required so the splits are marked installable; we reuse the keystore the
# AAB itself was signed with so the measured sizes include the v2/v3 sig
# blocks the user actually downloads.
java -jar "$BUNDLETOOL_JAR" build-apks \
  --bundle="$AAB_PATH" \
  --output="$APKS_PATH" \
  --overwrite \
  --ks="$KEYSTORE_PATH" \
  --ks-pass="pass:$KEYSTORE_PASSWORD" \
  --ks-key-alias="$KEY_ALIAS" \
  --key-pass="pass:$KEY_PASSWORD"

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
