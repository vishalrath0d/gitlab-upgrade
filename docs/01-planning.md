# 01: Planning and Prerequisites

A comprehensive pre-upgrade planning guide to ensure a successful GitLab migration with zero data loss.

---

## Overview

This guide covers the critical planning phase before starting a major GitLab version upgrade. Proper planning is the difference between a smooth weekend project and a production disaster.

---

## Prerequisites Checklist

### System Requirements

- [ ] **Root/sudo access** to the GitLab server
- [ ] **Minimum 30% free disk space** on `/var` partition
- [ ] **AWS CLI installed** (for AMI snapshots)
- [ ] **Backup destination** with sufficient storage (~100GB per environment)
- [ ] **Maintenance window** scheduled (recommend weekend)

### Knowledge Requirements

- [ ] **Understanding of your GitLab architecture**
  - Single instance vs HA setup
  - External PostgreSQL or bundled
  - Storage backend (NFS, local, object storage)
- [ ] **Familiarity with Linux package management** (apt/yum)
- [ ] **Basic PostgreSQL knowledge** (for troubleshooting)
- [ ] **SSH and Git operations** (for verification)

---

## Pre-Upgrade Assessment

### 1. Document Current State

Create a baseline snapshot of your environment:

```bash
# GitLab version
cat /opt/gitlab/version-manifest.txt | grep gitlab-ce

# OS version
cat /etc/os-release

# PostgreSQL version
gitlab-psql --version

# Disk usage
df -h

# Repository count
gitlab-rake gitlab:env:info | grep Projects

# Active users
gitlab-rails runner "puts User.active.count"
```

Save this output as `pre-upgrade-baseline.txt` for comparison later.

### 2. Identify Your Upgrade Path

Use the official GitLab upgrade path tool:

**Tool:** https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/

**Example:**
- **Current:** 12.1.6
- **Target:** 18.5.2
- **Edition:** CE

**Output:** 22-step upgrade path with required stops

### 3. Estimate Execution Time

Based on instance size:

| Repos  | Estimated Time per Major Version | Total for 6 Major Versions |
| ------ | -------------------------------- | -------------------------- |
| < 50   | 30-60 min                        | 3-6 hours                  |
| 50-100 | 1-2 hours                        | 6-12 hours                 |
| 100+   | 2-4 hours                        | 12-24 hours                |

**Add:**
- OS upgrade time: 1-2 hours per upgrade
- Troubleshooting buffer: 20-30%
- Testing and verification: 2-3 hours

---

## Risk Assessment

### Critical Risks

| Risk                         | Likelihood | Impact   | Mitigation                               |
| ---------------------------- | ---------- | -------- | ---------------------------------------- |
| Disk space exhaustion        | High       | Critical | Monitor `/var`, cleanup old backups      |
| Background migration timeout | Medium     | High     | Increase Sidekiq workers, wait patiently |
| PostgreSQL upgrade failure   | Low        | Critical | AMI snapshot before OS upgrade           |
| Config deprecation issues    | Medium     | Medium   | Review release notes per version         |
| SSH key mismatch (AMI clone) | High       | Medium   | Copy SSH host keys from original         |

### Rollback Scenarios

Prepare for:
- **Version rollback:** Restore from package version
- **OS rollback:** Restore from AMI snapshot
- **Data rollback:** Restore from backup tarball

---

## Infrastructure Preparation

### Option A: Clone Strategy (Recommended)

**✅ Advantages:**
- Zero risk to production
- Instant rollback (swap ALB target)
- Test upgrade on production data clone

**Workflow:**
1. Create AMI of running production GitLab instance
2. Launch clone from AMI
3. Perform all upgrades on clone
4. Test thoroughly
5. Swap Load Balancer target to clone
6. Keep original for 24-48 hours as fallback

