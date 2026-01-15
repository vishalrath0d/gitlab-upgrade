# 02: Detailed Upgrade Path

Step-by-step procedures for upgrading GitLab CE from v12.1.6 to v18.5.2 with all required intermediate versions.

---

## Overview

This guide provides the complete, tested upgrade path with commands and verification steps for each version.

**Total:** 22 GitLab version upgrades + 2 OS upgrades = 24 steps

---

## Standard Workflow

Each GitLab version upgrade follows this pattern:

```bash
# 1. Stop services (reduces resource usage)
gitlab-ctl stop puma
gitlab-ctl stop sidekiq

# 2. Install target version
apt-get install gitlab-ce=<VERSION>-ce.0

# 3. Reconfigure and restart
gitlab-ctl reconfigure
gitlab-ctl restart
sleep 180  # Wait for stabilization

# 4. Verify services
gitlab-ctl status

# 5. CRITICAL: Wait for migrations
gitlab-rails runner "puts Gitlab::BackgroundMigration.remaining"
# Must be 0 before proceeding

# For v14+ also check:
gitlab-rails runner "puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count"
# Must be 0 before proceeding

# 6. Health check
gitlab-rake gitlab:check SANITIZE=true
```

---

## Complete Upgrade Matrix

| Step | From → To          | Package Version      | Notes                             |
| ---- | ------------------ | -------------------- | --------------------------------- |
| 1    | 12.1.6 → 12.10.14  | 12.10.14-ce.0        | Starting point                    |
| 2    | 12.10.14 → 13.0.14 | 13.0.14-ce.0         | ⚠️ Puma port conflict              |
| 3    | 13.0.14 → 13.1.11  | 13.1.11-ce.0         | Checkpoint: migrations = 0        |
| 4    | 13.1.11 → 13.8.8   | 13.8.8-ce.0          |                                   |
| 5    | 13.8.8 → 13.12.15  | 13.12.15-ce.0        |                                   |
| 6A   | **OS Upgrade**     | Ubuntu 16.04 → 18.04 | ⚠️ Required OS change              |
| 6    | 13.12.15 → 14.0.12 | 14.0.12-ce.0         | ⚠️ Introduces batched migrations   |
| 7    | 14.0.12 → 14.3.6   | 14.3.6-ce.0          |                                   |
| 8    | 14.3.6 → 14.9.5    | 14.9.5-ce.0          |                                   |
| 9    | 14.9.5 → 14.10.5   | 14.10.5-ce.0         |                                   |
| 10   | 14.10.5 → 15.0.5   | 15.0.5-ce.0          | Major version, PostgreSQL upgrade |
| 11   | 15.0.5 → 15.4.6    | 15.4.6-ce.0          |                                   |
| 12   | 15.4.6 → 15.11.13  | 15.11.13-ce.0        |                                   |
| 13   | 15.11.13 → 16.3.9  | 16.3.9-ce.0          | ⚠️ Config deprecations             |
| 14   | 16.3.9 → 16.7.10   | 16.7.10-ce.0         |                                   |
| 15   | 16.7.10 → 16.11.10 | 16.11.10-ce.0        |                                   |
| 16A  | **OS Upgrade**     | Ubuntu 18.04 → 20.04 | ⚠️ Required OS change              |
| 16   | 16.11.10 → 17.1.8  | 17.1.8-ce.0          | Major v17                         |
| 17   | 17.1.8 → 17.3.7    | 17.3.7-ce.0          |                                   |
| 18   | 17.3.7 → 17.5.5    | 17.5.5-ce.0          |                                   |
| 19   | 17.5.5 → 17.8.7    | 17.8.7-ce.0          | ⚠️ Monitor disk space              |
| 20   | 17.8.7 → 17.11.7   | 17.11.7-ce.0         |                                   |
| 21   | 17.11.7 → 18.2.8   | 18.2.8-ce.0          |                                   |
| 22   | 18.2.8 → 18.5.2    | 18.5.2-ce.0          | ✅ Target version                  |

---

## Step-by-Step Commands

### Steps 1-5: GitLab v12 → v13

```bash
# Step 1: 12.1.6 → 12.10.14
gitlab-ctl stop puma && gitlab-ctl stop sidekiq
apt-get install gitlab-ce=12.10.14-ce.0
gitlab-ctl reconfigure && gitlab-ctl restart
gitlab-rails runner "puts Gitlab::BackgroundMigration.remaining"  # Wait for 0

# Step 2: 12.10.14 → 13.0.14 (⚠️ Puma port conflict)
gitlab-ctl stop puma && gitlab-ctl stop sidekiq
apt-get install gitlab-ce=13.0.14-ce.0
gitlab-ctl reconfigure && gitlab-ctl restart

# If Puma fails to start, fix config:
vim /etc/gitlab/gitlab.rb
# Add:
# puma['port'] = 8085
# gitlab_workhorse['auth_backend'] = "http://localhost:8085"

gitlab-ctl reconfigure && gitlab-ctl restart
gitlab-rails runner "puts Gitlab::BackgroundMigration.remaining"  # Wait for 0

# Steps 3-5: Continue pattern
apt-get install gitlab-ce=13.1.11-ce.0
# ... (same workflow for 13.8.8, 13.12.15)
```

