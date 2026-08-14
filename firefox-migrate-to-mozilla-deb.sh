#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE_DEFAULT="/tmp/firefox-migrate-to-mozilla-deb.log"
LOG_FILE="${LOG_FILE:-$LOG_FILE_DEFAULT}"

readonly MOZILLA_KEY="/etc/apt/keyrings/packages.mozilla.org.asc"
readonly MOZILLA_SOURCES="/etc/apt/sources.list.d/mozilla.sources"
readonly MOZILLA_PREF="/etc/apt/preferences.d/mozilla"
readonly EXPECTED_FPR="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"
readonly MOZILLA_APT_ORIGIN="packages.mozilla.org"

readonly FLATPAK_FIREFOX_APP_ID="org.mozilla.firefox"
readonly DEFAULT_PROFILE_NAME="Migrated from sandboxed Firefox"
readonly DEFAULT_PROFILE_DIR_PREFIX="migrated-from-sandboxed-firefox"

ASSUME_YES=0
DRY_RUN=0
INTERACTIVE=1

DO_INSTALL_DEB="unset"
DO_MIGRATE_PROFILE="unset"
DO_REMOVE_FLATPAK="unset"
DO_REMOVE_SNAP="unset"
DO_DELETE_OLD_SANDBOX_DATA="unset"
INSTALL_FIREFOX_L10N="${INSTALL_FIREFOX_L10N:-1}"
FIREFOX_L10N_CODE="${FIREFOX_L10N_CODE:-}"

MIGRATED_PROFILE_NAME="${MIGRATED_PROFILE_NAME:-$DEFAULT_PROFILE_NAME}"
MIGRATED_PROFILE_DIR_NAME="${MIGRATED_PROFILE_DIR_NAME:-}"
BACKUP_DIR=""
SELECTED_PROFILE_SOURCE=""
SELECTED_PROFILE_PATH=""

usage() {
  cat <<EOF_USAGE
Usage:
  $SCRIPT_NAME [options]

Installs Mozilla Firefox as a real deb package on Ubuntu/Debian-like systems and can
optionally migrate an existing Flatpak/Snap Firefox profile into the normal deb
Firefox profile location.

With no action flags, the script runs interactively and asks what to do.

Actions:
  --install-deb                 Install Mozilla Firefox deb package
  --migrate-profile             Migrate one sandboxed Firefox profile to deb Firefox
  --remove-flatpak              Ask/remove Flatpak Firefox after backup
  --remove-snap                 Ask/remove Snap Firefox after backup
  --delete-old-sandbox-data     Ask/delete old Flatpak/Snap Firefox user data after backup
  --all                         Install deb Firefox and migrate a profile; still asks before removals

Options:
  --yes                         Answer yes to prompts; useful with explicit action flags
  --dry-run                     Print planned operations without changing anything
  --no-l10n                     Do not install a Firefox language pack
  --l10n-code CODE              Override detected language pack code, e.g. sv-se, en-gb, de, fr
  --profile-name NAME           Display name for the migrated Firefox profile
  --profile-dir-name NAME       Directory name under ~/.mozilla/firefox for the migrated profile
  --log-file PATH               Write log to PATH instead of $LOG_FILE_DEFAULT
  --help                        Show this help

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --dry-run
  $SCRIPT_NAME --install-deb --migrate-profile
  $SCRIPT_NAME --install-deb --migrate-profile --yes
  $SCRIPT_NAME --all
  $SCRIPT_NAME --install-deb --no-l10n
  $SCRIPT_NAME --install-deb --l10n-code sv-se

Safe defaults:
  - Always creates a backup before profile/system changes
  - Does not remove Flatpak/Snap Firefox unless explicitly selected
  - Does not delete old Flatpak/Snap user data unless explicitly selected
  - Moves known broken /usr/local/bin/firefox wrappers out of the way
  - Preserves existing Firefox profiles and adds a new migrated profile
EOF_USAGE
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

warn() {
  log "WARNING: $*"
}

fail() {
  echo
  log "ERROR: $*"
  exit 1
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN: $*"
  else
    "$@"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

ask_yes_no() {
  local question="$1"
  local default="${2:-n}"

  if [[ "$ASSUME_YES" == "1" ]]; then
    log "$question yes (--yes)"
    return 0
  fi

  local prompt
  if [[ "$default" == "y" ]]; then
    prompt="[Y/n]"
  else
    prompt="[y/N]"
  fi

  local answer
  read -r -p "$question $prompt " answer || true
  answer="${answer:-$default}"

  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --all)
        DO_INSTALL_DEB=1
        DO_MIGRATE_PROFILE=1
        shift
        ;;
      --install-deb)
        DO_INSTALL_DEB=1
        shift
        ;;
      --migrate-profile|--migrate-flatpak-profile)
        DO_MIGRATE_PROFILE=1
        shift
        ;;
      --remove-flatpak)
        DO_REMOVE_FLATPAK=1
        shift
        ;;
      --remove-snap)
        DO_REMOVE_SNAP=1
        shift
        ;;
      --delete-old-sandbox-data)
        DO_DELETE_OLD_SANDBOX_DATA=1
        shift
        ;;
      --yes|-y)
        ASSUME_YES=1
        INTERACTIVE=0
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --no-l10n)
        INSTALL_FIREFOX_L10N=0
        shift
        ;;
      --l10n-code)
        [[ "${2:-}" ]] || fail "--l10n-code requires a value"
        FIREFOX_L10N_CODE="$2"
        shift 2
        ;;
      --profile-name)
        [[ "${2:-}" ]] || fail "--profile-name requires a value"
        MIGRATED_PROFILE_NAME="$2"
        shift 2
        ;;
      --profile-dir-name)
        [[ "${2:-}" ]] || fail "--profile-dir-name requires a value"
        MIGRATED_PROFILE_DIR_NAME="$2"
        shift 2
        ;;
      --log-file)
        [[ "${2:-}" ]] || fail "--log-file requires a value"
        LOG_FILE="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done
}

