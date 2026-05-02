#!/usr/bin/env bash
# validate_store_metadata.sh — enforce Play Store character limits on the
# fastlane/metadata/android tree before upload.
#
# Play Store limits (in Unicode code points, not bytes):
#   title              ≤ 30 chars
#   short_description  ≤ 80 chars
#   full_description   ≤ 4000 chars
#   changelogs/*       ≤ 500 chars each
#
# Usage:
#   bash scripts/validate_store_metadata.sh
#   bash scripts/validate_store_metadata.sh fastlane/metadata/android
#
# Exits non-zero and prints a summary if any limit is exceeded.

set -euo pipefail

METADATA_ROOT="${1:-fastlane/metadata/android}"

if [ ! -d "$METADATA_ROOT" ]; then
  echo "ERROR: metadata directory not found: $METADATA_ROOT" >&2
  exit 1
fi

ERRORS=0

# Count Unicode code points in a file (strips trailing newline for comparison).
char_count() {
  # python3 is available on all our CI runners and locally (required for the
  # screenshot generators already in scripts/).
  python3 -c "
import sys
text = open(sys.argv[1], encoding='utf-8').read().rstrip('\n')
print(len(text))
" "$1"
}

check_file() {
  local path="$1"
  local limit="$2"
  local label="$3"

  if [ ! -f "$path" ]; then
    # Missing file is not a length violation — supply doesn't require all files.
    return 0
  fi

  local count
  count=$(char_count "$path")

  if [ "$count" -gt "$limit" ]; then
    echo "FAIL  $label: ${count} chars (limit ${limit}) — $path" >&2
    ERRORS=$((ERRORS + 1))
  else
    echo "OK    $label: ${count}/${limit} chars"
  fi
}

echo "=== Play Store metadata length check ==="
echo "Root: $METADATA_ROOT"
echo ""

# Walk every locale directory.
for locale_dir in "$METADATA_ROOT"/*/; do
  locale=$(basename "$locale_dir")
  echo "--- Locale: $locale ---"
  check_file "${locale_dir}title.txt"             30   "title"
  check_file "${locale_dir}short_description.txt" 80   "short_description"
  check_file "${locale_dir}full_description.txt"  4000 "full_description"

  # Check every changelog file in this locale.
  changelogs_dir="${locale_dir}changelogs"
  if [ -d "$changelogs_dir" ]; then
    for cl in "$changelogs_dir"/*.txt; do
      [ -e "$cl" ] || continue
      check_file "$cl" 500 "changelog/$(basename "$cl")"
    done
  fi
  echo ""
done

if [ "$ERRORS" -gt 0 ]; then
  echo "=== FAILED: $ERRORS file(s) exceed their Play Store character limit ===" >&2
  exit 1
else
  echo "=== All metadata files are within Play Store character limits ==="
fi
