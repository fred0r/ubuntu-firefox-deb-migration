#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

DRY_RUN=0

usage() {
  cat <<EOF_USAGE
Usage:
  $SCRIPT_NAME [--dry-run]

Finds the current default Thunderbird profile from ~/.thunderbird/profiles.ini
and rewrites former snap/flatpak absolute paths inside its text config files
so they point at the deb profile location. The deb profile root must already
exist; the sandbox may or may not still be present.

Old roots rewritten:
  $HOME/snap/thunderbird/common/.thunderbird
  $HOME/.var/app/org.mozilla.Thunderbird/.thunderbird

to:
  $HOME/.thunderbird

Options:
  --dry-run               Print the planned replacements without modifying files.

All text config files are touched (prefs.js, extensions.json, mimeTypes.rdf, ...).
Binary files such as .sqlite, .db, .jsonlz4 and .mozlz4 are detected by content and skipped.
profiles.ini itself is rewritten too if it contains old absolute paths.

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --dry-run
EOF_USAGE
}

escape_sed() {
  printf '%s' "$1" | sed 's/[&|/]/\\&/g'
}

find_default_profile_dir() {
  local deb_root="$1"
  local profiles_ini="$2"

  python3 - "$deb_root" "$profiles_ini" <<'PY_PROFILE'
import os
import re
import sys

deb_root, profiles_ini = sys.argv[1], sys.argv[2]

config = {}
current = None
install_default = None

with open(profiles_ini, encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith(";") or line.startswith("#"):
            continue
        match = re.match(r"^\[(.*)\]$", line)
        if match:
            current = match.group(1).strip()
            config[current] = {}
            continue
        if current is None or "=" not in line:
            continue
        key, _, value = line.partition("=")
        config[current][key.strip()] = value.strip()

for section in config:
    if section.startswith("Install") and "Default" in config[section]:
        install_default = config[section]["Default"]

target_path = None
is_relative = "1"
for section in config:
    if not section.startswith("Profile"):
        continue
    cfg = config[section]
    if cfg.get("Default") == "1":
        target_path = cfg.get("Path")
        is_relative = cfg.get("IsRelative", "1")
        break

if target_path is None:
    target_path = install_default

if not target_path:
    sys.exit(2)

target_path = target_path.strip('"').strip("'")
if os.path.isabs(target_path):
    print(os.path.normpath(target_path))
elif is_relative == "0":
    sys.exit(2)
else:
    print(os.path.normpath(os.path.join(deb_root, target_path)))
PY_PROFILE
}

rewrite_file() {
  local file="$1"
  local snap_root="$HOME/snap/thunderbird/common/.thunderbird"
  local flatpak_root="$HOME/.var/app/org.mozilla.Thunderbird/.thunderbird"
  local deb_root="$HOME/.thunderbird"

  local sed_script
  sed_script="s|$(escape_sed "$snap_root")|$(escape_sed "$deb_root")|g;"
  sed_script+="s|$(escape_sed "$flatpak_root")|$(escape_sed "$deb_root")|g"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: sed -i '$sed_script' $file"
  else
    sed -i "$sed_script" "$file"
    echo "Rewrote: $file"
  fi
}

rewrite_profile_paths() {
  local profile_dir="$1"
  local snap_root="$HOME/snap/thunderbird/common/.thunderbird"
  local flatpak_root="$HOME/.var/app/org.mozilla.Thunderbird/.thunderbird"

  [[ -d "$profile_dir" ]] || fail "Profile directory does not exist: $profile_dir"

  local old_patterns=(-e "$snap_root" -e "$flatpak_root")

  local -a files=()
  local file
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(
    find "$profile_dir" \
      -type d \( -name cache2 -o -name startupCache \) -prune -o \
      -type f -print0 2>/dev/null |
      xargs -0 grep -FIlZ "${old_patterns[@]}" 2>/dev/null
  )

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "No files containing old paths found."
    return 0
  fi

  local count=0
  for file in "${files[@]}"; do
    rewrite_file "$file"
    count=$((count + 1))
  done

  echo "Total files processed: $count"
}

fail() {
  echo
  echo "ERROR: $*" >&2
  exit 1
}

main() {
  local deb_root="$HOME/.thunderbird"
  local profiles_ini="$deb_root/profiles.ini"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      -*)
        fail "Unknown option: $1"
        ;;
      *)
        fail "Unexpected argument: $1"
        ;;
    esac
  done

  [[ -d "$deb_root" ]] || fail "Thunderbird profile root does not exist: $deb_root"
  [[ -f "$profiles_ini" ]] || fail "profiles.ini not found: $profiles_ini"

  local profile_dir
  profile_dir="$(find_default_profile_dir "$deb_root" "$profiles_ini")" || fail "Could not determine the default profile from $profiles_ini"
  [[ -n "$profile_dir" ]] || fail "Could not determine the default profile from $profiles_ini"
  [[ -d "$profile_dir" ]] || fail "Default profile directory does not exist: $profile_dir"

  echo "Default profile: $profile_dir"
  rewrite_profile_paths "$profile_dir"

  if grep -Fq -e "$HOME/snap/thunderbird/common/.thunderbird" -e "$HOME/.var/app/org.mozilla.Thunderbird/.thunderbird" "$profiles_ini" 2>/dev/null; then
    rewrite_file "$profiles_ini"
  else
    echo "No old paths found in profiles.ini"
  fi
}

main "$@"