normalize_boolean_defaults() {
  [[ "$DO_INSTALL_DEB" == "unset" ]] && DO_INSTALL_DEB=0
  [[ "$DO_MIGRATE_PROFILE" == "unset" ]] && DO_MIGRATE_PROFILE=0
  [[ "$DO_REMOVE_FLATPAK" == "unset" ]] && DO_REMOVE_FLATPAK=0
  [[ "$DO_REMOVE_SNAP" == "unset" ]] && DO_REMOVE_SNAP=0
  [[ "$DO_DELETE_OLD_SANDBOX_DATA" == "unset" ]] && DO_DELETE_OLD_SANDBOX_DATA=0
}

generate_profile_dir_name() {
  if [[ -z "$MIGRATED_PROFILE_DIR_NAME" ]]; then
    MIGRATED_PROFILE_DIR_NAME="${DEFAULT_PROFILE_DIR_PREFIX}-$(date +%Y%m%d-%H%M%S).default-release"
  fi
}

detect_os() {
  log "=== Detecting operating system ==="

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    log "OS: ${PRETTY_NAME:-unknown}"

    local os_family="${ID_LIKE:-${ID:-}}"
    if [[ "$os_family" != *debian* && "$os_family" != *ubuntu* && "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
      warn "This does not look like a Debian/Ubuntu based system."
      ask_yes_no "Continue anyway?" "n" || exit 1
    fi
  else
    warn "/etc/os-release not found. Continuing with apt-based checks only."
  fi

  require_cmd apt-get
  require_cmd dpkg
}

interactive_plan() {
  if [[ "$DO_INSTALL_DEB" != "unset" || "$DO_MIGRATE_PROFILE" != "unset" || "$DO_REMOVE_FLATPAK" != "unset" || "$DO_REMOVE_SNAP" != "unset" || "$DO_DELETE_OLD_SANDBOX_DATA" != "unset" ]]; then
    normalize_boolean_defaults
    return
  fi

  echo
  echo "Interactive setup"
  echo "================="
  echo

  ask_yes_no "Install Mozilla Firefox deb from packages.mozilla.org?" "y" && DO_INSTALL_DEB=1 || DO_INSTALL_DEB=0
  ask_yes_no "Migrate an existing Flatpak/Snap Firefox profile to deb Firefox?" "y" && DO_MIGRATE_PROFILE=1 || DO_MIGRATE_PROFILE=0
  ask_yes_no "Uninstall Flatpak Firefox after backup/migration?" "n" && DO_REMOVE_FLATPAK=1 || DO_REMOVE_FLATPAK=0
  ask_yes_no "Uninstall Snap Firefox after backup/migration?" "n" && DO_REMOVE_SNAP=1 || DO_REMOVE_SNAP=0

  if [[ "$DO_REMOVE_FLATPAK" == "1" || "$DO_REMOVE_SNAP" == "1" ]]; then
    ask_yes_no "Delete old Flatpak/Snap Firefox user data after backup?" "n" && DO_DELETE_OLD_SANDBOX_DATA=1 || DO_DELETE_OLD_SANDBOX_DATA=0
  else
    DO_DELETE_OLD_SANDBOX_DATA=0
  fi
}

print_plan() {
  log "=== Planned actions ==="
  log "Install Mozilla deb Firefox: $DO_INSTALL_DEB"
  log "Install Firefox language pack from locale: $INSTALL_FIREFOX_L10N"
  log "Firefox language pack override: ${FIREFOX_L10N_CODE:-auto}"
  log "Current locale: ${LC_ALL:-${LC_MESSAGES:-${LANG:-unknown}}}"
  log "Migrate sandboxed Firefox profile: $DO_MIGRATE_PROFILE"
  log "Migrated profile display name: $MIGRATED_PROFILE_NAME"
  log "Migrated profile directory name: $MIGRATED_PROFILE_DIR_NAME"
  log "Remove Flatpak Firefox: $DO_REMOVE_FLATPAK"
  log "Remove Snap Firefox: $DO_REMOVE_SNAP"
  log "Delete old sandbox user data: $DO_DELETE_OLD_SANDBOX_DATA"
  log "Dry-run: $DRY_RUN"
}

stop_firefox() {
  log "=== Stopping Firefox processes ==="
  run pkill firefox 2>/dev/null || true
  run pkill firefox-bin 2>/dev/null || true
  sleep 1
}

create_backup() {
  log "=== Creating backup ==="

  BACKUP_DIR="$HOME/firefox-migration-backup-$(date +%Y%m%d-%H%M%S)"
  run mkdir -p "$BACKUP_DIR"

  if [[ -d "$HOME/.mozilla/firefox" ]]; then
    log "Backing up classic/deb Firefox profile directory."
    run cp -a "$HOME/.mozilla/firefox" "$BACKUP_DIR/mozilla-firefox"
  fi

  if [[ -d "$HOME/.var/app/$FLATPAK_FIREFOX_APP_ID" ]]; then
    log "Backing up Flatpak Firefox data."
    run cp -a "$HOME/.var/app/$FLATPAK_FIREFOX_APP_ID" "$BACKUP_DIR/flatpak-org.mozilla.firefox"
  fi

  if [[ -d "$HOME/snap/firefox" ]]; then
    log "Backing up Snap Firefox data."
    run cp -a "$HOME/snap/firefox" "$BACKUP_DIR/snap-firefox"
  fi

  write_backup_manifest
  write_rollback_script

  log "Backup directory: $BACKUP_DIR"
}

write_backup_manifest() {
  [[ "$DRY_RUN" == "1" ]] && return

  cat > "$BACKUP_DIR/backup-manifest.txt" <<EOF_MANIFEST
Firefox migration backup
========================

Date: $(date '+%Y-%m-%d %H:%M:%S')
Hostname: $(hostname)
User: $USER
Script: $SCRIPT_NAME

Actions requested:
  Install deb Firefox: $DO_INSTALL_DEB
  Migrate sandboxed profile: $DO_MIGRATE_PROFILE
  Remove Flatpak Firefox: $DO_REMOVE_FLATPAK
  Remove Snap Firefox: $DO_REMOVE_SNAP
  Delete old sandbox data: $DO_DELETE_OLD_SANDBOX_DATA

Paths:
  Classic Firefox data: $HOME/.mozilla/firefox
  Flatpak Firefox data: $HOME/.var/app/$FLATPAK_FIREFOX_APP_ID
  Snap Firefox data: $HOME/snap/firefox

Migrated profile:
  Name: $MIGRATED_PROFILE_NAME
  Directory: $HOME/.mozilla/firefox/$MIGRATED_PROFILE_DIR_NAME
  Source: ${SELECTED_PROFILE_SOURCE:-not selected yet}
  Source path: ${SELECTED_PROFILE_PATH:-not selected yet}
EOF_MANIFEST
}

write_rollback_script() {
  [[ "$DRY_RUN" == "1" ]] && return

  cat > "$BACKUP_DIR/rollback.sh" <<'EOF_ROLLBACK'
#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "This rollback restores backed-up Firefox profile directories."
echo "It does not uninstall Mozilla deb Firefox or reinstall Flatpak/Snap apps."
read -r -p "Continue rollback? [y/N] " answer
case "${answer:-n}" in
  y|Y|yes|YES|Yes) ;;
  *) exit 0 ;;
esac

pkill firefox 2>/dev/null || true
pkill firefox-bin 2>/dev/null || true

if [[ -d "$BACKUP_DIR/mozilla-firefox" ]]; then
  mkdir -p "$HOME/.mozilla"
  rm -rf "$HOME/.mozilla/firefox"
  cp -a "$BACKUP_DIR/mozilla-firefox" "$HOME/.mozilla/firefox"
  echo "Restored ~/.mozilla/firefox"
fi

if [[ -d "$BACKUP_DIR/flatpak-org.mozilla.firefox" ]]; then
  mkdir -p "$HOME/.var/app"
  rm -rf "$HOME/.var/app/org.mozilla.firefox"
  cp -a "$BACKUP_DIR/flatpak-org.mozilla.firefox" "$HOME/.var/app/org.mozilla.firefox"
  echo "Restored Flatpak Firefox user data"
fi

if [[ -d "$BACKUP_DIR/snap-firefox" ]]; then
  mkdir -p "$HOME/snap"
  rm -rf "$HOME/snap/firefox"
  cp -a "$BACKUP_DIR/snap-firefox" "$HOME/snap/firefox"
  echo "Restored Snap Firefox user data"
fi

echo "Rollback complete."
EOF_ROLLBACK

  chmod +x "$BACKUP_DIR/rollback.sh"
}

