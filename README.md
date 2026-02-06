# macos-clean-my-stuff

A safety-first macOS disk space auditor and interactive cleaner for Apple Silicon and Intel Macs.

**Default mode is read-only.** Nothing is modified unless you explicitly opt in.

## Quick Start

```bash
# Make executable (one time)
chmod +x disk-audit.sh

# Run a quick audit (read-only, no changes)
./disk-audit.sh

# Thorough audit (scans deeper, takes longer)
./disk-audit.sh --deep

# Preview what cleanup would do (no changes)
./disk-audit.sh --cleanup --dry-run

# Interactive cleanup (prompts per category)
./disk-audit.sh --cleanup
```

## Usage

```
disk-audit.sh [OPTIONS]

MODES
  (default)       Read-only audit. Reports disk usage, no changes made.
  --cleanup       Interactive cleanup mode. Prompts per category (Y/N).
  --dry-run       Show what --cleanup would do, without doing it.

SCAN DEPTH
  --fast          Known hotspots only (default). Fast, covers ~90% of wins.
  --deep          More exhaustive scan of user space. Slower.

OPTIONS
  --top N         Show top N largest files/dirs (default: 25)
  --log PATH      Custom log file path
  -h, --help      Show help message
  -v, --version   Show version
```

## What It Checks

| Area | What | Risk Level |
|------|------|------------|
| Trash | `~/.Trash` | LOW |
| User Caches | `~/Library/Caches` | LOW |
| User Logs | `~/Library/Logs` | LOW |
| System Logs | `/private/var/log` | MED |
| Xcode DerivedData | Build artifacts | LOW |
| Xcode Archives | Old distribution builds | MED |
| Xcode iOS DeviceSupport | Debug symbols per iOS version | LOW |
| Xcode Simulators | Unavailable simulator runtimes | LOW |
| Homebrew | Download cache | LOW |
| Docker | Images, containers, build cache | HIGH |
| npm / yarn / pnpm | Package caches | LOW |
| pip / conda | Package caches | LOW / MED |
| Chrome / Brave / Firefox / Safari | Browser caches | LOW / MED |
| Mail | Data + attachment downloads | HIGH / LOW |
| iOS Backups | `MobileSync/Backup` | HIGH |
| Downloads | .dmg, .pkg, large .zip files | LOW / MED |
| Time Machine | Local snapshots | MED |
| App caches | Spotify, Slack, Discord | LOW |
| Dev tools | Gradle, CocoaPods, Composer, Cargo, Go, Ruby | LOW |

## Examples

### 1. Quick read-only audit

```bash
./disk-audit.sh
```

Produces a report showing filesystem overview, home directory breakdown, largest files/dirs, system data contributors, and a checklist of safe cleanup candidates with commands. Nothing is modified.

### 2. Deep audit

```bash
./disk-audit.sh --deep
```

Same as above but also:
- Scans all of `~` for large files (not just known hotspots)
- Finds `node_modules` directories and totals their size
- Finds Python virtual environments
- Reports old large files in Downloads (>90 days, >50MB)

Takes 1-2 minutes depending on disk size.

### 3. Cleanup dry run

```bash
./disk-audit.sh --cleanup --dry-run
```

Runs the full audit, then walks through each cleanup category showing exactly what *would* happen — without touching any files. Use this to review before committing.

### 4. Interactive cleanup

```bash
./disk-audit.sh --cleanup
```

After the audit, prompts for each category:

```
━━━ Xcode DerivedData ━━━
Size:    8.2 GB
Risk:    [LOW RISK]
Path:    /Users/you/Library/Developer/Xcode/DerivedData
Why:     Build artifacts; Xcode rebuilds on next build.
Warning: Next build will be slower (clean build).
Command: rm -rf '/Users/you/Library/Developer/Xcode/DerivedData'

Clean up 'Xcode DerivedData' (8.2 GB)? [y/N]:
```

- LOW-risk items: single confirmation
- HIGH-risk items (Docker, iOS Backups): double confirmation with warning
- User-space items are moved to Trash where possible
- `rm -rf` used only for caches/logs after confirmation
- `/System` and personal content are never touched

### 5. Custom log location

```bash
./disk-audit.sh --log ~/my-audit.log
```

## Safety Guarantees

- **Read-only by default.** The script never modifies, moves, or deletes anything unless `--cleanup` is passed.
- **Interactive cleanup.** Every category requires explicit Y/N confirmation. HIGH-risk items require double confirmation.
- **Protected paths.** `/System`, `/usr`, `/bin`, `/sbin`, `~/Documents`, `~/Photos`, `~/Movies`, `~/Music`, and `~/Desktop` are hardcoded as off-limits.
- **Trash first.** User-space deletions are moved to Trash via Finder/`~/.Trash` when possible. Permanent deletion (`rm -rf`) is used only for system caches/logs after confirmation.
- **Logging.** All actions are logged to a timestamped file on your Desktop (or Downloads).
- **No sudo by default.** The script runs without elevated privileges. It asks for `sudo` only when needed (system logs, Time Machine snapshots) and explains why.
- **No external dependencies.** Uses only standard macOS tools (`bash`, `du`, `find`, `df`, `tmutil`, `stat`, `bc`).

## Common Big Wins on Dev Macs

These are the areas that typically reclaim the most space on developer machines:

1. **Xcode DerivedData** (5-30 GB) — Build artifacts that Xcode regenerates. Clearing this is almost always safe and often the single biggest win.

2. **Xcode iOS DeviceSupport** (5-20 GB) — Debug symbols for every iOS version you've connected a device with. Safe to delete; re-downloaded when you next connect that device.

3. **Xcode Simulators** (5-50 GB) — Old simulator runtimes for iOS versions you may no longer target. Use `xcrun simctl delete unavailable`.

4. **Docker Desktop** (10-60 GB) — Unused images and build cache grow silently. `docker system prune -a` is effective but destructive — review first.

5. **~/Library/Caches** (2-10 GB) — App caches that rebuild automatically. Almost always safe to clear entirely.

6. **Homebrew cache** (1-5 GB) — Downloaded archives from `brew install`. `brew cleanup --prune=all` is safe.

7. **npm/yarn/pnpm caches** (1-5 GB) — Package manager download caches. Cleared safely with their respective `cache clean` commands.

8. **Downloads folder** (varies) — Old `.dmg` and `.pkg` installers pile up. Review and trash them.

9. **iOS Backups** (5-50 GB) — Local device backups at `~/Library/Application Support/MobileSync/Backup`. If you use iCloud Backup, these are redundant — but verify first.

10. **Time Machine local snapshots** (5-50 GB) — macOS auto-manages these, but you can thin them if space is critical.

## Requirements

- macOS 12 (Monterey) or later
- Apple Silicon or Intel
- Bash 3.2+ (ships with macOS)
- No external tools required (Homebrew, Docker, Xcode, etc. are checked only if present)

## License

MIT