**AWS Commands:**
```bash
# Create AMI
aws ec2 create-image \
  --instance-id i-xxxxx \
  --name "gitlab-prod-clone-$(date +%Y%m%d)" \
  --description "Pre-upgrade clone for testing" \
  --no-reboot

# Launch from AMI
aws ec2 run-instances \
  --image-id ami-xxxxx \
  --instance-type t3.medium \
  --subnet-id subnet-xxxxx \
  --security-group-ids sg-xxxxx \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=gitlab-clone}]'
```

### Option B: In-Place Upgrade

**⚠️ Higher Risk** - Only if clone not possible

**Requirements:**
- Verified backup restoration tested
- Rollback plan documented
- Extended maintenance window

---

## Performance Optimization

### Increase EBS IOPS (AWS)

Background migrations are **I/O-bound**, not CPU-bound.

**Before starting:**
```bash
# Check current IOPS
aws ec2 describe-volumes \
  --volume-ids vol-xxxxx \
  --query "Volumes[0].[Iops,Throughput]"

# Modify volume (requires restart)
aws ec2 modify-volume \
  --volume-id vol-xxxxx \
  --iops 16000 \
  --throughput 1000
```

**Expected improvement:** 30-40% faster migrations

### Increase Sidekiq Workers

Edit `/etc/gitlab/gitlab.rb`:
```ruby
sidekiq['concurrency'] = 25  # Default: 10-20
```

Then:
```bash
gitlab-ctl reconfigure
gitlab-ctl restart sidekiq
```

---

## Team Communication

### Stakeholder Notification

**Who to notify:**
- Engineering teams (developers)
- DevOps/SRE team
- Product/Project managers
- Security team (if applicable)

**What to communicate:**
- Maintenance window dates/times
- Expected downtime (if any)
- Backup plan and rollback strategy
- Contact person for issues

**Sample Email:**
```
Subject: GitLab Upgrade Maintenance - [Date]

Team,

We will be upgrading our GitLab instance from v12 to v18 this weekend.

Timeline:
- Saturday 8 AM - 12 AM: Upgrade steps 1-15
- Sunday 7 AM - Monday 9 AM: Upgrade steps 16-22
- Monday 9 AM: Production cutover

Impact:
- GitLab will be accessible (read-only) during upgrade
- No pushes/merges during maintenance window
- Jenkins pipelines may be paused temporarily

Rollback plan: We have AMI snapshots and can revert within 10 minutes if needed.

Point of contact: [Your name/Slack/Email]
```

---

## Backup Strategy Planning

See [03-backup-strategy.md](03-backup-strategy.md) for comprehensive backup procedures.

**Minimum backups required:**
- [ ] Full GitLab backup before starting
- [ ] AMI snapshot before each OS upgrade
- [ ] Configuration backup (`/etc/gitlab/`)
- [ ] SSH host keys backup (`/etc/ssh/ssh_host_*`)

---

## Post-Upgrade Verification Plan

Define success criteria **before** starting:

```bash
# Must pass all checks:
gitlab-rake gitlab:check SANITIZE=true

# Test operations:
git clone https://<gitlab-url>/test-repo.git
cd test-repo
touch test-file.txt
git add . && git commit -m "Test" && git push

# Verify integrations:
# - Jenkins can clone repos via SSH
# - Webhooks trigger correctly
# - API access works
# - CI/CD pipelines run
```

---

## Final Checklist

Before starting the upgrade:

- [ ] Upgrade path documented
- [ ] Backups created and verified
- [ ] AMI snapshots created
- [ ] Disk space > 30% free
- [ ] Team notified
- [ ] Rollback plan documented
- [ ] Test environment verified (if using clone)
- [ ] SSH host keys backed up
- [ ] EBS IOPS increased (optional but recommended)
- [ ] Maintenance window scheduled
- [ ] Support contact ready (colleague/AWS support)

---

**Next:** [02-upgrade-path.md](02-upgrade-path.md) - Detailed step-by-step upgrade procedures