install_prereqs() {
  log "=== Installing prerequisites ==="
  run sudo apt-get update
  run sudo apt-get install -y wget gpg ca-certificates python3
}

install_mozilla_repo() {
  log "=== Installing Mozilla APT repository ==="

  run sudo install -d -m 0755 /etc/apt/keyrings

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN: download Mozilla signing key to $MOZILLA_KEY"
  else
    wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- \
      | sudo tee "$MOZILLA_KEY" >/dev/null
    sudo chmod 0644 "$MOZILLA_KEY"
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    local actual_fpr
    actual_fpr="$(
      gpg -n -q --import --import-options import-show "$MOZILLA_KEY" 2>/dev/null \
        | awk '/pub/{getline; gsub(/^ +| +$/,""); print; exit}'
    )"

    if [[ "$actual_fpr" != "$EXPECTED_FPR" ]]; then
      fail "Mozilla signing key fingerprint mismatch.

Expected:
$EXPECTED_FPR

Got:
${actual_fpr:-empty}"
    fi

    log "Mozilla signing key fingerprint matches: $actual_fpr"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN: write $MOZILLA_SOURCES"
    log "DRY-RUN: write $MOZILLA_PREF"
  else
    sudo tee "$MOZILLA_SOURCES" >/dev/null <<EOF_SOURCES
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: $MOZILLA_KEY
EOF_SOURCES

    sudo tee "$MOZILLA_PREF" >/dev/null <<EOF_PREF
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF_PREF
  fi

  log "Mozilla APT repository and pinning configured."
}

