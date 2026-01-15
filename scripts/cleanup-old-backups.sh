#!/bin/bash
# cleanup-old-backups.sh - Remove old GitLab backup files
# Keeps the most recent backups based on retention policy

set -e

# Default configuration
BACKUP_DIR="/var/opt/gitlab/backups"
KEEP_COUNT=7  # Keep last N backups
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep)
            KEEP_COUNT="$2"
            shift 2
            ;;
        --dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --keep N       Keep last N backups (default: 7)"
            echo "  --dir PATH     Backup directory (default: /var/opt/gitlab/backups)"
            echo "  --dry-run      Show what would be deleted without deleting"
            echo "  --help         Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo "================================================"
echo "GitLab Backup Cleanup"
echo "================================================"
echo "Backup directory: $BACKUP_DIR"
echo "Retention policy: Keep last $KEEP_COUNT backups"
if [ "$DRY_RUN" = true ]; then
    echo "Mode: DRY RUN (no files will be deleted)"
fi
echo ""

# Check if backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    echo "✗ ERROR: Backup directory not found: $BACKUP_DIR"
    exit 1
fi

# Get list of backup files sorted by modification time (newest first)
BACKUP_FILES=($(ls -t "$BACKUP_DIR"/*.tar 2>/dev/null))
TOTAL_COUNT=${#BACKUP_FILES[@]}

if [ $TOTAL_COUNT -eq 0 ]; then
    echo "No backup files found in $BACKUP_DIR"
    exit 0
fi

echo "Found $TOTAL_COUNT backup file(s)"
echo ""

# Calculate how many files to delete
DELETE_COUNT=$((TOTAL_COUNT - KEEP_COUNT))

if [ $DELETE_COUNT -le 0 ]; then
    echo "✓ No cleanup needed"
    echo "  Current backups ($TOTAL_COUNT) ≤ retention policy ($KEEP_COUNT)"
    exit 0
fi

echo "Files to keep ($KEEP_COUNT most recent):"
for ((i=0; i<KEEP_COUNT && i<TOTAL_COUNT; i++)); do
    FILE="${BACKUP_FILES[$i]}"
    SIZE=$(du -h "$FILE" | cut -f1)
    DATE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$FILE" 2>/dev/null || stat -c "%y" "$FILE" 2>/dev/null | cut -d. -f1)
    echo "  ✓ $(basename $FILE) ($SIZE, $DATE)"
done
echo ""

echo "Files to delete ($DELETE_COUNT old backups):"
FREED_SPACE=0
for ((i=KEEP_COUNT; i<TOTAL_COUNT; i++)); do
    FILE="${BACKUP_FILES[$i]}"
    SIZE_BYTES=$(stat -f%z "$FILE" 2>/dev/null || stat -c%s "$FILE" 2>/dev/null)
    SIZE=$(du -h "$FILE" | cut -f1)
    DATE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$FILE" 2>/dev/null || stat -c "%y" "$FILE" 2>/dev/null | cut -d. -f1)
    
    echo "  ✗ $(basename $FILE) ($SIZE, $DATE)"
    FREED_SPACE=$((FREED_SPACE + SIZE_BYTES))
done
echo ""

# Convert freed space to human readable
FREED_SPACE_GB=$(echo "scale=2; $FREED_SPACE / 1024 / 1024 / 1024" | bc)

echo "Disk space to be freed: ${FREED_SPACE_GB} GB"
echo ""

# Confirm deletion
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN mode: No files deleted"
    exit 0
fi

read -p "Proceed with deletion? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted"
    exit 0
fi

# Delete old backups
echo ""
echo "Deleting old backups..."
DELETED=0
for ((i=KEEP_COUNT; i<TOTAL_COUNT; i++)); do
    FILE="${BACKUP_FILES[$i]}"
    if rm -f "$FILE"; then
        echo "  ✓ Deleted: $(basename $FILE)"
        ((DELETED++))
    else
        echo "  ✗ Failed to delete: $(basename $FILE)"
    fi
done

echo ""
echo "================================================"
echo "Cleanup Complete"
echo "================================================"
echo "Files deleted: $DELETED"
echo "Files retained: $KEEP_COUNT"
echo "Space freed: ${FREED_SPACE_GB} GB"
echo ""

# Show current disk usage
echo "Current disk usage:"
df -h "$BACKUP_DIR" | tail -1
echo ""
