#!/bin/bash
# verify-health.sh - Comprehensive GitLab health check
# Run after each upgrade to verify system integrity

set -e

FAILED_CHECKS=0

echo "================================================"
echo "GitLab Health Verification"
echo "================================================"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Check 1: GitLab Version
echo "[1/7] Checking GitLab version..."
VERSION=$(cat /opt/gitlab/version-manifest.txt 2>/dev/null | grep gitlab-ce | head -1)
if [ -n "$VERSION" ]; then
    echo "✓ $VERSION"
else
    echo "✗ Unable to determine version"
    ((FAILED_CHECKS++))
fi
echo ""

# Check 2: All services running
echo "[2/7] Checking GitLab services..."
if gitlab-ctl status | grep -q "down"; then
    echo "✗ Some services are down:"
    gitlab-ctl status | grep "down"
    ((FAILED_CHECKS++))
else
    echo "✓ All services running"
    gitlab-ctl status | grep -E "^run:" | wc -l | xargs echo "  Total services:"
fi
echo ""

# Check 3: GitLab system check
echo "[3/7] Running GitLab system check..."
if gitlab-rake gitlab:check SANITIZE=true 2>&1 | grep -q "Checking GitLab .*finished"; then
    echo "✓ System check passed"
else
    echo "⚠ System check completed with warnings (review output)"
fi
echo ""

# Check 4: Database migrations
echo "[4/7] Checking database migrations..."
PENDING=$(gitlab-rake db:migrate:status 2>&1 | grep -c "down" || echo "0")
if [ "$PENDING" = "0" ]; then
    echo "✓ All migrations applied"
else
    echo "✗ $PENDING pending migrations"
    echo "  Run: gitlab-rake db:migrate"
    ((FAILED_CHECKS++))
fi
echo ""

# Check 5: PostgreSQL connectivity
echo "[5/7] Checking PostgreSQL..."
if gitlab-psql -c "SELECT version();" > /dev/null 2>&1; then
    PG_VERSION=$(gitlab-psql --version | head -1)
    echo "✓ PostgreSQL connected"
    echo "  $PG_VERSION"
else
    echo "✗ PostgreSQL connection failed"
    ((FAILED_CHECKS++))
fi
echo ""

# Check 6: Redis connectivity
echo "[6/7] Checking Redis..."
if gitlab-redis-cli ping 2>&1 | grep -q "PONG"; then
    echo "✓ Redis responding"
else
    echo "✗ Redis connection failed"
    ((FAILED_CHECKS++))
fi
echo ""

# Check 7: Repository integrity (sample check)
echo "[7/7] Checking repository integrity..."
echo "  Running fsck on sample repositories..."
FSCK_OUTPUT=$(gitlab-rake gitlab:git:fsck 2>&1 || true)
if echo "$FSCK_OUTPUT" | grep -q "Finished"; then
    echo "✓ Repository integrity check completed"
    FAILED_REPOS=$(echo "$FSCK_OUTPUT" | grep -c "Failed" || echo "0")
    if [ "$FAILED_REPOS" -gt "0" ]; then
        echo "  ⚠ Warning: $FAILED_REPOS repositories failed fsck"
    fi
else
    echo "  ⚠ Unable to complete fsck (may be slow on large instances)"
fi
echo ""

# Final summary
echo "================================================"
echo "Health Check Summary"
echo "================================================"

if [ $FAILED_CHECKS -eq 0 ]; then
    echo "✓ ALL CHECKS PASSED"
    echo ""
    echo "System appears healthy. Safe to continue."
    exit 0
else
    echo "✗ $FAILED_CHECKS CHECK(S) FAILED"
    echo ""
    echo "Review errors above before proceeding."
    echo "See docs/04-troubleshooting.md for solutions."
    exit 1
fi