detect_firefox_l10n_code() {
  if [[ -n "$FIREFOX_L10N_CODE" ]]; then
    echo "$FIREFOX_L10N_CODE"
    return 0
  fi

  local locale_value
  locale_value="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"

  if [[ -z "$locale_value" || "$locale_value" == "C" || "$locale_value" == "POSIX" ]]; then
    return 1
  fi

  local normalized
  normalized="$(echo "$locale_value" | sed 's/\..*$//' | tr '[:upper:]_' '[:lower:]-')"

  case "$normalized" in
    en-us|c|posix)
      return 1
      ;;
    *)
      echo "$normalized"
      ;;
  esac
}

install_firefox_l10n() {
  [[ "$INSTALL_FIREFOX_L10N" == "1" ]] || return

  local l10n_code
  if ! l10n_code="$(detect_firefox_l10n_code)"; then
    log "No Firefox language pack needed for locale: ${LC_ALL:-${LC_MESSAGES:-${LANG:-unknown}}}"
    return
  fi

  local full_package="firefox-l10n-$l10n_code"
  local language_only
  language_only="$(echo "$l10n_code" | cut -d- -f1)"
  local short_package="firefox-l10n-$language_only"

  log "Detected locale: ${LC_ALL:-${LC_MESSAGES:-${LANG:-unknown}}}"
  log "Trying Firefox language pack: $full_package"

  if apt-cache show "$full_package" >/dev/null 2>&1; then
    run sudo apt-get install -y "$full_package"
    return
  fi

  if [[ "$short_package" != "$full_package" ]]; then
    log "Language pack $full_package not found. Trying: $short_package"
    if apt-cache show "$short_package" >/dev/null 2>&1; then
      run sudo apt-get install -y "$short_package"
      return
    fi
  fi

  warn "No matching Firefox language pack found for locale code: $l10n_code"
  warn "List available packages with: apt-cache search '^firefox-l10n-'"
}

