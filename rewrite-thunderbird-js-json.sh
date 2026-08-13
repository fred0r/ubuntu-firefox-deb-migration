#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

DRY_RUN=0
OLD_HOME="${OLD_HOME:-$HOME}"

usage() {
  cat <<EOF_USAGE
Usage:
  $SCRIPT_NAME PROFILE_DIR [OLD_PROFILE_DIR_NAME] [--old-home PATH] [--dry-run]

Rewrites absolute snap/flatpak Thunderbird paths inside the prefs.js, .js and .json files
of a migrated Thunderbird profile so they point at the deb profile location.

Old roots rewritten (from --old-home, default \$HOME):
  \$OLD_HOME/snap/thunderbird/common/.thunderbird
  \$OLD_HOME/.var/app/org.mozilla.Thunderbird/.thunderbird

to:
  $HOME/.thunderbird

Arguments:
  PROFILE_DIR             The migrated profile directory to scan and rewrite in place.
  OLD_PROFILE_DIR_NAME    The source profile directory name, e.g. abcdef.default.
                          When given, full paths that include this directory name are
                          remapped to the new profile directory name (basename of
                          PROFILE_DIR). When omitted, only root-level path swaps run.
  --old-home PATH         Home directory the profile was copied from, e.g. /home/olduser.
                          Needed when the whole home directory was copied from another
                          machine and absolute paths reference that old home.
  --dry-run               Print the planned replacements without modifying files.

Only prefs.js, *.js and *.json files are touched. .jsonlz4/.mozlz4 and binary files are skipped.

Examples:
  $SCRIPT_NAME ~/.thunderbird/migrated-from-sandboxed-thunderbird-20260814-010000.default-release abcdef.default
  $SCRIPT_NAME ~/.thunderbird/migrated-from-sandboxed-thunderbird-20260814-010000.default-release abcdef.default --old-home /home/olduser
  $SCRIPT_NAME ~/.thunderbird/migrated-from-sandboxed-thunderbird-20260814-010000.default-release --dry-run
EOF_USAGE
}

escape_sed() {
  printf '%s' "$1" | sed 's/[&|/]/\\&/g'
}

rewrite_profile_paths() {
  local profile_dir="$1"
  local old_profile_dir_name="${2:-}"

  [[ -d "$profile_dir" ]] || fail "Profile directory does not exist: $profile_dir"

  local new_profile_dir_name
  new_profile_dir_name="$(basename "$profile_dir")"

  local snap_root="$OLD_HOME/snap/thunderbird/common/.thunderbird"
  local flatpak_root="$OLD_HOME/.var/app/org.mozilla.Thunderbird/.thunderbird"
  local deb_root="$HOME/.thunderbird"

  local old_roots=("$snap_root" "$flatpak_root")
  local old_patterns=()
  local i
  for i in "${old_roots[@]}"; do
    old_patterns+=(-e "$i")
  done

  local -a files=()
  local file
  while IFS= read -r -d '' file; do
    if grep -Fq "${old_patterns[@]}" "$file" 2>/dev/null; then
      files+=("$file")
    fi
  done < <(
    find "$profile_dir" \
      -type d \( -name cache2 -o -name startupCache \) -prune -o \
      -type f \( -name '*.js' -o -name '*.json' \) \
      ! -name '*.jsonlz4' ! -name '*.mozlz4' -print0 2>/dev/null
  )

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "No files containing old paths found."
    return 0
  fi

  local count=0
  for file in "${files[@]}"; do
    local sed_script=""

    if [[ -n "$old_profile_dir_name" ]]; then
      local full_old="$snap_root/$old_profile_dir_name"
      local full_old_fp="$flatpak_root/$old_profile_dir_name"
      local full_new="$deb_root/$new_profile_dir_name"
      sed_script+="s|$(escape_sed "$full_old")|$(escape_sed "$full_new")|g;"
      sed_script+="s|$(escape_sed "$full_old_fp")|$(escape_sed "$full_new")|g;"
    fi

    sed_script+="s|$(escape_sed "$snap_root")|$(escape_sed "$deb_root")|g;"
    sed_script+="s|$(escape_sed "$flatpak_root")|$(escape_sed "$deb_root")|g"

    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY-RUN: sed -i '$sed_script' $file"
    else
      sed -i "$sed_script" "$file"
      echo "Rewrote: $file"
    fi
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
  local profile_dir=""
  local old_profile_dir_name=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --old-home)
        [[ "${2:-}" ]] || fail "--old-home requires a value"
        OLD_HOME="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      -*)
        fail "Unknown option: $1"
        ;;
      *)
        if [[ -z "$profile_dir" ]]; then
          profile_dir="$1"
        elif [[ -z "$old_profile_dir_name" ]]; then
          old_profile_dir_name="$1"
        else
          fail "Unexpected extra argument: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$profile_dir" ]] || fail "Missing required argument: PROFILE_DIR"

  rewrite_profile_paths "$profile_dir" "$old_profile_dir_name"
}

main "$@"