### Step 6A: OS Upgrade (Ubuntu 16.04 → 18.04)

```bash
# Create AMI snapshot first!
aws ec2 create-image \
  --instance-id i-xxxxx \
  --name "gitlab-before-os-upgrade-$(date +%Y%m%d)" \
  --no-reboot

# Upgrade OS
do-release-upgrade

# Reboot
reboot

# Verify GitLab after reboot
gitlab-ctl status
gitlab-rake gitlab:check SANITIZE=true
```

### Steps 6-15: GitLab v14 → v16

```bash
# Step 6: 13.12.15 → 14.0.12 (⚠️ Batched migrations introduced)
apt-get install gitlab-ce=14.0.12-ce.0
gitlab-ctl reconfigure && gitlab-ctl restart

# NEW: Monitor batched migrations
gitlab-rails runner "puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count"
# Can take 2-4 hours on large instances

# Monitor progress:
watch -n 300 'gitlab-rails runner "puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count"'

# Steps 7-15: Continue with same pattern
# (14.3.6, 14.9.5, 14.10.5, 15.0.5, 15.4.6, 15.11.13, 16.3.9, 16.7.10, 16.11.10)
```

### Step 16A: OS Upgrade (Ubuntu 18.04 → 20.04)

```bash
# Create AMI snapshot
aws ec2 create-image \
  --instance-id i-xxxxx \
  --name "gitlab-before-os-upgrade-20-$(date +%Y%m%d)" \
  --no-reboot

# Upgrade OS
do-release-upgrade

# Reboot and verify
reboot
gitlab-ctl status
```

### Steps 16-22: GitLab v17 → v18

```bash
# Step 16: 16.11.10 → 17.1.8
apt-get install gitlab-ce=17.1.8-ce.0
gitlab-ctl reconfigure && gitlab-ctl restart
# Check batched migrations

# Steps 17-22: Continue pattern
# WARNING: Monitor disk space starting at Step 19 (17.8.7)
df -h  # Should be > 30% free

# Step 22: Final upgrade to target
apt-get install gitlab-ce=18.5.2-ce.0
gitlab-ctl reconfigure && gitlab-ctl restart
```

---

## Version-Specific Issues and Fixes

### v13.0.14: Puma Port Conflict

**Error:**
```
Puma failed to bind to 127.0.0.1:8080
```

**Fix:** Edit `/etc/gitlab/gitlab.rb`:
```ruby
puma['port'] = 8085
gitlab_workhorse['auth_backend'] = "http://localhost:8085"
```

### v14.0.12: crond --no-auto Flag

**Error:**
```
level=error msg="unknown flag `no-auto'"
```

**Fix:**
```bash
vim /opt/gitlab/sv/crond/run
# Remove line: --no-auto \
gitlab-ctl restart crond
```

### v16.3.9: gitaly Config Deprecation

**Error:**
```
gitaly['custom_hooks_dir'] has been deprecated
```

**Fix:** Comment out in `/etc/gitlab/gitlab.rb`:
```ruby
# gitaly['custom_hooks_dir'] = "/var/opt/gitlab/gitaly/custom_hooks"
```

### v17.8.7+: Disk Space Management

**Monitor continuously:**
```bash
df -h
cd /var/opt/gitlab/backups/
ls -ltrh  # List by time

# Clean old backups if needed:
./scripts/cleanup-old-backups.sh --keep 5
```

---

## Migration Monitoring

### Script for Continuous Monitoring

Save as `monitor-migrations.sh`:
```bash
#!/bin/bash

while true; do
  clear
  echo "=== Legacy Migrations ==="
  gitlab-rails runner "puts Gitlab::BackgroundMigration.remaining"
  
  echo ""
  echo "=== Batched Migrations (v14+) ==="
  gitlab-rails runner "puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count"
  
  echo ""
  echo "=== Active Migrations ==="
  gitlab-rails runner "
    Gitlab::Database::BackgroundMigration::BatchedMigration.active.each do |m|
      puts \"#{m.job_class_name} - #{m.table_name} (#{m.progress}%)\"
    end
  "
  
  echo""
  echo "Time: $(date)"
  echo "Checking again in 5 minutes..."
  sleep 300
done
```

Usage:
```bash
chmod +x monitor-migrations.sh
./monitor-migrations.sh
```

---

## Post-Upgrade Verification

After reaching v18.5.2:

```bash
# 1. Verify version
cat /opt/gitlab/version-manifest.txt | grep gitlab-ce
# Should show: gitlab-ce 18.5.2

# 2. Full health check
gitlab-rake gitlab:check SANITIZE=true

# 3. Test Git operations
git clone http://<gitlab-url>/test-repo.git
cd test-repo
touch test.txt
git add . && git commit -m "Post-upgrade test" && git push

# 4. Verify integrations
# - Test Jenkins can connect via SSH
# - Verify webhooks work
# - Check CI/CD pipelines run
```

---

**Next:** [04-troubleshooting.md](04-troubleshooting.md) - Common issues and solutions
