#!/bin/bash
# check-migrations.sh - Monitor GitLab background migrations
# Run this after each upgrade step to verify migrations complete

set -e

echo "================================================"
echo "GitLab Migration Status Check"
echo "================================================"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Check if GitLab is running
if ! gitlab-ctl status > /dev/null 2>&1; then
    echo "✗ ERROR: GitLab services are not running"
    echo "  Run: gitlab-ctl status"
    exit 1
fi

# Get GitLab version
echo "GitLab Version:"
cat /opt/gitlab/version-manifest.txt 2>/dev/null | grep gitlab-ce | head -1 || echo "  Unknown"
echo ""

# Check legacy background migrations (all versions)
echo "========================================"
echo "[1/2] Legacy Background Migrations"
echo "========================================"

LEGACY_COUNT=$(gitlab-rails runner "puts Gitlab::BackgroundMigration.remaining" 2>/dev/null || echo "N/A")

if [ "$LEGACY_COUNT" = "0" ]; then
    echo "✓ Status: COMPLETE"
    echo "  Remaining: 0"
elif [ "$LEGACY_COUNT" = "N/A" ]; then
    echo "⚠ Status: UNABLE TO CHECK"
    echo "  (May not apply to this version)"
else
    echo "⚠ Status: IN PROGRESS"
    echo "  Remaining: $LEGACY_COUNT"
    echo ""
    echo "  Wait for this to reach 0 before proceeding."
    echo "  Monitor with: watch -n 60 \"gitlab-rails runner 'puts Gitlab::BackgroundMigration.remaining'\""
fi
echo ""

# Check batched background migrations (v14+)
echo "========================================"
echo "[2/2] Batched Background Migrations"
echo "========================================"

BATCHED_COUNT=$(gitlab-rails runner "puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count" 2>/dev/null || echo "N/A")

if [ "$BATCHED_COUNT" = "0" ]; then
    echo "✓ Status: COMPLETE"
    echo "  Queued: 0"
elif [ "$BATCHED_COUNT" = "N/A" ]; then
    echo "ℹ Status: NOT APPLICABLE"
    echo "  (Batched migrations introduced in v14+)"
else
    echo "⚠ Status: IN PROGRESS"
    echo "  Queued: $BATCHED_COUNT"
    echo ""
    echo "  Checking active migrations..."
    gitlab-rails runner "
      Gitlab::Database::BackgroundMigration::BatchedMigration.active.each do |m|
        puts \"  → #{m.job_class_name}\"
        puts \"     Table: #{m.table_name}\"
        puts \"     Progress: #{m.progress}%\"
        puts \"\"
      end
    " 2>/dev/null || echo "  Unable to fetch active migration details"
    
    echo "  Monitor with: watch -n 60 \"gitlab-rails runner 'puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count'\""
fi
echo ""

# Final verdict
echo "================================================"
echo "Summary"
echo "================================================"

if [ "$LEGACY_COUNT" = "0" ] && ([ "$BATCHED_COUNT" = "0" ] || [ "$BATCHED_COUNT" = "N/A" ]); then
    echo "✓ ALL MIGRATIONS COMPLETE"
    echo ""
    echo "Safe to proceed to next upgrade step."
    exit 0
else
    echo "⚠ MIGRATIONS STILL RUNNING"
    echo ""
    echo "DO NOT proceed to the next upgrade until both counts = 0"
    echo ""
    echo "Troubleshooting:"
    echo "  - Check Sidekiq is running: gitlab-ctl status sidekiq"
    echo "  - View Sidekiq logs: gitlab-ctl tail sidekiq"
    echo "  - Check for failed migrations: See docs/04-troubleshooting.md"
    exit 1
fi
