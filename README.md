# Firefox and Thunderbird migrate to Mozilla deb

Interactive migration scripts for Ubuntu/Debian-like systems that install Mozilla Firefox or Mozilla Thunderbird from Mozilla's official APT repository and optionally migrate an existing sandboxed Firefox/Thunderbird profile from Flatpak or Snap into the normal deb profile location.

- `firefox-migrate-to-mozilla-deb.sh` handles Mozilla Firefox, and additionally rewrites absolute snap paths inside migrated profile text config files so download directories keep working.
- `thunderbird-migrate-to-mozilla-deb.sh` handles Mozilla Thunderbird, and additionally rewrites absolute snap paths inside migrated profile text config files so mail and download directories keep working.

The scripts are designed for users who want to move away from Flatpak/Snap Firefox or Thunderbird and use a normal deb-installed application, for example when sandboxing prevents host integrations such as native messaging, smart cards, PKCS#11 modules, hardware devices, or other local system integrations.

## What it does

The script can:

- Install Mozilla Firefox or Mozilla Thunderbird from `packages.mozilla.org` using APT.
- Verify Mozilla's APT signing key fingerprint.
- Configure APT pinning so Mozilla's package is preferred over Ubuntu's transitional Snap package.
- Detect your system locale and install a matching Firefox or Thunderbird language pack when available.
- Find profiles from:
  - Flatpak: `~/.var/app/org.mozilla.firefox/.mozilla/firefox` and `~/.var/app/org.mozilla.Thunderbird/.thunderbird`
  - Snap: `~/snap/firefox/common/.mozilla/firefox` and `~/snap/thunderbird/common/.thunderbird`
- Interactively ask which profile to migrate.
- Copy the selected profile into `~/.mozilla/firefox` or `~/.thunderbird` as a new profile.
- Give the migrated profile a clear name, by default `Migrated from sandboxed Firefox` or `Migrated from sandboxed Thunderbird`.
- Preserve existing profiles.
- Update `profiles.ini`, including `[Install...]` sections, so the migrated profile is actually used.
- Rewrite absolute snap paths inside migrated profile text config files so mail/download directories keep working.
- Create a full backup before making changes, and generate a `backup-manifest.txt` and `rollback.sh` in the backup directory.
- Detect and move broken `/usr/local/bin/firefox` and `/usr/local/bin/thunderbird` wrappers that still point to Flatpak or Snap.
- Optionally uninstall Flatpak/Snap Firefox and/or Thunderbird.
- Optionally delete old Flatpak/Snap user data after backup.

## What it does not do

The script does not:

- Delete old Flatpak/Snap profile data by default.
- Remove Flatpak Firefox or Snap Firefox unless you explicitly choose that.
- Upload, sync, or transmit any browser data.
- Guarantee that every extension survives migration. Most profile data should migrate, but Firefox/extension compatibility still depends on Firefox itself.
- Support non-APT distributions such as Fedora, Arch, openSUSE, or NixOS.

## Why this exists

On Ubuntu, `apt install firefox` may install a transitional package that launches the Snap version of Firefox instead of a normal deb package. Flatpak and Snap are useful, but they add sandboxing. That sandboxing can be a problem when Firefox needs direct access to host-installed components.

Mozilla provides an official APT repository for Debian-based and Ubuntu-based distributions. These scripts automate that setup and add safe profile migration and cleanup helpers.

## Thunderbird specifics

`thunderbird-migrate-to-mozilla-deb.sh` uses the same approach as the Firefox script, with these differences:

- It installs the `thunderbird` deb package.
- It adds the Mozilla repository entry for the `thunderbird-deb` suite (Firefox uses the `mozilla` suite), using the one-line APT format in `/etc/apt/sources.list.d/mozilla-thunderbird.list`:

  ```text
  deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt thunderbird-deb main
  ```

- It installs Thunderbird language packs like `thunderbird-l10n-sv-se` or `thunderbird-l10n-de`.
- It finds Thunderbird profiles from:
  - Flatpak Thunderbird: `~/.var/app/org.mozilla.Thunderbird/.thunderbird`
  - Snap Thunderbird: `~/snap/thunderbird/common/.thunderbird`
