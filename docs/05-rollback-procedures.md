# 05: Rollback Procedures

Comprehensive guide for safely rolling back GitLab upgrades when issues arise.

---

## When to Rollback

### Rollback Triggers

Consider rolling back if:

- ✅ **Critical services fail** after upgrade (Puma, Sidekiq, PostgreSQL)
- ✅ **Data corruption detected** (repositories inaccessible, database errors)
- ✅ **Background migrations stuck** for > 6 hours with no progress
- ✅ **Production outage** affecting users
- ✅ **Integration failures** (Jenkins can't connect, webhooks broken)

### When NOT to Rollback

- ⏳ **Migrations running slowly** - Be patient, especially for large instances
- ⏳ **Minor UI glitches** - Can be fixed without rollback
- ⏳ **Single failed health check** - Verify it's actually broken
- ⏳ **Disk space warnings** - Clean up backups instead

**Rule:** Only rollback for **critical failures** that prevent GitLab from functioning.

---

## Rollback Options

### Option 1: Version Downgrade (Quickest)

**Use when:**
- Single version upgrade failed
- OS not upgraded
- Data not corrupted

**Time:** 5-10 minutes  
**Risk:** Low

### Option 2: AMI Restoration (Safest)

**Use when:**
- OS upgrade failed
- Multiple version failures
- System unstable
- Boot issues

**Time:** 10-15 minutes  
**Risk:** Very Low

### Option 3: Backup Restoration (Complete Reset)

**Use when:**
- Data corruption suspected
- Database issues
- Need to restore to specific point

**Time:** 30-60 minutes  
**Risk:** Low (if backups tested)

---

## Option 1: Version Downgrade

### Steps

```bash
# 1. Stop GitLab
gitlab-ctl stop

# 2. Reinstall previous version
apt-get install gitlab-ce=<PREVIOUS_VERSION>-ce.0

# Example: Rolling back from 14.0.12 to 13.12.15
apt-get install gitlab-ce=13.12.15-ce.0

# 3. Reconfigure
gitlab-ctl reconfigure

# 4. Restart
gitlab-ctl restart

# 5. Verify services
gitlab-ctl status

# 6. Health check
gitlab-rake gitlab:check SANITIZE=true

# 7. Test operations
git clone https://<gitlab-url>/test-repo.git
```

### Verification

```bash
# Confirm version
cat /opt/gitlab/version-manifest.txt | grep gitlab-ce

# Check running services
gitlab-ctl status

# Verify database
gitlab-rake db:migrate:status

# Test web interface
curl -I http://localhost
```

### Common Issues

**Issue: Package not found**
```bash
# List available versions
apt-cache madison gitlab-ce | grep <VERSION>

# If not in cache, add specific version
wget https://packages.gitlab.com/gitlab/gitlab-ce/packages/ubuntu/xenial/gitlab-ce_<VERSION>-ce.0_amd64.deb/download.deb
dpkg -i download.deb
```

**Issue: Configuration mismatch**
```bash
# Restore config from backup
tar -xzf /backup/gitlab-config.tar.gz -C /
gitlab-ctl reconfigure
```

---

## Option 2: AMI Restoration (AWS)

### Pre-Requisites

- AMI snapshot created before upgrade
- ALB or ELB in front of GitLab instance
- DNS/routing can be updated quickly

### Steps

#### 1. Launch New Instance from AMI

```bash
# Find your pre-upgrade AMI
aws ec2 describe-images \
  --owners self \
  --filters "Name=name,Values=gitlab-snapshot-*" \
  --query 'Images[*].[ImageId,Name,CreationDate]' \
  --output table \
  --region us-east-1

# Launch new instance
aws ec2 run-instances \
  --image-id ami-xxxxx \
  --instance-type t3.medium \
  --subnet-id subnet-xxxxx \
  --security-group-ids sg-xxxxx \
  --key-name your-keypair \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=gitlab-rollback}]' \
  --region us-east-1
```

#### 2. Wait for Instance to Start

```bash
# Get instance ID from previous command
INSTANCE_ID=i-xxxxx

# Wait for running state
aws ec2 wait instance-running \
  --instance-ids $INSTANCE_ID \
  --region us-east-1

# Get private IP
aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text
```

#### 3. Verify GitLab is Working

```bash
# SSH into new instance
ssh ubuntu@<PRIVATE_IP>

# Check GitLab services
sudo gitlab-ctl status

# Verify version
cat /opt/gitlab/version-manifest.txt | grep gitlab-ce

# Test web interface
curl -I http://localhost
```

#### 4. Update Load Balancer Target

```bash
# Deregister old instance from target group
aws elbv2 deregister-targets \
  --target-group-arn arn:aws:elasticloadbalancing:... \
  --targets Id=i-OLD_INSTANCE \
  --region us-east-1

# Register new instance
aws elbv2 register-targets \
  --target-group-arn arn:aws:elasticloadbalancing:... \
  --targets Id=$INSTANCE_ID \
  --region us-east-1

# Wait for healthy status
aws elbv2 wait target-in-service \
  --target-group-arn arn:aws:elasticloadbalancing:... \
  --targets Id=$INSTANCE_ID \
  --region us-east-1
```

#### 5. Test Access via Load Balancer

```bash
# Test public access
curl -I https://gitlab.yourdomain.com

# Test git operations
git clone https://gitlab.yourdomain.com/test-repo.git
```

#### 6. Terminate Failed Instance

```bash
# After verifying rollback works
aws ec2 terminate-instances \
  --instance-ids i-OLD_INSTANCE \
  --region us-east-1
```

### Rollback Time

- Instance launch: 2-3 minutes
- Verification: 2-3 minutes
- ALB registration: 2-3 minutes
- **Total: ~10 minutes**

---

## Option 3: Backup Restoration

### Use Cases

- Data corruption
- Database migration failures
- Need exact state from backup point

### Steps

#### 1. Stop GitLab

```bash
gitlab-ctl stop
```

#### 2. Identify Backup to Restore

```bash
# List available backups
ls -lh /var/opt/gitlab/backups/

# Or from S3
aws s3 ls s3://my-gitlab-backups/

# Backup format: TIMESTAMP_YYYY_MM_DD_VERSION_gitlab_backup.tar
# Example: 1234567890_2026_01_15_13.12.15_gitlab_backup.tar
```

#### 3. Download Backup (if from S3)

```bash
aws s3 cp \
  s3://my-gitlab-backups/1234567890_2026_01_15_13.12.15_gitlab_backup.tar \
  /var/opt/gitlab/backups/
```

#### 4. Restore GitLab Data

```bash
# Extract timestamp from filename
BACKUP_TIMESTAMP=1234567890_2026_01_15_13.12.15

# Restore
gitlab-rake gitlab:backup:restore BACKUP=$BACKUP_TIMESTAMP

# Answer 'yes' to prompts
```

#### 5. Restore Configuration

```bash
# Restore gitlab.rb and secrets
tar -xzf /backup/gitlab-config.tar.gz -C /

# Restore SSH host keys (if needed)
tar -xzf /backup/ssh-host-keys.tar.gz -C /
systemctl restart ssh
```

#### 6. Reinstall Correct GitLab Version

```bash
# The backup contains data from specific version
# Install matching version
apt-get install gitlab-ce=13.12.15-ce.0
```

#### 7. Reconfigure and Restart

```bash
gitlab-ctl reconfigure
gitlab-ctl restart
```

#### 8. Verify Restoration

```bash
# Health check
gitlab-rake gitlab:check SANITIZE=true

# Check version
cat /opt/gitlab/version-manifest.txt | grep gitlab-ce

# Test git operations
git clone http://<gitlab-url>/test-repo.git
cd test-repo
git log  # Verify history
```

### Restoration Time

- Backup download: 5-10 minutes (depends on size/network)
- GitLab restore: 10-20 minutes
- Reconfigure: 2-3 minutes
- **Total: ~30-40 minutes**

---

## Decision Matrix

| Scenario                      | Recommended Option            | Time   | Risk     |
| ----------------------------- | ----------------------------- | ------ | -------- |
| Single version upgrade failed | Version Downgrade             | 10 min | Low      |
| OS upgrade boot failure       | AMI Restoration               | 10 min | Very Low |
| Multiple versions failed      | AMI Restoration               | 10 min | Low      |
| Data corruption suspected     | Backup Restoration            | 40 min | Low      |
| PostgreSQL upgrade failed     | AMI Restoration               | 10 min | Low      |
| Service won't start           | Version Downgrade (try first) | 10 min | Low      |
| System completely broken      | AMI Restoration               | 10 min | Very Low |

---

## Post-Rollback Actions

### 1. Document What Happened

```markdown
# Rollback Log

**Date:** YYYY-MM-DD HH:MM
**Attempted Upgrade:** vX.X.X → vY.Y.Y
**Reason for Rollback:** [Describe issue]
**Rollback Method:** [Version Downgrade / AMI / Backup]
**Time to Rollback:** XX minutes
**Data Loss:** Yes/No
**Lessons Learned:**
- [What went wrong]
- [What to do differently next time]
```

### 2. Investigate Root Cause

**Common causes:**
- Didn't wait for migrations to complete
- Insufficient disk space
- Config deprecation not addressed
- PostgreSQL compatibility issue
- Missed OS upgrade requirement

### 3. Plan Retry Strategy

```bash
# Before retrying:
- [ ] Review release notes for version
- [ ] Check GitLab forums for known issues
- [ ] Ensure sufficient disk space (40%+ free)
- [ ] Create fresh AMI snapshot
- [ ] Increase monitoring
- [ ] Schedule longer maintenance window
```

### 4. Notify Team

**Email template:**
```
Subject: GitLab Upgrade Rollback - [Date]

Team,

We attempted to upgrade GitLab from vX to vY this weekend but encountered [issue].

Status:
- ✅ Rolled back to vX.X.X successfully
- ✅ All services operational
- ✅ Zero data loss
- ✅ Git operations verified working

Next steps:
- Root cause investigation in progress
- Will schedule new maintenance window after fix identified

GitLab is fully operational on previous version.
```

---

## Prevention Best Practices

To avoid needing rollback:

1. **Test on clone first** - AMI clone strategy catches issues before production
2. **Wait for migrations** - Most failures from impatience
3. **Monitor disk space** - #1 cause of upgrade failures
4. **Read release notes** - Catch config deprecations
5. **Verify backups** - Test restoration before upgrade
6. **One version at a time** - Never skip versions
7. **Schedule buffer time** - Don't rush

---

## Emergency Contacts

If rollback fails:

- **GitLab Support:** https://about.gitlab.com/support/
- **AWS Support:** https://aws.amazon.com/premiumsupport/
- **Your team's escalation contact**

---

## Rollback Checklist

After rollback:

- [ ] GitLab version correct (match pre-upgrade)
- [ ] All services running (`gitlab-ctl status`)
- [ ] Health check passed (`gitlab-rake gitlab:check`)
- [ ] Git operations work (clone/push/pull)
- [ ] Web interface accessible
- [ ] Jenkins/CI can connect (if applicable)
- [ ] Team notified of rollback
- [ ] Incident documented
- [ ] Root cause investigation pending

---

**Previous:** [04-troubleshooting.md](04-troubleshooting.md) - Common upgrade issues
