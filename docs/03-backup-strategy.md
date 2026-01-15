# 03: Backup Strategy

Comprehensive backup procedures to ensure zero data loss during GitLab upgrades.

---

## Backup Philosophy

**Rule #1:** Never start an upgrade without tested, verified backups.  
**Rule #2:** Backups are useless if you can't restore from them.  
**Rule #3:** Multiple backup layers provide maximum safety.

---

## Backup Layers

### Layer 1: GitLab Application Backup

**What it includes:**
- Database (repositories, issues, merge requests, users)
- Git repositories
- Attachments and uploads
- CI/CD variables and secrets
- Wiki data
- LFS objects (if enabled)

**What it excludes:**
- Configuration files (`/etc/gitlab/`)
- SSL certificates
- SSH host keys

**Create backup:**
```bash
gitlab-rake gitlab:backup:create SKIP=registry
```

**Location:** `/var/opt/gitlab/backups/`

**Retention:** Configure in `/etc/gitlab/gitlab.rb`:
```ruby
gitlab_rails['backup_keep_time'] = 604800  # 7 days in seconds
```

### Layer 2: Configuration Backup

**Critical files to backup:**
```bash
# Manual backup
tar -czf /backup/gitlab-config-$(date +%Y%m%d).tar.gz \
  /etc/gitlab/gitlab.rb \
  /etc/gitlab/gitlab-secrets.json \
  /etc/ssh/ssh_host_*
```

**Why important:**
- `gitlab.rb` - All configuration settings
- `gitlab-secrets.json` - Encryption keys (CRITICAL!)
- SSH host keys - Required for Jenkins/CI integration

### Layer 3: AMI Snapshots (AWS)

**When to create:**
- Before each OS upgrade
- Before first GitLab upgrade in a session
- After successful major version upgrade

**Create AMI:**
```bash
aws ec2 create-image \
  --instance-id i-xxxxx \
  --name "gitlab-snapshot-$(date +%Y%m%d-%H%M)" \
  --description "Pre-upgrade snapshot before v${VERSION}" \
  --no-reboot \
  --region us-east-1
```

**Verify creation:**
```bash
aws ec2 describe-images \
  --owners self \
  --filters "Name=name,Values=gitlab-snapshot-*" \
  --query 'Images[*].[ImageId,Name,CreationDate]' \
  --output table
```

---

## Automated Backup Script

Use the provided `scripts/backup.sh`:

```bash
#!/bin/bash
set -e

BACKUP_DIR="/backup/gitlab-upgrade-$(date +%Y%m%d)"
GITLAB_BACKUP_DIR="/var/opt/gitlab/backups"

echo "[1/5] Creating backup directory..."
mkdir -p $BACKUP_DIR

echo "[2/5] Running GitLab backup..."
gitlab-rake gitlab:backup:create SKIP=registry

echo "[3/5] Backing up configuration..."
tar -czf $BACKUP_DIR/gitlab-config.tar.gz \
  /etc/gitlab/gitlab.rb \
  /etc/gitlab/gitlab-secrets.json

echo "[4/5] Backing up SSH host keys..."
tar -czf $BACKUP_DIR/ssh-host-keys.tar.gz /etc/ssh/ssh_host_*

echo "[5/5] Copying latest GitLab backup..."
LATEST_BACKUP=$(ls -t $GITLAB_BACKUP_DIR/*.tar | head -1)
cp $LATEST_BACKUP $BACKUP_DIR/

# Create manifest
cat > $BACKUP_DIR/MANIFEST.txt <<EOF
Backup Created: $(date)
GitLab Version: $(cat /opt/gitlab/version-manifest.txt | grep gitlab-ce)
OS Version: $(cat /etc/os-release | grep PRETTY_NAME)
Backup Files:
  - $(basename $LATEST_BACKUP)
  - gitlab-config.tar.gz
  - ssh-host-keys.tar.gz
EOF

echo "✓ Backup complete: $BACKUP_DIR"
ls -lh $BACKUP_DIR
```

**Usage:**
```bash
chmod +x scripts/backup.sh
sudo ./scripts/backup.sh
```

---

## Backup Verification

### Test Restoration (Critical!)

**Before starting upgrade**, verify you can restore:

```bash
# 1. Stop GitLab
gitlab-ctl stop puma
gitlab-ctl stop sidekiq

# 2. Restore backup (dry-run first)
gitlab-rake gitlab:backup:restore BACKUP=1234567890_2026_01_15

# 3. Reconfigure
gitlab-ctl reconfigure

# 4. Verify
gitlab-rake gitlab:check SANITIZE=true

# 5. Test login and git operations
```

**If restoration works, your backups are valid.**

---

## Backup Schedule

### Pre-Upgrade Backups