- It copies the selected profile into `~/.thunderbird` as a new profile named `Migrated from sandboxed Thunderbird`.
- It rewrites absolute paths inside the migrated profile's text config files, mapping `$HOME/snap/thunderbird/common/.thunderbird/...` (including the old profile directory name) to the new `$HOME/.thunderbird/...` location. Thunderbird stores absolute paths in `prefs.js` for mail/Local Folders directories and download locations, so this keeps those working after migration. SQLite databases such as `content-prefs.sqlite` have their TEXT cells fixed too; binary files such as `.jsonlz4`, `.mozlz4`, and `key4.db` are detected by content and never touched.
- It detects and moves broken `/usr/local/bin/thunderbird` wrappers that still point to Flatpak or Snap.
- It optionally uninstalls Flatpak Thunderbird and/or Snap Thunderbird.

All other behavior (backup, rollback, `--dry-run`, `--yes`, interactive prompts, APT pinning, key verification) is identical to the Firefox script. The command-line flags are the same; replace `firefox-migrate-to-mozilla-deb.sh` with `thunderbird-migrate-to-mozilla-deb.sh` in the usage examples below.

Thunderbird verification paths:

```text
/usr/bin/thunderbird
/usr/lib/thunderbird/thunderbird
```

## Standalone path-rewrite helpers

The main scripts rewrite absolute sandbox paths inside migrated profile config files automatically. If you migrated a profile some other way, two standalone helpers do the same rewriting with plain `sed`:

- `rewrite-thunderbird-paths.sh` maps paths to `~/.thunderbird`.
- `rewrite-firefox-paths.sh` maps paths to `~/.mozilla/firefox`.

Each helper reads the deb profile root's `profiles.ini`, finds the current default profile, and rewrites former snap, flatpak and macOS absolute paths inside every text config file of that profile (`prefs.js`, `extensions.json`, `mimeTypes.rdf`, and so on), in place:

```text
$HOME/snap/thunderbird/common/.thunderbird        -> $HOME/.thunderbird
$HOME/.var/app/org.mozilla.Thunderbird/.thunderbird -> $HOME/.thunderbird
/Users/<user>/Library/Thunderbird                 -> $HOME/.thunderbird
$HOME/snap/firefox/common/.mozilla/firefox        -> $HOME/.mozilla/firefox
$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox -> $HOME/.mozilla/firefox
/Users/<user>/Library/Application Support/Firefox -> $HOME/.mozilla/firefox
```

The macOS roots (`/Users/<user>/Library/...`) are detected automatically: profiles migrated from macOS carry absolute paths that do not exist on Linux (for example `mail.root.*` in Thunderbird or `folderCache.json` keys), which can break the app. The helper scans the profile for such paths and rewrites them to the deb root like any other old root.

Binary files such as `.jsonlz4`, `.mozlz4`, and `key4.db` are detected by content and never touched, and the `cache2`/`startupCache` directories are skipped. SQLite databases (for example `content-prefs.sqlite`) *are* fixed: their TEXT cells are updated via `sqlite3` so the database stays valid, and the number of fixed entries is reported. `profiles.ini` itself is rewritten too if it contains old absolute paths (for example an `IsRelative=0` `Path=`).

Each rewritten file reports how many path entries were replaced (`Rewrote: .../prefs.js - 12 entries`), skipped binaries are listed, and a summary line breaks down text rewritten vs. sqlite fixed vs. binary skipped.

Usage:

```bash
./rewrite-thunderbird-paths.sh [--dry-run]
./rewrite-firefox-paths.sh [--dry-run]
```

The deb profile root (`~/.thunderbird` or `~/.mozilla/firefox`) must already exist. The helper targets only the default profile from `profiles.ini`; other profiles are left untouched. `--dry-run` previews the planned replacements without writing any file.

If you migrated a profile by hand (for example copying `~/snap/...` into `~/.thunderbird` or `~/.mozilla/firefox` yourself), run the matching helper on the moved profile before deleting `~/snap` or `~/.var/app` so that removing the old data is safe.

## Safety model

The script is intentionally conservative:

- It asks before doing major actions when run without flags.
- It creates a backup before profile migration or removals.
- It creates a rollback script.
- It does not delete old Flatpak/Snap data unless explicitly requested.
- It preserves existing deb Firefox profiles by creating a new migrated profile.
- It has a `--dry-run` mode.

## Requirements

Tested target family:

