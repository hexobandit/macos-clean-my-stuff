#!/usr/bin/env bash
# ============================================================================
# disk-audit.sh — macOS Disk Space Audit + Safe Cleanup
# ============================================================================
# A safety-first tool for understanding and reclaiming disk space on macOS.
#
# DEFAULT MODE: Read-only audit. No files are modified or deleted.
# CLEANUP MODE: Interactive, per-category confirmation. Moves to Trash
#               where possible; uses rm only for clearly safe caches/logs.
#
# Compatible with macOS 12+ (Apple Silicon + Intel).
# Uses only standard macOS tools (bash, du, find, df, tmutil, etc.).
# ============================================================================

set -uo pipefail
# Note: we intentionally do NOT use 'set -e' because du/find/stat will
# return non-zero on permission errors and missing paths, which is expected
# during an audit of directories we may not have access to.

# ---------------------------------------------------------------------------
# Constants & Globals
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly HOME_DIR="$HOME"
readonly TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# Modes
MODE="audit"          # audit | cleanup
SCAN_DEPTH="fast"     # fast | deep
DRY_RUN=false
TOP_N_FILES=25
TOP_N_DIRS=25

# Log file
LOG_DIR="${HOME_DIR}/Desktop"
[[ -d "$LOG_DIR" ]] || LOG_DIR="${HOME_DIR}/Downloads"
[[ -d "$LOG_DIR" ]] || LOG_DIR="${HOME_DIR}"
LOG_FILE="${LOG_DIR}/disk-audit-${TIMESTAMP}.log"

# Accumulators for the summary
declare -a CLEANUP_CATEGORIES=()
declare -a CLEANUP_SIZES=()
declare -a CLEANUP_PATHS=()
declare -a CLEANUP_RISKS=()
declare -a CLEANUP_REASONS=()
declare -a CLEANUP_WARNINGS=()
declare -a CLEANUP_COMMANDS=()

TOTAL_RECLAIMABLE=0

# Colors (disable if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ---------------------------------------------------------------------------
# Protected paths — NEVER touch these
# ---------------------------------------------------------------------------
readonly -a PROTECTED_PATHS=(
    "/System"
    "/usr"
    "/bin"
    "/sbin"
    "/private/var/db"
    "${HOME_DIR}/Documents"
    "${HOME_DIR}/Photos Library.photoslibrary"
    "${HOME_DIR}/Pictures/Photos Library.photoslibrary"
    "${HOME_DIR}/Movies"
    "${HOME_DIR}/Music"
    "${HOME_DIR}/Desktop"
)

# ---------------------------------------------------------------------------
# Utility Functions
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
${BOLD}${SCRIPT_NAME}${RESET} v${SCRIPT_VERSION} — macOS Disk Space Audit + Safe Cleanup

${BOLD}USAGE${RESET}
    $SCRIPT_NAME [OPTIONS]

${BOLD}MODES${RESET}
    (default)       Read-only audit. Reports disk usage, no changes made.
    --cleanup       Interactive cleanup mode. Prompts per category (Y/N).
    --dry-run       Show what --cleanup would do, without doing it.

${BOLD}SCAN DEPTH${RESET}
    --fast           Known hotspots only (default). Fast, covers ~90% of wins.
    --deep           More exhaustive scan of user space. Slower.

${BOLD}OPTIONS${RESET}
    --top N          Show top N largest files/dirs (default: 25)
    --log PATH       Custom log file path
    -h, --help       Show this help message
    -v, --version    Show version

${BOLD}EXAMPLES${RESET}
    $SCRIPT_NAME                        # Quick read-only audit
    $SCRIPT_NAME --deep                 # Thorough audit
    $SCRIPT_NAME --cleanup --dry-run    # Preview cleanup actions
    $SCRIPT_NAME --cleanup              # Interactive cleanup

${BOLD}SAFETY${RESET}
    - Default mode is READ-ONLY. Nothing is modified.
    - Cleanup mode is INTERACTIVE. Every category requires confirmation.
    - Personal content (Documents, Photos, Movies, Music) is NEVER deleted.
    - /System and OS-protected paths are NEVER touched.
    - All actions are logged to: ~/Desktop/disk-audit-<timestamp>.log
EOF
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$LOG_FILE"
}

print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}${BLUE}  $1${RESET}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    log "=== $1 ==="
}

print_subheader() {
    echo ""
    echo -e "${BOLD}${CYAN}  ── $1${RESET}"
    log "--- $1 ---"
}

print_item() {
    echo -e "    $1"
    log "    $(echo "$1" | sed $'s/\033\[[0-9;]*m//g')"
}

print_warning() {
    echo -e "  ${YELLOW}⚠  $1${RESET}"
    log "WARNING: $1"
}

print_error() {
    echo -e "  ${RED}✖  $1${RESET}" >&2
    log "ERROR: $1"
}

print_ok() {
    echo -e "  ${GREEN}✔  $1${RESET}"
    log "OK: $1"
}

print_risk() {
    local level="$1"
    case "$level" in
        LOW)  echo -e "${GREEN}[LOW RISK]${RESET}" ;;
        MED)  echo -e "${YELLOW}[MED RISK]${RESET}" ;;
        HIGH) echo -e "${RED}[HIGH RISK]${RESET}" ;;
        *)    echo "[$level]" ;;
    esac
}

# Format bytes to human-readable
human_size() {
    local bytes="${1:-0}"
    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
        if (( bytes >= 1073741824 )); then
            echo "$(echo "scale=1; $bytes / 1073741824" | bc) GB"
        elif (( bytes >= 1048576 )); then
            echo "$(echo "scale=1; $bytes / 1048576" | bc) MB"
        elif (( bytes >= 1024 )); then
            echo "$(echo "scale=0; $bytes / 1024" | bc) KB"
        else
            echo "${bytes} B"
        fi
    else
        echo "$bytes"
    fi
}

# Get directory size in bytes (returns 0 if inaccessible)
dir_size_bytes() {
    local path="$1"
    if [[ -d "$path" ]] && [[ -r "$path" ]]; then
        # Capture du output first, then extract the number (avoids pipefail issues)
        local raw
        raw=$(du -sk "$path" 2>/dev/null | tail -1) || true
        if [[ -n "$raw" ]]; then
            echo "$raw" | awk '{printf "%d", $1 * 1024}'
        else
            echo "0"
        fi
    else
        echo "0"
    fi
}

# Get directory size human-readable via du -sh
dir_size_human() {
    local path="$1"
    if [[ -d "$path" ]] && [[ -r "$path" ]]; then
        local raw
        raw=$(du -sh "$path" 2>/dev/null | tail -1) || true
        if [[ -n "$raw" ]]; then
            echo "$raw" | awk '{print $1}'
        else
            echo "N/A"
        fi
    else
        echo "N/A"
    fi
}