install_firefox_deb() {
  [[ "$DO_INSTALL_DEB" == "1" ]] || return

  log "=== Installing Mozilla Firefox deb ==="

  install_prereqs
  install_mozilla_repo

  run sudo apt-get update

  log "APT policy before installation:"
  apt-cache policy firefox | tee -a "$LOG_FILE" || true

  run sudo apt-get install -y --allow-downgrades firefox

  install_firefox_l10n
}

fix_broken_local_firefox_wrapper() {
  log "=== Checking /usr/local/bin/firefox ==="

  if [[ ! -e /usr/local/bin/firefox && ! -L /usr/local/bin/firefox ]]; then
    log "No /usr/local/bin/firefox found."
    return
  fi

  if dpkg -S /usr/local/bin/firefox >/dev/null 2>&1; then
    log "/usr/local/bin/firefox is owned by dpkg. Leaving it unchanged."
    return
  fi

  if grep -qE "flatpak run org\.mozilla\.firefox|snap run firefox|/snap/bin/firefox" /usr/local/bin/firefox 2>/dev/null; then
    local backup_path
    backup_path="/usr/local/bin/firefox.broken-wrapper.$(date +%Y%m%d-%H%M%S)"

    log "Found old Flatpak/Snap Firefox wrapper in /usr/local/bin/firefox."
    log "Moving it to: $backup_path"

    run sudo mv /usr/local/bin/firefox "$backup_path"
    hash -r || true
    return
  fi

  fail "/usr/local/bin/firefox exists, is not owned by dpkg, and is not a known Flatpak/Snap wrapper.

Inspect it manually:

  ls -l /usr/local/bin/firefox
  head -50 /usr/local/bin/firefox

Move it manually if it should not be used:

  sudo mv /usr/local/bin/firefox /usr/local/bin/firefox.manual-backup"
}

list_flatpak_profiles() {
  local root="$HOME/.var/app/$FLATPAK_FIREFOX_APP_ID/.mozilla/firefox"
  [[ -d "$root" ]] || return 0
  find "$root" -maxdepth 2 -type f -name places.sqlite -printf 'flatpak\t%h\n' 2>/dev/null | sort -u
}

list_snap_profiles() {
  local root="$HOME/snap/firefox/common/.mozilla/firefox"
  [[ -d "$root" ]] || return 0
  find "$root" -maxdepth 2 -type f -name places.sqlite -printf 'snap\t%h\n' 2>/dev/null | sort -u
}

list_sandbox_profiles() {
  list_flatpak_profiles
  list_snap_profiles
}