- Ubuntu 24.04 LTS and newer
- Debian/Ubuntu-like systems using `apt`

Required tools:

- `bash`
- `sudo`
- `apt-get`
- `dpkg`
- `wget`
- `gpg`
- `python3`

The script installs missing APT prerequisites where possible.

## Install

Clone the repository:

```bash
 git clone https://github.com/YOUR-USER/firefox-migrate-to-mozilla-deb.git
 cd firefox-migrate-to-mozilla-deb
```

Make the script executable:

```bash
chmod +x firefox-migrate-to-mozilla-deb.sh
```

Run interactively:

```bash
./firefox-migrate-to-mozilla-deb.sh
```

## Usage

### Interactive mode

```bash
./firefox-migrate-to-mozilla-deb.sh
```

With no action flags, the script asks:

- Install Mozilla Firefox deb?
- Migrate an existing Flatpak/Snap profile?
- Uninstall Flatpak Firefox?
- Uninstall Snap Firefox?
- Delete old Flatpak/Snap user data?

### Dry run

```bash
./firefox-migrate-to-mozilla-deb.sh --dry-run
```

This prints the planned actions without changing the system.

### Install Mozilla deb Firefox only

```bash
./firefox-migrate-to-mozilla-deb.sh --install-deb
```

### Install Mozilla deb Firefox and migrate a profile

```bash
./firefox-migrate-to-mozilla-deb.sh --install-deb --migrate-profile
```

### More automated run

```bash
./firefox-migrate-to-mozilla-deb.sh --install-deb --migrate-profile --yes
```

This answers yes to prompts. Use it only after testing with `--dry-run`.

### Full flow, still safe

```bash
./firefox-migrate-to-mozilla-deb.sh --all
```

`--all` installs deb Firefox and migrates a profile. Removal of Flatpak/Snap is still controlled separately by flags or prompts.

### Remove Flatpak and Snap Firefox

```bash
./firefox-migrate-to-mozilla-deb.sh --remove-flatpak --remove-snap
```

The script still asks for confirmation unless `--yes` is used.

### Delete old sandbox data after backup

```bash
./firefox-migrate-to-mozilla-deb.sh --delete-old-sandbox-data
```

This removes:

```text
~/.var/app/org.mozilla.firefox
~/snap/firefox
```

Only use this after verifying that the migrated deb Firefox profile works.

## Language packs

By default, the script tries to install a Firefox language pack based on your environment locale.

Examples:

```bash
LANG=sv_SE.UTF-8 ./firefox-migrate-to-mozilla-deb.sh --install-deb
LANG=en_GB.UTF-8 ./firefox-migrate-to-mozilla-deb.sh --install-deb
```

You can override the detected language pack code:

```bash
./firefox-migrate-to-mozilla-deb.sh --install-deb --l10n-code sv-se
./firefox-migrate-to-mozilla-deb.sh --install-deb --l10n-code en-gb
./firefox-migrate-to-mozilla-deb.sh --install-deb --l10n-code de
```

Disable language pack installation:

```bash
./firefox-migrate-to-mozilla-deb.sh --install-deb --no-l10n
```

The script checks for both full locale packages such as:

```text
firefox-l10n-sv-se
firefox-l10n-en-gb
```

and language-only packages such as:

```text
firefox-l10n-de
firefox-l10n-fr
```

## Profile migration details

The script searches for sandboxed Firefox profiles with `places.sqlite`, which normally contains bookmarks and history.

It supports profile sources from:

```text
~/.var/app/org.mozilla.firefox/.mozilla/firefox
~/snap/firefox/common/.mozilla/firefox
```

The migrated profile is copied to:

```text
~/.mozilla/firefox/migrated-from-sandboxed-firefox-YYYYMMDD-HHMMSS.default-release
```

and is shown in Firefox as:

```text
Migrated from sandboxed Firefox
```

The original Flatpak/Snap profile is not moved. It is copied.

### Copied home directory from another machine

Both main scripts find and migrate profiles under the current user's home even if the whole home directory (including `~/snap/...` or `~/.var/app/...`) was copied from another machine, and Snap/Flatpak do not need to be installed on the new system.

