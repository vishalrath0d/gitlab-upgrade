#!/bin/bash
# backup.sh - GitLab Backup Automation Script
# Creates comprehensive backup of GitLab data and configuration

set -e  # Exit on error

# Configuration
BACKUP_DIR="/backup/gitlab-upgrade-$(date +%Y%m%d)"
GITLAB_BACKUP_DIR="/var/opt/gitlab/backups"
CONFIG_DIR="/etc/gitlab"

echo "================================"
echo "GitLab Backup Script"
echo "================================"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Create backup directory
echo "[1/5] Creating backup directory..."
mkdir -p "$BACKUP_DIR"
chmod 755 "$BACKUP_DIR"
echo "✓ Directory created: $BACKUP_DIR"
echo ""

# Create GitLab application backup
echo "[2/5] Creating GitLab application backup..."
echo "This may take 10-30 minutes for large instances..."
gitlab-rake gitlab:backup:create SKIP=registry

# Get the latest backup file
LATEST_BACKUP=$(ls -t $GITLAB_BACKUP_DIR/*.tar 2>/dev/null | head -1)
if [ -z "$LATEST_BACKUP" ]; then
    echo "✗ ERROR: No backup file found in $GITLAB_BACKUP_DIR"
    exit 1
fi

echo "✓ Backup created: $(basename $LATEST_BACKUP)"
echo "  Size: $(du -h $LATEST_BACKUP | cut -f1)"
echo ""

# Backup GitLab configuration
echo "[3/5] Backing up GitLab configuration..."
tar -czf "$BACKUP_DIR/gitlab-config-backup-$(date +%Y%m%d_%H%M%S).tar.gz" "$CONFIG_DIR/" 2>/dev/null
echo "✓ Configuration backed up"
echo ""

# Copy critical files
echo "[4/5] Copying critical files..."
cp "$CONFIG_DIR/gitlab.rb" "$BACKUP_DIR/gitlab.rb.backup" 2>/dev/null || echo "Warning: gitlab.rb not found"
cp "$CONFIG_DIR/gitlab-secrets.json" "$BACKUP_DIR/gitlab-secrets.json.backup" 2>/dev/null || echo "Warning: gitlab-secrets.json not found"
cp "$LATEST_BACKUP" "$BACKUP_DIR/" 2>/dev/null

echo "✓ Critical files copied"
echo ""

# Generate backup manifest
echo "[5/5] Generating backup manifest..."
cat > "$BACKUP_DIR/backup-manifest.txt" << EOF
GitLab Backup Manifest
Generated: $(date)
Hostname: $(hostname)
GitLab Version: $(cat /opt/gitlab/version-manifest.txt 2>/dev/null | grep gitlab-ce | head -1 || echo "Unknown")

Files:
$(ls -lh "$BACKUP_DIR")

Total Size: $(du -sh "$BACKUP_DIR" | cut -f1)
EOF

echo "✓ Manifest created"
echo ""

# Summary
echo "================================"
echo "Backup Complete!"
echo "================================"
echo "Location: $BACKUP_DIR"
echo "Contents:"
ls -lh "$BACKUP_DIR" | tail -n +2
echo ""
echo "Total backup size: $(du -sh $BACKUP_DIR | cut -f1)"
echo ""
echo "Next steps:"
echo "1. Verify backup integrity: tar -tzf $BACKUP_DIR/*.tar | head"
echo "2. Create AMI snapshot (if on AWS)"
echo "3. Proceed with upgrade"
echo ""