choose_profile_to_migrate() {
  local entries=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && entries+=("$line")
  done < <(list_sandbox_profiles)

  if [[ "${#entries[@]}" -eq 0 ]]; then
    return 1
  fi

  if [[ "$ASSUME_YES" == "1" ]]; then
    IFS=$'\t' read -r SELECTED_PROFILE_SOURCE SELECTED_PROFILE_PATH <<< "${entries[0]}"
    echo "$SELECTED_PROFILE_PATH"
    return 0
  fi

  echo
  echo "Available sandboxed Firefox profiles:"

  local i=1
  for entry in "${entries[@]}"; do
    local source path places_size extensions_marker
    IFS=$'\t' read -r source path <<< "$entry"
    places_size="unknown"
    [[ -f "$path/places.sqlite" ]] && places_size="$(du -h "$path/places.sqlite" | awk '{print $1}')"
    extensions_marker=""
    [[ -f "$path/extensions.json" ]] && extensions_marker=", extensions.json found"
    echo "  $i) [$source] $path [places.sqlite: $places_size$extensions_marker]"
    i=$((i + 1))
  done

  echo
  local choice
  read -r -p "Select profile to migrate [1-${#entries[@]}], or empty to skip: " choice || true
  [[ -n "$choice" ]] || return 1

  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    warn "Invalid selection."
    return 1
  fi

  if (( choice < 1 || choice > ${#entries[@]} )); then
    warn "Selection out of range."
    return 1
  fi

  IFS=$'\t' read -r SELECTED_PROFILE_SOURCE SELECTED_PROFILE_PATH <<< "${entries[$((choice - 1))]}"
  echo "$SELECTED_PROFILE_PATH"
}

remove_profile_locks() {
  local profile_dir="$1"
  rm -f "$profile_dir/parent.lock" \
        "$profile_dir/lock" \
        "$profile_dir/.parentlock" \
        "$profile_dir/.startup-incomplete" 2>/dev/null || true
}

check_profile_contents() {
  local profile_dir="$1"

  log "=== Checking migrated profile contents ==="
  log "Profile directory: $profile_dir"

  for f in places.sqlite prefs.js extensions.json key4.db logins.json cert9.db; do
    if [[ -e "$profile_dir/$f" ]]; then
      log "Found: $f"
    else
      warn "Missing: $f"
    fi
  done

  if [[ ! -f "$profile_dir/places.sqlite" ]]; then
    warn "places.sqlite is missing. This may not be the correct profile."
  fi
}

update_profiles_ini() {
  local profiles_ini="$1"
  local profile_name="$2"
  local profile_dir_name="$3"

  log "Updating profiles.ini: $profiles_ini"

  mkdir -p "$(dirname "$profiles_ini")"

  if [[ -f "$profiles_ini" ]]; then
    cp -a "$profiles_ini" "$profiles_ini.backup.$(date +%Y%m%d-%H%M%S)"
  fi

  python3 - "$profiles_ini" "$profile_name" "$profile_dir_name" <<'PY_PROFILES'
import configparser
import os
import sys

profiles_ini, profile_name, profile_dir_name = sys.argv[1], sys.argv[2], sys.argv[3]

config = configparser.RawConfigParser()
config.optionxform = str

if os.path.exists(profiles_ini):
    config.read(profiles_ini)

if not config.has_section("General"):
    config.add_section("General")

config.set("General", "StartWithLastProfile", "1")
config.set("General", "Version", "2")

for section in config.sections():
    if section.startswith("Profile") and config.has_option(section, "Default"):
        config.remove_option(section, "Default")

# Firefox may use install-specific defaults and ignore Profile Default=1.
# Update all install sections to the migrated profile while preserving the sections.
for section in config.sections():
    if section.startswith("Install"):
        config.set(section, "Default", profile_dir_name)
        config.set(section, "Locked", "1")

target_section = None
for section in config.sections():
    if section.startswith("Profile"):
        if (
            config.get(section, "Name", fallback="") == profile_name
            or config.get(section, "Path", fallback="") == profile_dir_name
        ):
            target_section = section
            break

if target_section is None:
    max_idx = -1
    for section in config.sections():
        if section.startswith("Profile"):
            try:
                max_idx = max(max_idx, int(section.replace("Profile", "")))
            except ValueError:
                pass
    target_section = f"Profile{max_idx + 1}"
    config.add_section(target_section)

config.set(target_section, "Name", profile_name)
config.set(target_section, "IsRelative", "1")
config.set(target_section, "Path", profile_dir_name)
config.set(target_section, "Default", "1")

with open(profiles_ini, "w", encoding="utf-8") as f:
    config.write(f, space_around_delimiters=False)
PY_PROFILES
}

rewrite_profile_paths() {
  local profile_dir="$1"
  local old_profile_dir_name="$2"
  local new_profile_dir_name="$3"

  log "=== Rewriting absolute paths in migrated profile ==="
  log "Profile directory: $profile_dir"

  local new_root="$HOME/.mozilla/firefox"
  log "Rewriting paths to: $new_root"

  local rewrite_output
  rewrite_output="$(
    python3 - "$profile_dir" "$HOME" "$new_root" "$old_profile_dir_name" "$new_profile_dir_name" <<'PY_PATHS'
import os
import re
import sys

profile_dir, old_home, new_root, old_dir_name, new_dir_name = sys.argv[1:6]

old_roots = [
    os.path.join(old_home, "snap/firefox/common/.mozilla/firefox"),
    os.path.join(old_home, ".var/app/org.mozilla.firefox/.mozilla/firefox"),
]
full_old = [os.path.join(root, old_dir_name) for root in old_roots]
full_new = os.path.join(new_root, new_dir_name)

mac_pattern = re.compile(r"/Users/[^/]+/Library/Application Support/Firefox")
mac_seen = set()
for dirpath, dirnames, filenames in os.walk(profile_dir):
    dirnames[:] = [d for d in dirnames if d not in ("cache2", "startupCache")]
    for name in filenames:
        path = os.path.join(dirpath, name)
        try:
            if os.path.getsize(path) > 50 * 1024 * 1024:
                continue
            with open(path, "rb") as f:
                data = f.read(8 * 1024 * 1024)
        except OSError:
            continue
        for m in mac_pattern.finditer(data.decode("utf-8", "replace")):
            mac_seen.add(m.group(0))
old_roots.extend(sorted(mac_seen))

count = 0
sqlite_count = 0
sqlite_entries = 0


def fix_sqlite(path):
    """Fix old roots inside a SQLite DB. Returns entry count, or None if not SQLite."""
    with open(path, "rb") as f:
        if f.read(16) != b"SQLite format 3\x00":
            return None
    import sqlite3

    con = sqlite3.connect(path)
    con.text_factory = str
    cur = con.cursor()
    n = 0
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
                    if not isinstance(val, str):
                        continue
                    new = val
                    for full in full_old:
                        new = new.replace(full, full_new)
                    for root in old_roots:
                        new = new.replace(root, new_root)
                    if new != val:
                        n += 1
                        cur.execute(
                            'UPDATE "%s" SET "%s"=? WHERE rowid=?' % (table, cname),
                            (new, rowid),
                        )
    con.commit()
    if cur.execute("PRAGMA integrity_check").fetchall()[0][0] != "ok":
        con.close()
        raise SystemExit(f"sqlite integrity check failed after fixing: {path}")
    con.close()
    return n


for dirpath, dirnames, filenames in os.walk(profile_dir):
    dirnames[:] = [d for d in dirnames if d not in ("cache2", "startupCache")]
    for name in filenames:
        path = os.path.join(dirpath, name)
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            continue
        if b"\x00" in data:
            n = fix_sqlite(path)
            if n is not None:
                sqlite_count += 1
                sqlite_entries += n
                print(f"Fixed SQLite: {path} - {n} entries")
            continue
        try:
            content = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if not any(root in content for root in old_roots):
            continue
        for full in full_old:
            content = content.replace(full, full_new)
        for root in old_roots:
            content = content.replace(root, new_root)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        count += 1
        print(path)

print(f"Total rewritten files: {count}")
print(f"Total sqlite files fixed: {sqlite_count} ({sqlite_entries} entries)")
PY_PATHS
  )"

  if [[ -n "$rewrite_output" ]]; then
    while IFS= read -r line; do
      log "$line"
    done <<< "$rewrite_output"
  fi
}

migrate_profile() {
  [[ "$DO_MIGRATE_PROFILE" == "1" ]] || return

  log "=== Migrating sandboxed Firefox profile to deb Firefox ==="

  local source_profile
  if ! source_profile="$(choose_profile_to_migrate)"; then
    warn "No sandboxed Firefox profile selected. Skipping migration."
    return
  fi

  log "Selected source: ${SELECTED_PROFILE_SOURCE:-unknown}"
  log "Selected profile: $source_profile"

  local source_dir_name
  source_dir_name="$(basename "$source_profile")"

  local deb_root="$HOME/.mozilla/firefox"
  local deb_profile="$deb_root/$MIGRATED_PROFILE_DIR_NAME"

  run mkdir -p "$deb_root"

  if [[ -d "$deb_profile" ]]; then
    local old="$deb_profile.before-migration.$(date +%Y%m%d-%H%M%S)"
    log "Target profile already exists. Moving old copy to: $old"
    run mv "$deb_profile" "$old"
  fi

  log "Copying profile to: $deb_profile"
  run cp -a "$source_profile" "$deb_profile"

  if [[ "$DRY_RUN" != "1" ]]; then
    remove_profile_locks "$deb_profile"
    check_profile_contents "$deb_profile"
    rewrite_profile_paths "$deb_profile" "$source_dir_name" "$MIGRATED_PROFILE_DIR_NAME"
    update_profiles_ini "$deb_root/profiles.ini" "$MIGRATED_PROFILE_NAME" "$MIGRATED_PROFILE_DIR_NAME"
  else
    log "DRY-RUN: update profiles.ini and set migrated profile as default"
  fi

  log "Migrated profile name: $MIGRATED_PROFILE_NAME"
  log "Migrated profile path: $deb_profile"
}

remove_sandboxed_firefox() {
  log "=== Handling Flatpak/Snap Firefox removal ==="

  if [[ "$DO_REMOVE_FLATPAK" == "1" ]]; then
    if command -v flatpak >/dev/null 2>&1 && flatpak list --app | grep -q "$FLATPAK_FIREFOX_APP_ID"; then
      if ask_yes_no "Uninstall Flatpak Firefox?" "n"; then
        run flatpak uninstall -y "$FLATPAK_FIREFOX_APP_ID" || warn "Could not uninstall Flatpak Firefox."
      fi
    else
      log "Flatpak Firefox is not installed."
    fi
  fi

  if [[ "$DO_REMOVE_SNAP" == "1" ]]; then
    if command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
      if ask_yes_no "Uninstall Snap Firefox?" "n"; then
        run sudo snap remove firefox || warn "Could not uninstall Snap Firefox."
      fi
    else
      log "Snap Firefox is not installed."
    fi
  fi

  if [[ "$DO_DELETE_OLD_SANDBOX_DATA" == "1" ]]; then
    if ask_yes_no "Delete old Flatpak/Snap Firefox user data? Backup has been created." "n"; then
      run rm -rf "$HOME/.var/app/$FLATPAK_FIREFOX_APP_ID"
      run rm -rf "$HOME/snap/firefox"
    fi
  else
    log "Old Flatpak/Snap user data is left in place."
  fi
}

verify_firefox_deb() {
  if [[ "$DO_INSTALL_DEB" != "1" && "$DO_MIGRATE_PROFILE" != "1" ]]; then
    return
  fi

  log "=== Verifying deb Firefox ==="

  hash -r || true

  local firefox_cmd
  firefox_cmd="$(command -v firefox || true)"
  [[ -n "$firefox_cmd" ]] || fail "firefox was not found in PATH."

  local firefox_real
  firefox_real="$(readlink -f "$firefox_cmd" 2>/dev/null || echo "$firefox_cmd")"

  local version
  version="$(firefox --version 2>/dev/null || true)"

  log "firefox command: $firefox_cmd"
  log "firefox realpath: $firefox_real"
  log "firefox version: ${version:-empty}"

  if [[ "$firefox_cmd" == "/usr/local/bin/firefox" ]]; then
    fail "firefox in PATH still points to /usr/local/bin/firefox."
  fi

  if [[ -z "$version" ]]; then
    fail "firefox --version returned empty output. The wrong Firefox executable is probably being used."
  fi

  if [[ "$firefox_real" == /snap/* ]]; then
    fail "firefox still points to Snap: $firefox_real"
  fi

  if [[ "$firefox_real" == /app/* ]]; then
    fail "firefox still points to Flatpak: $firefox_real"
  fi

  if [[ -f /usr/bin/firefox ]] && grep -q "/snap/bin/firefox" /usr/bin/firefox 2>/dev/null; then
    fail "/usr/bin/firefox is still a Snap wrapper."
  fi

  if ! dpkg -s firefox >/dev/null 2>&1; then
    fail "The dpkg package firefox is not installed."
  fi

  if dpkg -S "$firefox_real" >/dev/null 2>&1; then
    log "dpkg owner: $(dpkg -S "$firefox_real" | head -n 1)"
  else
    warn "Could not confirm dpkg ownership for: $firefox_real"
  fi

  local policy
  policy="$(apt-cache policy firefox || true)"
  log "APT policy:"
  echo "$policy" | tee -a "$LOG_FILE" || true

  if ! echo "$policy" | grep -q "$MOZILLA_APT_ORIGIN"; then
    warn "APT policy does not mention $MOZILLA_APT_ORIGIN. Check repository configuration."
  fi

  log "deb Firefox verification OK."
}

print_summary() {
  cat <<EOF_SUMMARY

============================================================
Done
============================================================

Log:
  $LOG_FILE

Backup:
  ${BACKUP_DIR:-not created}

Migrated profile:
  Name: $MIGRATED_PROFILE_NAME
  Path: $HOME/.mozilla/firefox/$MIGRATED_PROFILE_DIR_NAME

Start Firefox:
  firefox

Check active profile:
  about:profiles

Check process:
  ps -ef | grep -i '[f]irefox'

Expected deb Firefox process path:
  /usr/lib/firefox/firefox

Bad process paths:
  /app/lib/firefox
  /snap/firefox

Rollback, if needed:
  ${BACKUP_DIR:-<backup-dir>}/rollback.sh

============================================================

EOF_SUMMARY
}

main() {
  parse_args "$@"
  interactive_plan
  generate_profile_dir_name

  log "Starting $SCRIPT_NAME"
  log "Log file: $LOG_FILE"

  require_cmd sudo
  require_cmd apt-get
  require_cmd dpkg
  require_cmd awk
  require_cmd grep
  require_cmd readlink
  require_cmd python3

  detect_os
  print_plan

  if [[ "$DRY_RUN" != "1" ]]; then
    sudo -v
  fi

  stop_firefox
  create_backup
  install_firefox_deb
  migrate_profile
  remove_sandboxed_firefox
  fix_broken_local_firefox_wrapper
  verify_firefox_deb
  print_summary

  log "Done."
}

main "$@"