Absolute paths inside the profile (for example `browser.download.lastDir` or Thunderbird's mail directories in `prefs.js`) are rewritten for both Snap and Flatpak sources based on the current `$HOME`. The scripts assume the profile's absolute paths live under the home directory they are run from.

## Backups and rollback

Every run creates a backup directory like:

```text
~/firefox-migration-backup-YYYYMMDD-HHMMSS
```

The backup may contain:

```text
mozilla-firefox/
flatpak-org.mozilla.firefox/
snap-firefox/
backup-manifest.txt
rollback.sh
```

To rollback profile data:

```bash
~/firefox-migration-backup-YYYYMMDD-HHMMSS/rollback.sh
```

The rollback script restores backed-up profile directories. It does not uninstall Mozilla deb Firefox and does not reinstall Flatpak/Snap apps.

## Broken `/usr/local/bin/firefox` wrappers

Some users may have a manually created wrapper such as:

```bash
#!/usr/bin/env bash
exec flatpak run org.mozilla.firefox "$@"
```

If `/usr/local/bin` comes before `/usr/bin` in `PATH`, that wrapper can shadow the newly installed deb Firefox. The script detects known Flatpak/Snap wrappers and moves them to a timestamped backup path such as:

```text
/usr/local/bin/firefox.broken-wrapper.YYYYMMDD-HHMMSS
```

Unknown manually created `/usr/local/bin/firefox` files are not removed automatically. The script fails and asks you to inspect them manually.

## Verification

After running the script, start Firefox:

```bash
firefox
```

Check the running process:

```bash
ps -ef | grep -i '[f]irefox'
```

Expected deb Firefox paths look like:

```text
/usr/bin/firefox
/usr/lib/firefox/firefox
```

Bad paths, if you intended to use deb Firefox:

```text
/app/lib/firefox
/snap/firefox
```

Check active profile in Firefox:

```text
about:profiles
```

The migrated profile should be visible as:

```text
Migrated from sandboxed Firefox
```

## Troubleshooting

### `firefox` still starts Flatpak

Check:

```bash
which -a firefox
ls -l /usr/local/bin/firefox /usr/bin/firefox /bin/firefox 2>/dev/null
head -50 /usr/local/bin/firefox 2>/dev/null
```

If `/usr/local/bin/firefox` is a Flatpak wrapper, move it:

```bash
sudo mv /usr/local/bin/firefox /usr/local/bin/firefox.broken-wrapper
hash -r
```

### Migrated profile does not open by default

Check:

```bash
cat ~/.mozilla/firefox/profiles.ini
firefox --ProfileManager
```

Firefox can use `[Install...]` sections in `profiles.ini` to pin a specific profile. The script updates those sections, but if you manually edit profiles later, check both:

```ini
[Install...]
Default=...
Locked=1
```

and:

```ini
[Profile...]
Default=1
```

### No Flatpak/Snap profile is found

Check manually:

```bash
find ~/.var/app/org.mozilla.firefox/.mozilla/firefox ~/snap/firefox/common/.mozilla/firefox \
  -maxdepth 2 \
  \( -name places.sqlite -o -name prefs.js -o -name extensions.json \) \
  -print 2>/dev/null
```

If no profile data exists, there is nothing to migrate.

### Language pack not found

List available packages:

```bash
apt-cache search '^firefox-l10n-'
```

Then run with an explicit code:

```bash
./firefox-migrate-to-mozilla-deb.sh --install-deb --l10n-code sv-se
```

or disable language packs:

```bash
./firefox-migrate-to-mozilla-deb.sh --install-deb --no-l10n
```

## Development

Run syntax check:

```bash
bash -n firefox-migrate-to-mozilla-deb.sh thunderbird-migrate-to-mozilla-deb.sh rewrite-thunderbird-paths.sh rewrite-firefox-paths.sh
```

Run ShellCheck if available:

```bash
shellcheck firefox-migrate-to-mozilla-deb.sh thunderbird-migrate-to-mozilla-deb.sh rewrite-thunderbird-paths.sh rewrite-firefox-paths.sh
```

## Security notes

The script:

- Uses Mozilla's official APT repository.
- Verifies the Mozilla APT signing key fingerprint.
- Writes APT pinning for `packages.mozilla.org`.
- Uses `sudo` for system changes.
- Does not send any browser data anywhere.

Review the script before running it. It changes browser installation and profile configuration.

## License

MIT. See [LICENSE](LICENSE).
