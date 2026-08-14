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
SQLite databases (for example content-prefs.sqlite) have their TEXT cells fixed too.
Other binary files such as .jsonlz4, .mozlz4 and key4.db are detected by content and skipped.
profiles.ini itself is rewritten too if it contains old absolute paths.
Window-state files (session.json, xulstore.json) are reset so stale or corrupt
state cannot break the launch after migration; Thunderbird regenerates them.

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

build_sed_script() {
  local snap_root="$HOME/snap/thunderbird/common/.thunderbird"
  local flatpak_root="$HOME/.var/app/org.mozilla.Thunderbird/.thunderbird"
  local deb_root="$HOME/.thunderbird"

  local script
  script="s|$(escape_sed "$snap_root")|$(escape_sed "$deb_root")|g;"
  script+="s|$(escape_sed "$flatpak_root")|$(escape_sed "$deb_root")|g"
  printf '%s' "$script"
}

count_text_entries() {
  local file="$1"
  local snap_root="$HOME/snap/thunderbird/common/.thunderbird"
  local flatpak_root="$HOME/.var/app/org.mozilla.Thunderbird/.thunderbird"

  grep -oF -e "$snap_root" -e "$flatpak_root" "$file" 2>/dev/null | wc -l
}

is_sqlite() {
  local file="$1"
  local magic
  magic="$(od -An -N16 -tx1 "$file" 2>/dev/null | tr -d ' \n')"
  [[ "$magic" == "53514c69746520666f726d6174203300" ]]
}

fix_sqlite() {
  local file="$1"
  local dry="$2"

  python3 - "$file" "$HOME/snap/thunderbird/common/.thunderbird" "$HOME/.var/app/org.mozilla.Thunderbird/.thunderbird" "$HOME/.thunderbird" "$dry" <<'PY_SQLITE'
import sqlite3
import sys

db, snap_root, flatpak_root, deb_root, dry = sys.argv[1:6]
old_roots = [snap_root, flatpak_root]

con = sqlite3.connect(db)
con.text_factory = str
cur = con.cursor()
count = 0

for (table,) in cur.execute(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
).fetchall():
    try:
        cols = cur.execute('PRAGMA table_info("%s")' % table).fetchall()
    except sqlite3.Error:
        continue
    for _cid, cname, ctype, _notnull, _dflt, _pk in cols:
        if ctype.upper() not in ("TEXT", "CLOB", ""):
            continue
        for old in old_roots:
            try:
                rows = cur.execute(
                    'SELECT rowid, "%s" FROM "%s" WHERE "%s" LIKE ?'
                    % (cname, table, cname),
                    ("%" + old + "%",),
                ).fetchall()
            except sqlite3.Error:
                continue
            for rowid, val in rows:
                if not isinstance(val, str) or old not in val:
                    continue
                count += 1
                if dry == "0":
                    cur.execute(
                        'UPDATE "%s" SET "%s"=? WHERE rowid=?' % (table, cname),
                        (val.replace(old, deb_root), rowid),
                    )

if dry == "0":
    con.commit()
    if cur.execute("PRAGMA integrity_check").fetchall()[0][0] != "ok":
        con.close()
        sys.exit(3)
con.close()

print(count)
PY_SQLITE
}

rewrite_file() {
  local file="$1"
  local entries
  entries="$(count_text_entries "$file")"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: $file - $entries entries"
  else
    sed -i "$(build_sed_script)" "$file"
    echo "Rewrote: $file - $entries entries"
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
      xargs -0 grep -FlZ "${old_patterns[@]}" 2>/dev/null
  )

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "No files containing old paths found."
    return 0
  fi

  local text_count=0
  local text_entries=0
  local sqlite_count=0
  local sqlite_entries=0
  local binary_count=0

  for file in "${files[@]}"; do
    if grep -FIq "${old_patterns[@]}" "$file" 2>/dev/null; then
      text_count=$((text_count + 1))
      local t
      t="$(count_text_entries "$file")"
      text_entries=$((text_entries + t))
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "DRY-RUN: $file - $t entries"
      else
        sed -i "$(build_sed_script)" "$file"
        echo "Rewrote: $file - $t entries"
      fi
    else
      if is_sqlite "$file"; then
        sqlite_count=$((sqlite_count + 1))
        local n
        n="$(fix_sqlite "$file" "$DRY_RUN")"
        if [[ "$n" =~ ^[0-9]+$ ]]; then
          sqlite_entries=$((sqlite_entries + n))
        else
          echo "WARNING: sqlite fix failed for $file: $n"
        fi
        if [[ "$DRY_RUN" == "1" ]]; then
          echo "DRY-RUN: $file - $n entries (sqlite)"
        else
          echo "Fixed SQLite: $file - $n entries"
        fi
      else
        binary_count=$((binary_count + 1))
        echo "Skipped (binary): $file"
      fi
    fi
  done

  echo "Total files processed: $text_count text rewritten ($text_entries entries), $sqlite_count sqlite fixed ($sqlite_entries entries), $binary_count binary skipped"
}

fail() {
  echo
  echo "ERROR: $*" >&2
  exit 1
}

reset_window_state() {
  local profile_dir="$1"
  local f
  for f in session.json xulstore.json; do
    [[ -f "$profile_dir/$f" && ! -L "$profile_dir/$f" ]] || continue
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY-RUN: Reset $profile_dir/$f -> $f.bak"
    else
      mv -f "$profile_dir/$f" "$profile_dir/$f.bak"
      echo "Reset: $f (window state regenerates on next launch)"
    fi
  done
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

  reset_window_state "$profile_dir"

  if grep -Fq -e "$HOME/snap/thunderbird/common/.thunderbird" -e "$HOME/.var/app/org.mozilla.Thunderbird/.thunderbird" "$profiles_ini" 2>/dev/null; then
    rewrite_file "$profiles_ini"
  else
    echo "No old paths found in profiles.ini"
  fi
}

main "$@"