#!/usr/bin/env bash
#set -euxo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
# BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to get absolute path (cross-platform compatible)
get_absolute_path() {
    # Try realpath first (Linux/Unix with GNU coreutils)
    if command -v realpath >/dev/null 2>&1; then
        realpath "$1" 2>/dev/null && return 0
    fi
    
    # Try readlink -f (Linux)
    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$1" 2>/dev/null && return 0
    fi
    
    # Fallback for macOS and other systems
    local dir
    dir=$(cd "$(dirname "$1")" >/dev/null 2>&1 && pwd -P)
    echo "${dir%/}/${1##*/}"
}

# Function to check if directory is protected
is_protected_directory() {
    local dir="$1"
    # Get absolute path using our cross-platform function
    local abs_path
    abs_path=$(get_absolute_path "$dir" 2>/dev/null || echo "$dir")

    # Directories that are protected ONLY on an exact path match (i.e., subdirectories are allowed).
    local exact_protected=(
        "/"
        "/home"
        "$HOME"
    )

    # Directories that are protected by prefix (the directories themselves and everything inside).
    local prefix_protected=(
        "/bin"
        "/sbin"
        "/lib"
        "/lib64"
        "/usr"
        "/etc"
        "/var"
        "/boot"
        "/dev"
        "/proc"
        "/sys"
        "/run"
        "/srv"
        "/mnt"
        "/media"
        "/opt"
        "/root"
        "/tmp"
        "/usr/local"
        "/usr/bin"
        "/usr/sbin"
        "/usr/lib"
        "/usr/share"
        "/usr/src"

        # MacOS
        "/Applications"
        "/System"
        "/Library"
    )

    # Exact-match prohibition.
    for p in "${exact_protected[@]}"; do
        if [[ "$abs_path" == "$p" ]]; then
            return 0
        fi
    done

    # Prohibition if the path is one of the listed directories or nested within it.
    for p in "${prefix_protected[@]}"; do
        if [[ "$abs_path" == "$p" || "$abs_path" == "$p"/* ]]; then
            return 0
        fi
    done

    return 1
}

# Function to check if directory is a C# repository
is_csharp_repository() {
    local dir="$1"

    # Check for .sln files
    if find "$dir" -maxdepth 2 -name "*.sln" -type f | grep -q .; then
        return 0
    fi

    # Check for .csproj files
    if find "$dir" -maxdepth 2 -name "*.csproj" -type f | grep -q .; then
        return 0
    fi

    return 1
}

# Get the target directory (default to current directory)
TARGET_DIR="${1:-.}"

# Check if target directory exists
if [ ! -d "$TARGET_DIR" ]; then
    echo -e "${RED}Error: Directory '$TARGET_DIR' does not exist${NC}"
    exit 1
fi

# Get absolute path
TARGET_DIR=$(get_absolute_path "$TARGET_DIR")

# Check if directory is protected
if is_protected_directory "$TARGET_DIR"; then
    echo -e "${RED}Error: Cannot clean protected directory '$TARGET_DIR'${NC}"
    echo -e "${YELLOW}This directory is protected to prevent accidental deletion of system files.${NC}"
    exit 1
fi

# Check if directory is a C# repository (informational only — scanning proceeds regardless)
if ! is_csharp_repository "$TARGET_DIR"; then
    echo -e "${YELLOW}Warning: No .sln or .csproj files found in '$TARGET_DIR' or its subdirectories.${NC}"
    echo -e "${YELLOW}Proceeding anyway to scan for bin, obj, and node_modules directories.${NC}"
fi

echo -e "${GREEN} Target directory is safe to clean${NC}"
echo -e "${GREEN} C# repository detected${NC}"

# Variables for statistics
TOTAL_SIZE=0
START_TIME=$(date +%s)
# don't delete mktemp! Problem inside while after pipe. Changing variable TEMP_SIZE_FILE doesn't change in main process!
TEMP_SIZE_FILE=$(mktemp)

echo -e "Starting search and removal of ${CYAN}bin${NC}, ${CYAN}obj${NC} and ${CYAN}node_modules${NC} directories in: ${CYAN}$TARGET_DIR${NC}"

# Function to format size
format_size() {
    local size=${1:-0}
    # Guard against empty or non-numeric input
    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        size=0
    fi
    if [ "$size" -ge 1073741824 ]; then
        awk -v s="$size" 'BEGIN{printf "%.2f GB\n", s/1073741824}'
    elif [ "$size" -ge 1048576 ]; then
        awk -v s="$size" 'BEGIN{printf "%.2f MB\n", s/1048576}'
    elif [ "$size" -ge 1024 ]; then
        awk -v s="$size" 'BEGIN{printf "%.2f KB\n", s/1024}'
    else
        echo "$size B"
    fi
}

# Search and remove directories
# Prune .git to avoid descending into git internals.
# bin, obj and node_modules are matched by name and listed for removal (deletion itself is commented out below).
find "$TARGET_DIR" -path "*/.git/*" -prune -o \
       -type d \( -name "bin" -o -name "obj" -o -name "node_modules" \) -print0 |
while IFS= read -r -d '' dir; do
    if [ -d "$dir" ]; then
        # Clean up path from extra spaces
        dir=$(echo "$dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty paths
        [ -z "$dir" ] && continue

        # Get directory size in kilobytes
        size_kb=$(du -sk -- "$dir" 2>/dev/null | awk '{print $1}')

        # Verify we got a number
        if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
            # Update total (in bytes) and save to temp file
            echo "$(( size_kb * 1024 ))" >> "$TEMP_SIZE_FILE"
            # Format size for display
            size_display="${size_kb}K"
        else
            size_display="0B"
        fi

        # Display removal info
        dir_name=$(basename -- "$dir")
        dir_path=$(dirname -- "$dir")
        [[ "$dir_path" == "." ]] && full_path="" || full_path="${dir_path#./}"
        echo -e "${RED}Removing:${NC} ${full_path:+$full_path/}${CYAN}${dir_name}${NC} ${YELLOW}(${size_display})${NC}"

        # Remove directory
        rm -rf -- "$dir" 2>/dev/null
        #echo "remove $dir"
    fi
done

# Calculate total size from temp file
TOTAL_SIZE=0
if [ -f "$TEMP_SIZE_FILE" ]; then
    TOTAL_SIZE=$(awk '{sum += $1} END {print sum+0}' "$TEMP_SIZE_FILE")
    rm -f "$TEMP_SIZE_FILE"
fi

# Calculate execution time
END_TIME=$(date +%s)
ELAPSED_TIME=$((END_TIME - START_TIME))

# Display report
echo -e "\n${CYAN}=== REPORT ===${NC}"
echo -e "Total space freed: ${YELLOW}$(format_size "$TOTAL_SIZE")${NC}"
echo -e "Total execution time: ${YELLOW}${ELAPSED_TIME} seconds${NC}"
echo -e "Cleanup completed!${NC}"