| When                     | Type          | Command                                      |
| ------------------------ | ------------- | -------------------------------------------- |
| Before starting          | Full backup   | `gitlab-rake gitlab:backup:create`           |
| Before starting          | AMI snapshot  | `aws ec2 create-image`                       |
| Before OS upgrade        | AMI snapshot  | `aws ec2 create-image`                       |
| After each major version | Config backup | `tar -czf gitlab-config.tar.gz /etc/gitlab/` |

### During Upgrade

GitLab **automatically creates backups** before each version install.

**Problem:** This fills disk space quickly!

**Monitor:**
```bash
df -h
du -sh /var/opt/gitlab/backups/
```

**Cleanup if needed:**
```bash
cd /var/opt/gitlab/backups/
ls -ltrh  # List by time

# Delete oldest backups (keep last 3-4)
rm -f 1234567890_*.tar

./scripts/cleanup-old-backups.sh --keep 5
```

---

## SSH Host Keys Backup

**Critical for AMI clone strategy!**

If you upgrade via AMI clone and swap instances, SSH host keys may differ. Jenkins and other SSH clients will fail.

**Backup before AMI creation:**
```bash
tar -czf /backup/ssh-host-keys-$(date +%Y%m%d).tar.gz \
  /etc/ssh/ssh_host_*

# Verify
tar -tzf /backup/ssh-host-keys-*.tar.gz
```

**Restore on new instance:**
```bash
# Before starting new instance
tar -xzf /backup/ssh-host-keys-YYYYMMDD.tar.gz -C /
systemctl restart ssh

# Verify fingerprint matches
ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub
```

---

## Backup Storage

### Local Storage

**Pros:**
- Fast backup/restore
- No network dependency

**Cons:**
- Lost if instance fails
- Consumes instance disk space

**Recommendation:** Use for immediate backups, copy to remote storage

### External Storage (S3)

**Upload to S3:**
```bash
BACKUP_DIR="/backup/gitlab-upgrade-$(date +%Y%m%d)"

aws s3 sync $BACKUP_DIR \
  s3://my-gitlab-backups/$(date +%Y%m%d)/ \
  --region us-east-1
```

**Download from S3:**
```bash
aws s3 sync \
  s3://my-gitlab-backups/20260115/ \
  /restore/gitlab-20260115/
```

---

## Backup Retention Policy

**Recommended retention:**
- **Immediate backups:** Keep last 3-4 on instance
- **Daily backups:** Keep 7 days in S3
- **Weekly backups:** Keep 4 weeks in S3
- **Pre-upgrade backups:** Keep until upgrade verified (24-48 hours)
- **AMI snapshots:** Keep 2-3 most recent

**Cleanup script:**
```bash
# Delete backups older than 7 days
find /var/opt/gitlab/backups/ -name "*.tar" -mtime +7 -delete

# Or use the provided script
./scripts/cleanup-old-backups.sh --keep 7 --dry-run
./scripts/cleanup-old-backups.sh --keep 7
```

---

## Recovery Scenarios

### Scenario 1: Single Version Rollback

**Problem:** GitLab upgrade failed, need to revert to previous version

**Solution:**
```bash
# Stop services
gitlab-ctl stop

# Reinstall previous version
apt-get install gitlab-ce=<PREVIOUS_VERSION>-ce.0

# Reconfigure
gitlab-ctl reconfigure
gitlab-ctl restart

# Verify
gitlab-rake gitlab:check
```

### Scenario 2: OS Upgrade Failure

**Problem:** Ubuntu upgrade broke system

**Solution:**
```bash
# From AWS Console
# 1. Stop broken instance
# 2. Launch new instance from pre-upgrade AMI
# 3. Update Load Balancer target to new instance
# 4. Verify GitLab works
```

**Downtime:** ~5-10 minutes

### Scenario 3: Data Corruption

**Problem:** Database corruption or data loss detected

**Solution:**
```bash
# 1. Stop GitLab
gitlab-ctl stop

# 2. Restore backup
gitlab-rake gitlab:backup:restore BACKUP=<timestamp>

# 3. Restore configuration
tar -xzf gitlab-config.tar.gz -C /

# 4. Reconfigure and restart
gitlab-ctl reconfigure
gitlab-ctl restart

# 5. Verify data integrity
gitlab-rake gitlab:check
```

---

## Backup Checklist

Before each upgrade step:

- [ ] Recent GitLab backup created (< 1 hour old)
- [ ] Configuration backed up
- [ ] SSH host keys backed up
- [ ] AMI snapshot created (for OS upgrades)
- [ ] Backups copied to external storage (S3)
- [ ] Backup restoration tested (at least once before starting)
- [ ] Disk space > 30% free
- [ ] Backup manifest created with version info

---

##Emergency Contacts

**If backup/restore fails:**
- [AWS Support](https://aws.amazon.com/premiumsupport/)
- [GitLab Support](https://about.gitlab.com/support/)
- Your team's designated backup contact

---

**Next:** [04-troubleshooting.md](04-troubleshooting.md) - Common issues during upgrades