# Check if a path is protected
is_protected() {
    local path="$1"
    for pp in "${PROTECTED_PATHS[@]}"; do
        if [[ "$path" == "$pp" ]] || [[ "$path" == "$pp"/* ]]; then
            return 0
        fi
    done
    return 1
}

# Confirm action with user
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local reply
    if [[ "$default" == "y" ]]; then
        read -r -p "  $prompt [Y/n]: " reply
        reply="${reply:-y}"
    else
        read -r -p "  $prompt [y/N]: " reply
        reply="${reply:-n}"
    fi
    [[ "$reply" =~ ^[Yy] ]]
}

# Move to Trash (macOS way) or rm as fallback
safe_delete() {
    local path="$1"
    local use_rm="${2:-false}"

    if is_protected "$path"; then
        print_error "REFUSED: '$path' is a protected path. Skipping."
        log "REFUSED deletion of protected path: $path"
        return 1
    fi

    if $DRY_RUN; then
        print_item "${DIM}[DRY RUN] Would delete: $path${RESET}"
        log "[DRY RUN] Would delete: $path"
        return 0
    fi

    if [[ "$use_rm" == "true" ]]; then
        rm -rf "$path" 2>/dev/null && {
            print_ok "Deleted: $path"
            log "DELETED (rm -rf): $path"
        } || {
            print_error "Failed to delete: $path"
            log "FAILED to delete: $path"
        }
    else
        # Use macOS Trash via osascript for user-space items
        if osascript -e "tell application \"Finder\" to delete POSIX file \"$path\"" &>/dev/null; then
            print_ok "Moved to Trash: $path"
            log "TRASHED: $path"
        else
            # Fallback: try mv to ~/.Trash
            if mv "$path" "${HOME_DIR}/.Trash/" 2>/dev/null; then
                print_ok "Moved to Trash: $path"
                log "TRASHED (mv): $path"
            else
                print_warning "Could not trash '$path'. Use rm? This is permanent."
                if confirm "Delete permanently?"; then
                    rm -rf "$path" 2>/dev/null && {
                        print_ok "Deleted: $path"
                        log "DELETED (rm -rf fallback): $path"
                    } || {
                        print_error "Failed to delete: $path"
                        log "FAILED to delete: $path"
                    }
                else
                    print_item "Skipped: $path"
                    log "SKIPPED: $path"
                fi
            fi
        fi
    fi
}

# Register a cleanup candidate
register_candidate() {
    local category="$1"
    local size_bytes="$2"
    local path="$3"
    local risk="$4"
    local reason="$5"
    local warning="$6"
    local command="$7"

    CLEANUP_CATEGORIES+=("$category")
    CLEANUP_SIZES+=("$size_bytes")
    CLEANUP_PATHS+=("$path")
    CLEANUP_RISKS+=("$risk")
    CLEANUP_REASONS+=("$reason")
    CLEANUP_WARNINGS+=("$warning")
    CLEANUP_COMMANDS+=("$command")
    TOTAL_RECLAIMABLE=$((TOTAL_RECLAIMABLE + size_bytes))
}

# ---------------------------------------------------------------------------
# Parse Arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cleanup)
                MODE="cleanup"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                MODE="cleanup"
                shift
                ;;
            --fast)
                SCAN_DEPTH="fast"
                shift
                ;;
            --deep)
                SCAN_DEPTH="deep"
                shift
                ;;
            --top)
                TOP_N_FILES="${2:-25}"
                TOP_N_DIRS="${2:-25}"
                shift 2
                ;;
            --log)
                LOG_FILE="${2:-$LOG_FILE}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                echo "$SCRIPT_NAME v$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Audit Sections
# ---------------------------------------------------------------------------

audit_filesystem_overview() {
    print_header "FILESYSTEM OVERVIEW"

    # APFS/HFS info via df
    echo ""
    df -H / 2>/dev/null | while IFS= read -r line; do
        print_item "$line"
    done

    # Extract key numbers
    local total_line
    total_line=$(df -H / 2>/dev/null | tail -1)
    local total used avail pct
    total=$(echo "$total_line" | awk '{print $2}')
    used=$(echo "$total_line" | awk '{print $3}')
    avail=$(echo "$total_line" | awk '{print $4}')
    pct=$(echo "$total_line" | awk '{print $5}')

    echo ""
    print_item "${BOLD}Disk: ${total} total | ${used} used | ${avail} available | ${pct} used${RESET}"

    # Purgeable space (APFS)
    local purgeable
    purgeable=$(diskutil apfs list 2>/dev/null | grep -i "purgeable" | head -1 | awk -F'(' '{print $2}' | tr -d ')' | xargs 2>/dev/null || echo "")
    if [[ -n "$purgeable" ]]; then
        print_item "${DIM}APFS Purgeable Space: ${purgeable}${RESET}"
    fi
}

audit_top_level_dirs() {
    print_header "TOP-LEVEL DIRECTORY USAGE"

    if [[ "$SCAN_DEPTH" == "fast" ]]; then
        print_item "${DIM}(Skipping deep top-level scan in fast mode. Use --deep for full breakdown.)${RESET}"
        print_item "${DIM}(The Home Directory and System Data sections below cover the key areas.)${RESET}"
        echo ""

        # In fast mode, just report a few quick-to-measure directories
        local quick_dirs=("/Applications" "/opt" "/usr/local")
        for d in "${quick_dirs[@]}"; do
            if [[ -d "$d" ]] && [[ -r "$d" ]]; then
                local size
                size=$(du -sh -d 0 "$d" 2>/dev/null | awk '{print $1}' || echo "N/A")
                printf "    %-30s %s\n" "$d" "$size"
            fi
        done
        printf "    %-30s %s\n" "/System" "(OS-managed, skipped)"
        printf "    %-30s %s\n" "/Library, /Users, /private" "(use --deep to measure)"
    else
        print_item "${DIM}(Deep scan — measuring top-level directories, may take 1-2 min...)${RESET}"
        echo ""

        du -d 1 -h -x / 2>/dev/null | sort -hr | head -15 \
            | while IFS= read -r line; do
                print_item "$line"
                log "$line"
            done

        if [[ -d "/System" ]]; then
            print_item "${DIM}/System                        (skipped — OS-managed, SIP protected)${RESET}"
        fi
    fi
}

audit_home_breakdown() {
    print_header "HOME DIRECTORY BREAKDOWN (~)"

    if [[ "$SCAN_DEPTH" == "fast" ]]; then
        echo ""
        print_item "${DIM}(Fast mode: scanning ~ top-level. Use --deep for ~/Library breakdown.)${RESET}"
        echo ""

        # Single pass: du -d 1 on ~ gives all top-level children in one traversal
        # This takes ~30-60s but is the most useful single view
        du -d 1 -h -x "${HOME_DIR}" 2>/dev/null | sort -hr | head -20 \
            | while IFS= read -r line; do
                [[ -n "$line" ]] && print_item "$line"
            done

        print_item ""
        print_item "${DIM}~/Library is usually the largest. See 'System Data Contributors' below for breakdown.${RESET}"
    else
        echo ""
        print_item "${DIM}(Deep scan — measuring all directories, may take 1-2 min...)${RESET}"
        echo ""
        du -d 1 -h -x "${HOME_DIR}" 2>/dev/null | sort -hr | head -20 \
            | while IFS= read -r line; do
                [[ -n "$line" ]] && print_item "$line"
            done

        print_subheader "~/Library Breakdown (often largest)"
        du -d 1 -h -x "${HOME_DIR}/Library" 2>/dev/null | sort -hr | head -15 \
            | while IFS= read -r line; do
                [[ -n "$line" ]] && print_item "$line"
            done
    fi
}

audit_largest_files() {
    print_header "LARGEST FILES IN USER SPACE (top ${TOP_N_FILES})"

    if [[ "$SCAN_DEPTH" == "fast" ]]; then
        print_item "${DIM}(Scanning known locations — use --deep for full scan)${RESET}"
        echo ""
        # Fast: scan key directories only (filter to those that exist)
        local -a scan_dirs=()
        for d in "${HOME_DIR}/Downloads" "${HOME_DIR}/Desktop" "${HOME_DIR}/Documents" \
                 "${HOME_DIR}/Library/Caches" "${HOME_DIR}/Library/Application Support"; do
            [[ -d "$d" ]] && scan_dirs+=("$d")
        done
        if [[ ${#scan_dirs[@]} -gt 0 ]]; then
            find "${scan_dirs[@]}" \
                 -maxdepth 4 -type f -size +50M 2>/dev/null \
                | while read -r f; do
                    local sz
                    sz=$(stat -f%z "$f" 2>/dev/null || echo "0")
                    echo "$sz $f"
                done \
                | sort -rn | head -"${TOP_N_FILES}" \
                | while read -r sz path; do
                    printf "    %-12s %s\n" "$(human_size "$sz")" "$path"
                done
        else
            print_item "${DIM}No scannable directories found.${RESET}"
        fi
    else
        print_item "${DIM}(Deep scan of ~ — this may take a minute...)${RESET}"
        echo ""
        find "${HOME_DIR}" -xdev -maxdepth 6 -type f -size +50M 2>/dev/null \
            | while read -r f; do
                local sz
                sz=$(stat -f%z "$f" 2>/dev/null || echo "0")
                echo "$sz $f"
            done \
            | sort -rn | head -"${TOP_N_FILES}" \
            | while read -r sz path; do
                printf "    %-12s %s\n" "$(human_size "$sz")" "$path"
            done
    fi
}

audit_largest_dirs() {
    print_header "LARGEST DIRECTORIES IN USER SPACE (top ${TOP_N_DIRS})"

    if [[ "$SCAN_DEPTH" == "fast" ]]; then
        print_item "${DIM}(Scanning known locations — use --deep for full scan)${RESET}"
        echo ""
        # Use du -d 1 on key directories (avoids glob expansion issues)
        {
            for d in "${HOME_DIR}/Library/Caches" \
                     "${HOME_DIR}/Library/Application Support" \
                     "${HOME_DIR}/Library/Developer" \
                     "${HOME_DIR}/Library/Containers" \
                     "${HOME_DIR}/Library/Group Containers" \
                     "${HOME_DIR}/Downloads" \
                     "${HOME_DIR}/.Trash"; do
                [[ -d "$d" ]] && du -d 1 -h "$d" 2>/dev/null
            done
        } | sort -hr | head -"${TOP_N_DIRS}" \
            | while IFS= read -r line; do
                print_item "$line"
            done
    else
        print_item "${DIM}(Deep scan — this may take a minute...)${RESET}"
        echo ""
        du -sh "${HOME_DIR}"/*/ "${HOME_DIR}"/.[!.]*/ 2>/dev/null \
            | sort -hr | head -"${TOP_N_DIRS}" \
            | while IFS= read -r line; do
                print_item "$line"
            done
    fi
}

audit_system_data() {
    print_header "SYSTEM DATA CONTRIBUTORS"
    print_item "${DIM}(These are common contributors to macOS 'System Data' in storage)${RESET}"
    echo ""

    local -a sd_paths=(
        "${HOME_DIR}/Library/Caches:User Caches"
        "${HOME_DIR}/Library/Logs:User Logs"
        "/Library/Caches:System Caches"
        "/private/var/log:System Logs"
        "/private/var/folders:Temporary Items"
        "/private/var/vm:Virtual Memory (swap)"
        "${HOME_DIR}/Library/Application Support/MobileSync:iOS Backups"
        "${HOME_DIR}/Library/Developer:Developer Tools"
        "${HOME_DIR}/Library/Containers:App Containers (Sandboxed)"
        "${HOME_DIR}/Library/Group Containers:App Group Containers"
        "${HOME_DIR}/.Trash:Trash"
    )

    for entry in "${sd_paths[@]}"; do
        local path="${entry%%:*}"
        local label="${entry##*:}"
        if [[ -d "$path" ]]; then
            local size
            size=$(dir_size_human "$path")
            printf "    %-12s %-40s %s\n" "$size" "$label" "${DIM}$path${RESET}"
        fi
    done

    # Time Machine local snapshots
    print_subheader "Time Machine Local Snapshots"
    if command -v tmutil &>/dev/null; then
        local snapshots
        snapshots=$(tmutil listlocalsnapshots / 2>/dev/null || echo "")
        local count=0
        if [[ -n "$snapshots" ]]; then
            count=$(echo "$snapshots" | grep -c "com.apple" 2>/dev/null || true)
            # Ensure count is a clean integer
            count=$(echo "$count" | tr -d '[:space:]')
            [[ "$count" =~ ^[0-9]+$ ]] || count=0
        fi
        if (( count > 0 )); then
            print_item "Found ${BOLD}${count}${RESET} local snapshot(s)"
            echo "$snapshots" | grep "com.apple" | head -5 | while IFS= read -r line; do
                print_item "  ${DIM}$line${RESET}"
            done
            if (( count > 5 )); then
                print_item "  ${DIM}... and $((count - 5)) more${RESET}"
            fi
            print_item "${DIM}Note: macOS manages these automatically; deleting frees space immediately.${RESET}"
        else
            print_ok "No local snapshots found."
        fi
    else
        print_item "${DIM}tmutil not available${RESET}"
    fi
}

# ---------------------------------------------------------------------------
# Cleanup Candidate Checks
# ---------------------------------------------------------------------------

check_trash() {
    print_subheader "Trash"
    local trash_path="${HOME_DIR}/.Trash"
    if [[ -d "$trash_path" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$trash_path")
        if (( size_bytes > 1048576 )); then
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} in Trash $(print_risk LOW)"
            register_candidate \
                "Trash" \
                "$size_bytes" \
                "$trash_path" \
                "LOW" \
                "Already deleted by user; sitting in Trash." \
                "None — these are already-deleted items." \
                "rm -rf ${HOME_DIR}/.Trash/*"
        else
            print_ok "Trash is small or empty."
        fi
    fi
}

check_user_caches() {
    print_subheader "User Caches (~/Library/Caches)"
    local cache_path="${HOME_DIR}/Library/Caches"
    if [[ -d "$cache_path" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$cache_path")
        if (( size_bytes > 104857600 )); then  # > 100 MB
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} total in ~/Library/Caches $(print_risk LOW)"
            print_item "${DIM}Apps rebuild caches as needed. Safe to delete.${RESET}"

            # Show top subdirectories
            du -sh "$cache_path"/* 2>/dev/null | sort -hr | head -5 \
                | while IFS= read -r line; do print_item "  $line"; done

            register_candidate \
                "User Caches" \
                "$size_bytes" \
                "$cache_path" \
                "LOW" \
                "Application caches; rebuilt automatically on next use." \
                "Apps may be slightly slower on first launch after clearing." \
                "rm -rf ${HOME_DIR}/Library/Caches/*"
        else
            print_ok "User caches are small ($(human_size "$size_bytes"))."
        fi
    fi
}

check_user_logs() {
    print_subheader "User Logs (~/Library/Logs)"
    local log_path="${HOME_DIR}/Library/Logs"
    if [[ -d "$log_path" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$log_path")
        if (( size_bytes > 52428800 )); then  # > 50 MB
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} in ~/Library/Logs $(print_risk LOW)"

            register_candidate \
                "User Logs" \
                "$size_bytes" \
                "$log_path" \
                "LOW" \
                "Application log files; macOS and apps recreate as needed." \
                "Lose historical logs for debugging. Usually unimportant." \
                "rm -rf ${HOME_DIR}/Library/Logs/*"
        else
            print_ok "User logs are small ($(human_size "$size_bytes"))."
        fi
    fi
}

check_system_logs() {
    print_subheader "System Logs (/private/var/log)"
    local syslog="/private/var/log"
    if [[ -d "$syslog" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$syslog")
        if (( size_bytes > 104857600 )); then
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} in /private/var/log $(print_risk MED)"
            print_item "${DIM}macOS rotates these automatically. Requires sudo to clean.${RESET}"

            register_candidate \
                "System Logs" \
                "$size_bytes" \
                "$syslog" \
                "MED" \
                "System log files; macOS rotates these via newsyslog/ASL." \
                "Requires sudo. macOS will recreate. Lose historical diagnostic data." \
                "sudo rm -rf /private/var/log/asl/*.asl"
        else
            print_ok "System logs are manageable ($(human_size "$size_bytes"))."
        fi
    fi
}

check_xcode() {
    print_subheader "Xcode / Developer Tools"

    # DerivedData
    local dd="${HOME_DIR}/Library/Developer/Xcode/DerivedData"
    if [[ -d "$dd" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$dd")
        if (( size_bytes > 104857600 )); then
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} in Xcode DerivedData $(print_risk LOW)"
            register_candidate \
                "Xcode DerivedData" \
                "$size_bytes" \
                "$dd" \
                "LOW" \
                "Build artifacts; Xcode rebuilds on next build." \
                "Next build will be slower (clean build)." \
                "rm -rf '${dd}'"
        fi
    fi

    # Archives
    local archives="${HOME_DIR}/Library/Developer/Xcode/Archives"
    if [[ -d "$archives" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$archives")
        if (( size_bytes > 104857600 )); then
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} in Xcode Archives $(print_risk MED)"
            register_candidate \
                "Xcode Archives" \
                "$size_bytes" \
                "$archives" \
                "MED" \
                "Old app build archives for distribution." \
                "Cannot re-submit old builds to App Store without re-archiving." \
                "rm -rf '${archives}'"
        fi
    fi

    # iOS DeviceSupport
    local devsup="${HOME_DIR}/Library/Developer/Xcode/iOS DeviceSupport"
    if [[ -d "$devsup" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$devsup")
        if (( size_bytes > 524288000 )); then
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} in iOS DeviceSupport $(print_risk LOW)"
            register_candidate \
                "Xcode iOS DeviceSupport" \
                "$size_bytes" \
                "$devsup" \
                "LOW" \
                "Debug symbols for connected iOS devices; re-downloaded on connect." \
                "First device debug session after cleanup will be slower." \
                "rm -rf '${devsup}'"
        fi
    fi

    # Simulators
    if command -v xcrun &>/dev/null; then
        local sim_path="${HOME_DIR}/Library/Developer/CoreSimulator"
        if [[ -d "$sim_path" ]]; then
            local size_bytes
            size_bytes=$(dir_size_bytes "$sim_path")
            if (( size_bytes > 1073741824 )); then
                local size_human
                size_human=$(human_size "$size_bytes")
                print_item "${BOLD}${size_human}${RESET} in CoreSimulator (Simulators) $(print_risk LOW)"
                # Count unavailable simulators
                local unavail
                unavail=$(xcrun simctl list devices unavailable 2>/dev/null | grep -c "unavailable" || true)
                unavail=$(echo "$unavail" | tr -d '[:space:]')
                [[ "$unavail" =~ ^[0-9]+$ ]] || unavail=0
                if (( unavail > 0 )); then
                    print_item "${DIM}$unavail unavailable simulator(s) can be safely removed.${RESET}"
                fi
                register_candidate \
                    "Xcode Simulators (unavailable)" \
                    "$size_bytes" \
                    "$sim_path" \
                    "LOW" \
                    "Old simulator runtimes for iOS versions you no longer target." \
                    "Need to re-download if you target those OS versions again." \
                    "xcrun simctl delete unavailable"
            fi
        fi
    fi

    # Xcode Caches
    local xc_cache="${HOME_DIR}/Library/Caches/com.apple.dt.Xcode"
    if [[ -d "$xc_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$xc_cache")
        if (( size_bytes > 104857600 )); then
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} in Xcode caches $(print_risk LOW)"
            register_candidate \
                "Xcode Caches" \
                "$size_bytes" \
                "$xc_cache" \
                "LOW" \
                "Xcode build caches; rebuilt automatically." \
                "None significant." \
                "rm -rf '${xc_cache}'"
        fi
    fi

    if [[ ! -d "$dd" ]] && [[ ! -d "$archives" ]] && [[ ! -d "$devsup" ]]; then
        print_ok "Xcode not detected or minimal footprint."
    fi
}

check_homebrew() {
    print_subheader "Homebrew"
    if command -v brew &>/dev/null; then
        local brew_cache
        brew_cache=$(brew --cache 2>/dev/null || echo "")
        if [[ -n "$brew_cache" ]] && [[ -d "$brew_cache" ]]; then
            local size_bytes
            size_bytes=$(dir_size_bytes "$brew_cache")
            if (( size_bytes > 104857600 )); then
                local size_human
                size_human=$(human_size "$size_bytes")
                print_item "${BOLD}${size_human}${RESET} in Homebrew cache $(print_risk LOW)"
                register_candidate \
                    "Homebrew Cache" \
                    "$size_bytes" \
                    "$brew_cache" \
                    "LOW" \
                    "Downloaded package archives; re-downloaded on install." \
                    "None. Run 'brew cleanup' for a targeted approach." \
                    "brew cleanup --prune=all"
            else
                print_ok "Homebrew cache is small ($(human_size "$size_bytes"))."
            fi
        fi
    else
        print_item "${DIM}Homebrew not installed.${RESET}"
    fi
}

check_docker() {
    print_subheader "Docker"
    if command -v docker &>/dev/null; then
        # Check if Docker daemon is running
        if docker info &>/dev/null; then
            local docker_df
            docker_df=$(docker system df 2>/dev/null || echo "")
            if [[ -n "$docker_df" ]]; then
                print_item "${BOLD}Docker disk usage:${RESET}"
                echo "$docker_df" | while IFS= read -r line; do
                    print_item "  $line"
                done

                local reclaimable
                reclaimable=$(docker system df 2>/dev/null | tail -n +2 | awk '{sum += $NF} END {printf "%.0f\n", sum}' || echo "0")

                # Docker Desktop VM disk
                local docker_vm="${HOME_DIR}/Library/Containers/com.docker.docker"
                if [[ -d "$docker_vm" ]]; then
                    local vm_size
                    vm_size=$(dir_size_bytes "$docker_vm")
                    local vm_human
                    vm_human=$(human_size "$vm_size")
                    print_item "Docker Desktop VM: ${BOLD}${vm_human}${RESET}"
                fi

                echo ""
                print_item "${RED}${BOLD}⚠ CAUTION:${RESET} Docker prune deletes unused images, containers, volumes."
                print_item "${DIM}This is HIGH RISK if you have important data in Docker volumes.${RESET}"

                register_candidate \
                    "Docker (prune)" \
                    "0" \
                    "docker system" \
                    "HIGH" \
                    "Remove unused Docker images, containers, and build cache." \
                    "DESTROYS unused containers, images, and potentially volumes with data." \
                    "docker system prune -a  # Add --volumes only if you're sure"
            fi
        else
            print_item "${DIM}Docker installed but daemon not running.${RESET}"
            # Still check Docker Desktop disk image
            local docker_vm="${HOME_DIR}/Library/Containers/com.docker.docker"
            if [[ -d "$docker_vm" ]]; then
                local vm_size
                vm_size=$(dir_size_bytes "$docker_vm")
                local vm_human
                vm_human=$(human_size "$vm_size")
                print_item "Docker Desktop data: ${BOLD}${vm_human}${RESET} at $docker_vm"
            fi
        fi
    else
        print_item "${DIM}Docker not installed.${RESET}"
    fi
}

check_node() {
    print_subheader "Node.js / npm / yarn / pnpm"

    local total_node=0

    # npm cache
    local npm_cache="${HOME_DIR}/.npm"
    if [[ -d "$npm_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$npm_cache")
        total_node=$((total_node + size_bytes))
        if (( size_bytes > 104857600 )); then
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} in npm cache (~/.npm) $(print_risk LOW)"
            register_candidate \
                "npm Cache" \
                "$size_bytes" \
                "$npm_cache" \
                "LOW" \
                "npm package cache; re-downloaded as needed." \
                "Slightly slower first npm install." \
                "npm cache clean --force"
        fi
    fi

    # Yarn cache
    local yarn_cache=""
    if command -v yarn &>/dev/null; then
        yarn_cache=$(yarn cache dir 2>/dev/null || echo "")
    fi
    # Fallback common paths
    for yc in "$yarn_cache" "${HOME_DIR}/Library/Caches/Yarn" "${HOME_DIR}/.cache/yarn"; do
        if [[ -n "$yc" ]] && [[ -d "$yc" ]]; then
            local size_bytes
            size_bytes=$(dir_size_bytes "$yc")
            total_node=$((total_node + size_bytes))
            if (( size_bytes > 104857600 )); then
                local size_human
                size_human=$(human_size "$size_bytes")
                print_item "${BOLD}${size_human}${RESET} in Yarn cache $(print_risk LOW)"
                register_candidate \
                    "Yarn Cache" \
                    "$size_bytes" \
                    "$yc" \
                    "LOW" \
                    "Yarn package cache; re-downloaded as needed." \
                    "Slightly slower first yarn install." \
                    "yarn cache clean"
            fi
            break
        fi
    done

    # pnpm store
    local pnpm_store="${HOME_DIR}/Library/pnpm/store"
    [[ -d "$pnpm_store" ]] || pnpm_store="${HOME_DIR}/.local/share/pnpm/store"
    if [[ -d "$pnpm_store" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$pnpm_store")
        total_node=$((total_node + size_bytes))
        if (( size_bytes > 104857600 )); then
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} in pnpm store $(print_risk LOW)"
            register_candidate \
                "pnpm Store" \
                "$size_bytes" \
                "$pnpm_store" \
                "LOW" \
                "pnpm content-addressable store; re-downloaded as needed." \
                "Slower first pnpm install after clearing." \
                "pnpm store prune"
        fi
    fi

    # node_modules scan (deep mode only)
    if [[ "$SCAN_DEPTH" == "deep" ]]; then
        print_item "${DIM}Scanning for node_modules directories...${RESET}"
        local nm_total=0
        local nm_count=0
        while IFS= read -r nm_dir; do
            local sz
            sz=$(du -sk "$nm_dir" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
            nm_total=$((nm_total + sz))
            nm_count=$((nm_count + 1))
        done < <(find "${HOME_DIR}" -maxdepth 5 -name "node_modules" -type d -not -path "*/.*" 2>/dev/null)

        if (( nm_count > 0 )); then
            print_item "${BOLD}$(human_size "$nm_total")${RESET} across ${nm_count} node_modules directories"
            print_item "${DIM}Tip: Use 'npx npkill' to interactively remove old node_modules.${RESET}"
        fi
    fi

    if (( total_node < 104857600 )); then
        print_ok "Node.js caches are small or not present."
    fi
}

check_python() {
    print_subheader "Python"

    # pip cache
    local pip_cache="${HOME_DIR}/Library/Caches/pip"
    if [[ -d "$pip_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$pip_cache")
        if (( size_bytes > 52428800 )); then
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} in pip cache $(print_risk LOW)"
            register_candidate \
                "pip Cache" \
                "$size_bytes" \
                "$pip_cache" \
                "LOW" \
                "pip download cache; packages re-downloaded on install." \
                "Slower first pip install." \
                "pip cache purge"
        fi
    fi

    # conda
    local conda_pkgs="${HOME_DIR}/.conda/pkgs"
    if [[ -d "$conda_pkgs" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$conda_pkgs")
        if (( size_bytes > 524288000 )); then
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} in conda packages $(print_risk MED)"
            register_candidate \
                "Conda Package Cache" \
                "$size_bytes" \
                "$conda_pkgs" \
                "MED" \
                "Conda cached packages; re-downloaded on install." \
                "Slower environment creation. Verify no env depends on cached pkgs." \
                "conda clean --all"
        fi
    fi

    # Virtual environments in common locations
    if [[ "$SCAN_DEPTH" == "deep" ]]; then
        print_item "${DIM}Scanning for Python virtual environments...${RESET}"
        local venv_total=0
        local venv_count=0
        while IFS= read -r vdir; do
            local sz
            sz=$(du -sk "$(dirname "$vdir")" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
            venv_total=$((venv_total + sz))
            venv_count=$((venv_count + 1))
        done < <(find "${HOME_DIR}" -maxdepth 5 \( -name "pyvenv.cfg" -o -name ".venv" \) -not -path "*/.*/.venv" 2>/dev/null | head -50)

        if (( venv_count > 0 )); then
            print_item "${BOLD}$(human_size "$venv_total")${RESET} across ~${venv_count} virtual environments"
        fi
    fi

    if [[ ! -d "$pip_cache" ]] && [[ ! -d "$conda_pkgs" ]]; then
        print_ok "Python caches not found or minimal."
    fi
}

check_browsers() {
    print_subheader "Browser Caches"

    # Chrome
    local chrome_cache="${HOME_DIR}/Library/Caches/Google/Chrome"
    local chrome_profile="${HOME_DIR}/Library/Application Support/Google/Chrome"
    if [[ -d "$chrome_cache" ]] || [[ -d "$chrome_profile" ]]; then
        local cache_sz=0
        [[ -d "$chrome_cache" ]] && cache_sz=$(dir_size_bytes "$chrome_cache")
        local profile_cache=0
        if [[ -d "$chrome_profile/Default/Cache" ]]; then
            profile_cache=$(dir_size_bytes "$chrome_profile/Default/Cache")
        fi
        local total_chrome=$((cache_sz + profile_cache))
        if (( total_chrome > 209715200 )); then
            print_item "${BOLD}$(human_size "$total_chrome")${RESET} in Chrome caches $(print_risk LOW)"
            register_candidate \
                "Chrome Cache" \
                "$total_chrome" \
                "$chrome_cache" \
                "LOW" \
                "Browser cache files; rebuilt as you browse." \
                "Websites load slightly slower on first visit. Sessions/logins preserved." \
                "rm -rf '${HOME_DIR}/Library/Caches/Google/Chrome' '${chrome_profile}/Default/Cache' '${chrome_profile}/Default/Code Cache'"
        fi
    fi

    # Brave
    local brave_cache="${HOME_DIR}/Library/Caches/BraveSoftware/Brave-Browser"
    local brave_profile="${HOME_DIR}/Library/Application Support/BraveSoftware/Brave-Browser"
    if [[ -d "$brave_cache" ]] || [[ -d "$brave_profile" ]]; then
        local cache_sz=0
        [[ -d "$brave_cache" ]] && cache_sz=$(dir_size_bytes "$brave_cache")
        local profile_cache=0
        if [[ -d "$brave_profile/Default/Cache" ]]; then
            profile_cache=$(dir_size_bytes "$brave_profile/Default/Cache")
        fi
        local total_brave=$((cache_sz + profile_cache))
        if (( total_brave > 209715200 )); then
            print_item "${BOLD}$(human_size "$total_brave")${RESET} in Brave caches $(print_risk LOW)"
            register_candidate \
                "Brave Cache" \
                "$total_brave" \
                "$brave_cache" \
                "LOW" \
                "Browser cache files; rebuilt as you browse." \
                "Websites load slightly slower on first visit. Sessions/logins preserved." \
                "rm -rf '${brave_cache}' '${brave_profile}/Default/Cache' '${brave_profile}/Default/Code Cache'"
        fi
    fi

    # Firefox
    local firefox_profiles="${HOME_DIR}/Library/Caches/Firefox/Profiles"
    if [[ -d "$firefox_profiles" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$firefox_profiles")
        if (( size_bytes > 209715200 )); then
            print_item "${BOLD}$(human_size "$size_bytes")${RESET} in Firefox caches $(print_risk LOW)"
            register_candidate \
                "Firefox Cache" \
                "$size_bytes" \
                "$firefox_profiles" \
                "LOW" \
                "Browser cache files; rebuilt as you browse." \
                "Websites load slightly slower on first visit." \
                "rm -rf '${firefox_profiles}'"
        fi
    fi

    # Safari (be cautious)
    local safari_cache="${HOME_DIR}/Library/Caches/com.apple.Safari"
    if [[ -d "$safari_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$safari_cache")
        if (( size_bytes > 209715200 )); then
            print_item "${BOLD}$(human_size "$size_bytes")${RESET} in Safari caches $(print_risk MED)"
            print_item "${DIM}Safari caches are tightly integrated. Prefer clearing via Safari > Develop > Empty Caches.${RESET}"
            register_candidate \
                "Safari Cache" \
                "$size_bytes" \
                "$safari_cache" \
                "MED" \
                "Safari web cache; rebuilt as you browse." \
                "Prefer clearing through Safari settings to avoid issues." \
                "rm -rf '${safari_cache}'"
        fi
    fi
}

check_mail() {
    print_subheader "Mail"
    local mail_data="${HOME_DIR}/Library/Mail"
    local mail_dl="${HOME_DIR}/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    if [[ -d "$mail_data" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$mail_data")
        local size_human
        size_human=$(human_size "$size_bytes")
        print_item "${BOLD}${size_human}${RESET} in Mail data $(print_risk HIGH)"
        print_item "${RED}${BOLD}DO NOT delete Mail data directly.${RESET}"
        print_item "${DIM}To reduce: remove old accounts, delete large emails, or use server-side mail (IMAP).${RESET}"
    fi
    if [[ -d "$mail_dl" ]]; then
        local dl_size
        dl_size=$(dir_size_bytes "$mail_dl")
        if (( dl_size > 52428800 )); then
            print_item "${BOLD}$(human_size "$dl_size")${RESET} in Mail Downloads $(print_risk LOW)"
            register_candidate \
                "Mail Downloads" \
                "$dl_size" \
                "$mail_dl" \
                "LOW" \
                "Cached mail attachment previews; re-downloaded from server." \
                "Attachments will need to be re-downloaded if opened again." \
                "rm -rf '${mail_dl}'"
        fi
    fi
}

check_ios_backups() {
    print_subheader "iOS Backups"
    local backup_path="${HOME_DIR}/Library/Application Support/MobileSync/Backup"
    if [[ -d "$backup_path" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$backup_path")
        if (( size_bytes > 1073741824 )); then
            local size_human
            size_human=$(human_size "$size_bytes")
            print_item "${BOLD}${size_human}${RESET} in iOS device backups $(print_risk HIGH)"
            print_item "${DIM}Path: $backup_path${RESET}"
            # Count individual backups
            local backup_count
            backup_count=$(find "$backup_path" -maxdepth 1 -type d | wc -l | tr -d ' ')
            backup_count=$((backup_count - 1))
            print_item "${DIM}Found $backup_count backup(s). Review in Finder > iPhone settings.${RESET}"
            print_item "${RED}WARNING: Deleting backups is IRREVERSIBLE. Ensure iCloud backup is enabled first.${RESET}"
            register_candidate \
                "iOS Backups" \
                "$size_bytes" \
                "$backup_path" \
                "HIGH" \
                "Local iOS device backups." \
                "PERMANENT data loss if no iCloud/other backup exists." \
                "# Review individual backups in Finder or: rm -rf '${backup_path}/<device-uuid>'"
        fi
    else
        print_ok "No iOS backups found."
    fi
}

check_downloads() {
    print_subheader "Downloads — Large Files & Installers"
    local dl_path="${HOME_DIR}/Downloads"
    if [[ -d "$dl_path" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$dl_path")
        local size_human
        size_human=$(human_size "$size_bytes")
        print_item "${BOLD}${size_human}${RESET} total in ~/Downloads"

        # Find DMGs
        local dmg_total=0
        local dmg_list=""
        while IFS= read -r f; do
            local sz
            sz=$(stat -f%z "$f" 2>/dev/null || echo "0")
            dmg_total=$((dmg_total + sz))
            dmg_list+="  $(human_size "$sz")  $f"$'\n'
        done < <(find "$dl_path" -maxdepth 2 -iname "*.dmg" -type f 2>/dev/null)

        if (( dmg_total > 52428800 )); then
            print_item "${BOLD}$(human_size "$dmg_total")${RESET} in .dmg files $(print_risk LOW)"
            echo "$dmg_list" | head -5 | while IFS= read -r line; do
                [[ -n "$line" ]] && print_item "${DIM}$line${RESET}"
            done
            register_candidate \
                "DMG Installers" \
                "$dmg_total" \
                "${dl_path}/*.dmg" \
                "LOW" \
                "Disk image installers; already installed or no longer needed." \
                "Re-download from vendor if needed." \
                "find '${dl_path}' -maxdepth 2 -iname '*.dmg' -delete"
        fi

        # Find PKGs
        local pkg_total=0
        while IFS= read -r f; do
            local sz
            sz=$(stat -f%z "$f" 2>/dev/null || echo "0")
            pkg_total=$((pkg_total + sz))
        done < <(find "$dl_path" -maxdepth 2 -iname "*.pkg" -type f 2>/dev/null)

        if (( pkg_total > 52428800 )); then
            print_item "${BOLD}$(human_size "$pkg_total")${RESET} in .pkg files $(print_risk LOW)"
            register_candidate \
                "PKG Installers" \
                "$pkg_total" \
                "${dl_path}/*.pkg" \
                "LOW" \
                "Package installers; typically not needed after installation." \
                "Re-download from vendor if needed." \
                "find '${dl_path}' -maxdepth 2 -iname '*.pkg' -delete"
        fi

        # Find ZIPs > 100MB
        local zip_total=0
        while IFS= read -r f; do
            local sz
            sz=$(stat -f%z "$f" 2>/dev/null || echo "0")
            zip_total=$((zip_total + sz))
        done < <(find "$dl_path" -maxdepth 2 -iname "*.zip" -type f -size +100M 2>/dev/null)

        if (( zip_total > 104857600 )); then
            print_item "${BOLD}$(human_size "$zip_total")${RESET} in large .zip files $(print_risk MED)"
            register_candidate \
                "Large ZIPs in Downloads" \
                "$zip_total" \
                "${dl_path}/*.zip (>100MB)" \
                "MED" \
                "Large archive files in Downloads; review before deleting." \
                "May contain important files. Review individually." \
                "find '${dl_path}' -maxdepth 2 -iname '*.zip' -size +100M"
        fi

        # Old files (> 90 days, > 50MB) — report only
        if [[ "$SCAN_DEPTH" == "deep" ]]; then
            print_item ""
            print_item "${DIM}Files in Downloads older than 90 days and larger than 50MB:${RESET}"
            find "$dl_path" -maxdepth 2 -type f -mtime +90 -size +50M 2>/dev/null \
                | while read -r f; do
                    local sz
                    sz=$(stat -f%z "$f" 2>/dev/null || echo "0")
                    printf "    %-12s %s\n" "$(human_size "$sz")" "$(basename "$f")"
                done | sort -hr | head -10
        fi
    fi
}

check_time_machine() {
    print_subheader "Time Machine Local Snapshots"
    if command -v tmutil &>/dev/null; then
        local snapshots
        snapshots=$(tmutil listlocalsnapshots / 2>/dev/null || echo "")
        local count=0
        if [[ -n "$snapshots" ]]; then
            count=$(echo "$snapshots" | grep -c "com.apple" 2>/dev/null || true)
            count=$(echo "$count" | tr -d '[:space:]')
            [[ "$count" =~ ^[0-9]+$ ]] || count=0
        fi
        if (( count > 0 )); then
            print_item "Found ${BOLD}${count}${RESET} local snapshot(s) $(print_risk MED)"
            echo "$snapshots" | grep "com.apple" | head -5 | while IFS= read -r s; do
                print_item "  ${DIM}$s${RESET}"
            done

            # We can't easily determine total size of snapshots without sudo/APFS tools
            # Estimate: report that they exist and may consume significant space
            print_item "${DIM}Snapshots can consume many GB. macOS deletes them when space is low.${RESET}"
            print_item "${DIM}To delete one: sudo tmutil deletelocalsnapshots <date>${RESET}"

            register_candidate \
                "Time Machine Snapshots" \
                "0" \
                "/ (local snapshots)" \
                "MED" \
                "Local Time Machine snapshots; macOS auto-manages but they can be large." \
                "Requires sudo. May lose point-in-time recovery for those dates." \
                "sudo tmutil deletelocalsnapshots <date>  # or: sudo tmutil thinlocalsnapshots / 9999999999 4"
        else
            print_ok "No local snapshots found."
        fi
    fi
}

check_misc() {
    print_subheader "Miscellaneous"

    # Spotify cache
    local spotify_cache="${HOME_DIR}/Library/Application Support/Spotify/PersistentCache"
    [[ -d "$spotify_cache" ]] || spotify_cache="${HOME_DIR}/Library/Caches/com.spotify.client"
    if [[ -d "$spotify_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$spotify_cache")
        if (( size_bytes > 524288000 )); then
            print_item "${BOLD}$(human_size "$size_bytes")${RESET} in Spotify cache $(print_risk LOW)"
            register_candidate \
                "Spotify Cache" \
                "$size_bytes" \
                "$spotify_cache" \
                "LOW" \
                "Offline music cache; Spotify re-downloads as needed." \
                "Previously cached/downloaded songs will need to re-download." \
                "rm -rf '${spotify_cache}'"
        fi
    fi

    # Slack cache
    local slack_cache="${HOME_DIR}/Library/Application Support/Slack/Cache"
    [[ -d "$slack_cache" ]] || slack_cache="${HOME_DIR}/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/Cache"
    if [[ -d "$slack_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$slack_cache")
        if (( size_bytes > 209715200 )); then
            print_item "${BOLD}$(human_size "$size_bytes")${RESET} in Slack cache $(print_risk LOW)"
            register_candidate \
                "Slack Cache" \
                "$size_bytes" \
                "$slack_cache" \
                "LOW" \
                "Slack cached files; re-downloaded from Slack servers." \
                "None significant; images/files reload from server." \
                "rm -rf '${slack_cache}'"
        fi
    fi

    # Discord cache
    local discord_cache="${HOME_DIR}/Library/Application Support/discord/Cache"
    if [[ -d "$discord_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$discord_cache")
        if (( size_bytes > 209715200 )); then
            print_item "${BOLD}$(human_size "$size_bytes")${RESET} in Discord cache $(print_risk LOW)"
            register_candidate \
                "Discord Cache" \
                "$size_bytes" \
                "$discord_cache" \
                "LOW" \
                "Discord cached media; re-downloaded from servers." \
                "None significant." \
                "rm -rf '${discord_cache}'"
        fi
    fi

    # Composer (PHP)
    local composer_cache="${HOME_DIR}/.composer/cache"
    [[ -d "$composer_cache" ]] || composer_cache="${HOME_DIR}/.cache/composer"
    if [[ -d "$composer_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$composer_cache")
        if (( size_bytes > 104857600 )); then
            print_item "${BOLD}$(human_size "$size_bytes")${RESET} in Composer cache $(print_risk LOW)"
            register_candidate \
                "Composer Cache" \
                "$size_bytes" \
                "$composer_cache" \
                "LOW" \
                "PHP Composer package cache; re-downloaded on install." \
                "Slower first composer install." \
                "composer clear-cache"
        fi
    fi

    # Gradle
    local gradle_cache="${HOME_DIR}/.gradle/caches"
    if [[ -d "$gradle_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$gradle_cache")
        if (( size_bytes > 524288000 )); then
            print_item "${BOLD}$(human_size "$size_bytes")${RESET} in Gradle caches $(print_risk LOW)"
            register_candidate \
                "Gradle Cache" \
                "$size_bytes" \
                "$gradle_cache" \
                "LOW" \
                "Gradle build cache; rebuilt/re-downloaded on build." \
                "First build after clearing is slower." \
                "rm -rf '${gradle_cache}'"
        fi
    fi

    # CocoaPods
    local pods_cache="${HOME_DIR}/Library/Caches/CocoaPods"
    if [[ -d "$pods_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$pods_cache")
        if (( size_bytes > 209715200 )); then
            print_item "${BOLD}$(human_size "$size_bytes")${RESET} in CocoaPods cache $(print_risk LOW)"
            register_candidate \
                "CocoaPods Cache" \
                "$size_bytes" \
                "$pods_cache" \
                "LOW" \
                "CocoaPods spec and pod cache; re-downloaded on pod install." \
                "Slower first pod install." \
                "pod cache clean --all"
        fi
    fi

    # Ruby gems
    local gem_cache="${HOME_DIR}/.gem"
    if [[ -d "$gem_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$gem_cache")
        if (( size_bytes > 209715200 )); then
            print_item "${BOLD}$(human_size "$size_bytes")${RESET} in Ruby gem cache $(print_risk LOW)"
            register_candidate \
                "Ruby Gem Cache" \
                "$size_bytes" \
                "$gem_cache" \
                "LOW" \
                "Cached Ruby gems; re-downloaded on install." \
                "Slower first gem install." \
                "gem cleanup"
        fi
    fi

    # Go module cache
    local go_cache="${HOME_DIR}/go/pkg/mod/cache"
    [[ -d "$go_cache" ]] || go_cache="${HOME_DIR}/Library/Caches/go-build"
    if [[ -d "$go_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$go_cache")
        if (( size_bytes > 209715200 )); then
            print_item "${BOLD}$(human_size "$size_bytes")${RESET} in Go module/build cache $(print_risk LOW)"
            register_candidate \
                "Go Cache" \
                "$size_bytes" \
                "$go_cache" \
                "LOW" \
                "Go module downloads and build cache; re-downloaded on build." \
                "Slower first build." \
                "go clean -cache -modcache"
        fi
    fi

    # Rust/Cargo
    local cargo_cache="${HOME_DIR}/.cargo/registry"
    if [[ -d "$cargo_cache" ]]; then
        local size_bytes
        size_bytes=$(dir_size_bytes "$cargo_cache")
        if (( size_bytes > 209715200 )); then
            print_item "${BOLD}$(human_size "$size_bytes")${RESET} in Cargo registry cache $(print_risk LOW)"
            register_candidate \
                "Cargo/Rust Cache" \
                "$size_bytes" \
                "$cargo_cache" \
                "LOW" \
                "Rust crate downloads; re-downloaded on build." \
                "Slower first cargo build." \
                "rm -rf '${cargo_cache}/cache'"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Summary & Report
# ---------------------------------------------------------------------------

print_summary() {
    print_header "SUMMARY — SAFE CLEANUP CANDIDATES"

    if [[ ${#CLEANUP_CATEGORIES[@]} -eq 0 ]]; then
        echo ""
        print_ok "No significant cleanup candidates found. Your disk is in good shape!"
        return
    fi

    echo ""
    print_item "${BOLD}Potential space to reclaim: $(human_size "$TOTAL_RECLAIMABLE")${RESET}"
    print_item "${DIM}(Some items have unknown sizes and are not included in the total)${RESET}"
    echo ""

    # Sort by size descending — print as a table
    # Build a sortable list
    local -a sorted_indices=()
    for i in "${!CLEANUP_CATEGORIES[@]}"; do
        echo "${CLEANUP_SIZES[$i]} $i"
    done | sort -rn | while read -r _ idx; do
        sorted_indices+=("$idx")
    done

    printf "    ${BOLD}%-4s %-30s %-12s %-10s %s${RESET}\n" "#" "CATEGORY" "SIZE" "RISK" "PATH"
    echo "    ────────────────────────────────────────────────────────────────────────────"

    local n=0
    for i in "${!CLEANUP_CATEGORIES[@]}"; do
        n=$((n + 1))
        local risk_colored
        risk_colored=$(print_risk "${CLEANUP_RISKS[$i]}")
        printf "    %-4s %-30s %-12s %-10b %s\n" \
            "$n" \
            "${CLEANUP_CATEGORIES[$i]}" \
            "$(human_size "${CLEANUP_SIZES[$i]}")" \
            "$risk_colored" \
            "${DIM}${CLEANUP_PATHS[$i]}${RESET}"
    done

    echo ""
    echo -e "    ${BOLD}Detailed Commands${RESET}"
    echo "    ────────────────────────────────────────────────────────────────────────────"
    for i in "${!CLEANUP_CATEGORIES[@]}"; do
        echo ""
        echo -e "    ${BOLD}${CLEANUP_CATEGORIES[$i]}${RESET} — $(human_size "${CLEANUP_SIZES[$i]}") $(print_risk "${CLEANUP_RISKS[$i]}")"
        echo -e "    ${GREEN}Why safe:${RESET} ${CLEANUP_REASONS[$i]}"
        if [[ -n "${CLEANUP_WARNINGS[$i]}" ]]; then
            echo -e "    ${YELLOW}Warning:${RESET}  ${CLEANUP_WARNINGS[$i]}"
        fi
        echo -e "    ${CYAN}Command:${RESET}  ${CLEANUP_COMMANDS[$i]}"
    done
}

print_next_steps() {
    print_header "NEXT STEPS"
    echo ""
    print_item "1. Review the candidates above. Focus on LOW-risk items first."
    print_item "2. To preview cleanup:  ${BOLD}$SCRIPT_NAME --cleanup --dry-run${RESET}"
    print_item "3. To clean interactively: ${BOLD}$SCRIPT_NAME --cleanup${RESET}"
    print_item ""
    print_item "${BOLD}Quick wins for most dev Macs:${RESET}"
    print_item "  • Empty Trash (always safe)"
    print_item "  • Xcode DerivedData (rebuilds on next build)"
    print_item "  • ~/Library/Caches (apps rebuild these)"
    print_item "  • Homebrew cache (brew cleanup --prune=all)"
    print_item "  • Old .dmg/.pkg installers in ~/Downloads"
    print_item "  • npm/yarn/pnpm caches"
    print_item ""
    print_item "${DIM}For an interactive file-size explorer, consider:${RESET}"
    if command -v ncdu &>/dev/null; then
        print_item "  ${GREEN}ncdu is installed!${RESET} Run: ncdu ~"
    else
        print_item "  brew install ncdu && ncdu ~"
    fi
    print_item ""
    print_item "${DIM}Log file: ${LOG_FILE}${RESET}"
}

# ---------------------------------------------------------------------------
# Cleanup Mode — Interactive Execution
# ---------------------------------------------------------------------------

run_cleanup() {
    print_header "INTERACTIVE CLEANUP MODE"

    if $DRY_RUN; then
        echo ""
        print_warning "DRY RUN — no files will be modified."
        echo ""
    fi

    if [[ ${#CLEANUP_CATEGORIES[@]} -eq 0 ]]; then
        print_ok "No cleanup candidates found. Nothing to do."
        return
    fi

    echo ""
    print_item "Found ${BOLD}${#CLEANUP_CATEGORIES[@]}${RESET} cleanup categories."
    print_item "You will be prompted for each one. Press Ctrl+C to abort at any time."
    echo ""

    for i in "${!CLEANUP_CATEGORIES[@]}"; do
        local cat="${CLEANUP_CATEGORIES[$i]}"
        local size_h
        size_h=$(human_size "${CLEANUP_SIZES[$i]}")
        local path="${CLEANUP_PATHS[$i]}"
        local risk="${CLEANUP_RISKS[$i]}"
        local reason="${CLEANUP_REASONS[$i]}"
        local warning="${CLEANUP_WARNINGS[$i]}"
        local cmd="${CLEANUP_COMMANDS[$i]}"

        echo -e "  ${BOLD}━━━ ${cat} ━━━${RESET}"
        echo -e "  Size:    $size_h"
        echo -e "  Risk:    $(print_risk "$risk")"
        echo -e "  Path:    $path"
        echo -e "  Why:     $reason"
        if [[ -n "$warning" ]]; then
            echo -e "  ${YELLOW}Warning:  $warning${RESET}"
        fi
        echo -e "  Command: ${DIM}$cmd${RESET}"
        echo ""

        if [[ "$risk" == "HIGH" ]]; then
            print_warning "This is a HIGH-RISK operation."
            if ! confirm "Are you SURE you want to proceed with '${cat}'?"; then
                print_item "Skipped: $cat"
                log "SKIPPED (user declined): $cat"
                echo ""
                continue
            fi
        fi

        if confirm "Clean up '${cat}' ($size_h)?"; then
            log "USER APPROVED: $cat"

            case "$cat" in
                "Trash")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would empty Trash${RESET}"
                    else
                        rm -rf "${HOME_DIR}/.Trash/"* 2>/dev/null && print_ok "Trash emptied." || print_error "Failed to empty Trash."
                    fi
                    ;;
                "User Caches")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would clear ~/Library/Caches/*${RESET}"
                    else
                        rm -rf "${HOME_DIR}/Library/Caches/"* 2>/dev/null && print_ok "User caches cleared." || print_error "Some caches could not be cleared (in use)."
                    fi
                    ;;
                "User Logs")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would clear ~/Library/Logs/*${RESET}"
                    else
                        rm -rf "${HOME_DIR}/Library/Logs/"* 2>/dev/null && print_ok "User logs cleared." || print_error "Some logs could not be cleared."
                    fi
                    ;;
                "System Logs")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would clear /private/var/log/asl/*.asl (sudo)${RESET}"
                    else
                        print_item "This requires sudo."
                        sudo rm -rf /private/var/log/asl/*.asl 2>/dev/null && print_ok "ASL logs cleared." || print_error "Failed. Try running with sudo."
                    fi
                    ;;
                "Xcode DerivedData")
                    safe_delete "$path" "true"
                    ;;
                "Xcode Archives")
                    safe_delete "$path" "true"
                    ;;
                "Xcode iOS DeviceSupport")
                    safe_delete "$path" "true"
                    ;;
                "Xcode Simulators (unavailable)")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: xcrun simctl delete unavailable${RESET}"
                    else
                        xcrun simctl delete unavailable 2>/dev/null && print_ok "Unavailable simulators removed." || print_error "Failed to remove simulators."
                    fi
                    ;;
                "Xcode Caches")
                    safe_delete "$path" "true"
                    ;;
                "Homebrew Cache")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: brew cleanup --prune=all${RESET}"
                    else
                        brew cleanup --prune=all 2>/dev/null && print_ok "Homebrew cache cleaned." || print_error "brew cleanup failed."
                    fi
                    ;;
                "Docker (prune)")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: docker system prune -a${RESET}"
                    else
                        print_warning "This will remove ALL unused Docker images, containers, and networks."
                        if confirm "Final confirmation — proceed with Docker prune?"; then
                            docker system prune -a -f 2>/dev/null && print_ok "Docker pruned." || print_error "Docker prune failed."
                        else
                            print_item "Skipped Docker prune."
                        fi
                    fi
                    ;;
                "npm Cache")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: npm cache clean --force${RESET}"
                    else
                        npm cache clean --force 2>/dev/null && print_ok "npm cache cleared." || print_error "npm cache clean failed."
                    fi
                    ;;
                "Yarn Cache")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: yarn cache clean${RESET}"
                    else
                        yarn cache clean 2>/dev/null && print_ok "Yarn cache cleared." || print_error "yarn cache clean failed."
                    fi
                    ;;
                "pnpm Store")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: pnpm store prune${RESET}"
                    else
                        pnpm store prune 2>/dev/null && print_ok "pnpm store pruned." || print_error "pnpm store prune failed."
                    fi
                    ;;
                "pip Cache")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: pip cache purge${RESET}"
                    else
                        pip cache purge 2>/dev/null && print_ok "pip cache purged." || print_error "pip cache purge failed."
                    fi
                    ;;
                "Conda Package Cache")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: conda clean --all -y${RESET}"
                    else
                        conda clean --all -y 2>/dev/null && print_ok "Conda cache cleaned." || print_error "conda clean failed."
                    fi
                    ;;
                Chrome*|Brave*|Firefox*|Safari*)
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: $cmd${RESET}"
                    else
                        eval "$cmd" 2>/dev/null && print_ok "${cat} cleared." || print_error "Some files could not be cleared (browser may be running)."
                    fi
                    ;;
                "DMG Installers"|"PKG Installers")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: $cmd${RESET}"
                    else
                        # Move to Trash instead of deleting
                        local ext="dmg"
                        [[ "$cat" == "PKG Installers" ]] && ext="pkg"
                        local moved=0
                        while IFS= read -r f; do
                            if [[ -f "$f" ]]; then
                                safe_delete "$f"
                                moved=$((moved + 1))
                            fi
                        done < <(find "${HOME_DIR}/Downloads" -maxdepth 2 -iname "*.${ext}" -type f 2>/dev/null)
                        print_ok "Processed $moved .${ext} file(s)."
                    fi
                    ;;
                "Large ZIPs in Downloads")
                    print_item "${DIM}Large ZIPs need manual review. Listing:${RESET}"
                    find "${HOME_DIR}/Downloads" -maxdepth 2 -iname "*.zip" -size +100M -type f 2>/dev/null \
                        | while read -r f; do
                            local sz
                            sz=$(stat -f%z "$f" 2>/dev/null || echo "0")
                            printf "    %-12s %s\n" "$(human_size "$sz")" "$(basename "$f")"
                        done
                    print_item "${DIM}Delete individually: rm '<path>'${RESET}"
                    ;;
                "Mail Downloads")
                    safe_delete "$path" "true"
                    ;;
                "iOS Backups")
                    print_warning "iOS backup deletion must be done carefully."
                    print_item "Open Finder > Your iPhone > Manage Backups to review."
                    print_item "Or delete individual backups from:"
                    print_item "  ${HOME_DIR}/Library/Application Support/MobileSync/Backup/"
                    ;;
                "Time Machine Snapshots")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would thin Time Machine snapshots (sudo required)${RESET}"
                    else
                        print_item "This requires sudo."
                        if confirm "Thin all local Time Machine snapshots?"; then
                            sudo tmutil thinlocalsnapshots / 9999999999 4 2>/dev/null && print_ok "Snapshots thinned." || print_error "Failed to thin snapshots."
                        fi
                    fi
                    ;;
                "Spotify Cache"|"Slack Cache"|"Discord Cache")
                    safe_delete "$path" "true"
                    ;;
                "Composer Cache")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: composer clear-cache${RESET}"
                    else
                        composer clear-cache 2>/dev/null && print_ok "Composer cache cleared." || safe_delete "$path" "true"
                    fi
                    ;;
                "Gradle Cache")
                    safe_delete "$path" "true"
                    ;;
                "CocoaPods Cache")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: pod cache clean --all${RESET}"
                    else
                        pod cache clean --all 2>/dev/null && print_ok "CocoaPods cache cleared." || safe_delete "$path" "true"
                    fi
                    ;;
                "Ruby Gem Cache")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: gem cleanup${RESET}"
                    else
                        gem cleanup 2>/dev/null && print_ok "Gems cleaned." || print_error "gem cleanup failed."
                    fi
                    ;;
                "Go Cache")
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: go clean -cache -modcache${RESET}"
                    else
                        go clean -cache -modcache 2>/dev/null && print_ok "Go cache cleared." || print_error "go clean failed."
                    fi
                    ;;
                "Cargo/Rust Cache")
                    safe_delete "$path/cache" "true"
                    ;;
                *)
                    # Generic handler
                    if $DRY_RUN; then
                        print_item "${DIM}[DRY RUN] Would run: $cmd${RESET}"
                    else
                        print_item "Running: $cmd"
                        eval "$cmd" 2>/dev/null && print_ok "Done." || print_error "Command failed."
                    fi
                    ;;
            esac
            log "COMPLETED: $cat"
        else
            print_item "Skipped: $cat"
            log "SKIPPED (user declined): $cat"
        fi
        echo ""
    done

    # Show space after cleanup
    echo ""
    print_header "POST-CLEANUP DISK STATUS"
    df -H / 2>/dev/null | while IFS= read -r line; do
        print_item "$line"
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    # Initialize log
    echo "# Disk Audit Log — $(date)" > "$LOG_FILE"
    echo "# Mode: ${MODE} | Scan: ${SCAN_DEPTH} | Dry Run: ${DRY_RUN}" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"

    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${MAGENTA}║          macOS Disk Space Audit + Safe Cleanup  v${SCRIPT_VERSION}               ║${RESET}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  Mode: ${BOLD}${MODE}${RESET} | Scan: ${BOLD}${SCAN_DEPTH}${RESET} | Dry Run: ${BOLD}${DRY_RUN}${RESET}"
    echo -e "  Log:  ${DIM}${LOG_FILE}${RESET}"

    if [[ "$MODE" == "audit" ]]; then
        echo -e "  ${GREEN}READ-ONLY mode — no files will be modified.${RESET}"
    elif $DRY_RUN; then
        echo -e "  ${YELLOW}DRY-RUN mode — showing what would be cleaned, no changes.${RESET}"
    else
        echo -e "  ${RED}CLEANUP mode — you will be prompted before each action.${RESET}"
    fi

    # ── Audit Phase ──
    audit_filesystem_overview
    audit_top_level_dirs
    audit_home_breakdown

    if [[ "$SCAN_DEPTH" == "deep" ]]; then
        print_warning "Deep scan enabled. Large file/directory scan may take 1-2 minutes..."
    fi

    audit_largest_files
    audit_largest_dirs
    audit_system_data

    # ── Candidate Detection ──
    print_header "CHECKING CLEANUP CANDIDATES"

    check_trash
    check_user_caches
    check_user_logs
    check_system_logs
    check_xcode
    check_homebrew
    check_docker
    check_node
    check_python
    check_browsers
    check_mail
    check_ios_backups
    check_downloads
    check_time_machine
    check_misc

    # ── Summary ──
    print_summary

    # ── Cleanup or Next Steps ──
    if [[ "$MODE" == "cleanup" ]]; then
        run_cleanup
    else
        print_next_steps
    fi

    echo ""
    echo -e "${DIM}Audit complete. Full log: ${LOG_FILE}${RESET}"
    echo ""
}

main "$@"
