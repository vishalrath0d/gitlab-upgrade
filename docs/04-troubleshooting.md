# 04: Troubleshooting Guide

Common issues encountered during GitLab major version upgrades and their solutions.

---

## Quick Reference

| gitaly config deprecation   | 15.10+, 16.0+       | [#5](#5-gitaly-configuration-deprecation-v1600) |
| Upload permissions          | 13.0.14             | [#6](#6-upload-permission-errors)               |
| Postgres connectivity       | Any                 | [#7](#7-postgresql-connection-issues)           |
| 502 Bad Gateway             | Any                 | [#8](#8-502-bad-gateway-after-upgrade)          |
| **SSH host key changed**    | **Any (AMI clone)** | [**#9**](#9-ssh-host-key-changed-jenkins-fails) |

---

## 1. Puma Port Conflict (v13.0.14)

### Symptoms
```
Puma failed to bind to 127.0.0.1:8080
GitLab web interface not accessible
nginx showing 502 Bad Gateway
```

### Root Cause
GitLab v13 replaced Unicorn with Puma as the web server. If your existing configuration had Unicorn on a specific port, Puma may conflict or workhorse may still be pointing to the old backend.

### Solution

**Step 1:** Edit `/etc/gitlab/gitlab.rb`:
```ruby
# Configure Puma on a different port
puma['listen'] = '127.0.0.1'
puma['port'] = 8085

# Update workhorse to point to Puma
gitlab_workhorse['auth_backend'] = "http://localhost:8085"

# Comment out any unicorn settings if present
# unicorn['port'] = 8080  # Remove or comment this
```

**Step 2:** Apply changes:
```bash
gitlab-ctl reconfigure
gitlab-ctl restart
```

**Step 3:** Verify:
```bash
# Check Puma is running on correct port
netstat -tlnp | grep 8085

# Test internal API
curl -I http://127.0.0.1:8085/-/health
# Should return: HTTP/1.1 200 OK
```

---

## 2. crond Unknown Flag --no-auto (v14.0.12)

### Symptoms
```
level=error msg="unknown flag `no-auto'"
crond service failing to start
gitlab-ctl status crond shows "down"
```

### Root Cause
GitLab's bundled `go-crond` removed the `--no-auto` flag in v14, but the run script still referenced it.

### Solution

**Step 1:** Backup the run script:
```bash
cp /opt/gitlab/sv/crond/run /root/run.crond.run.bak.$(date +%s)
ls -l /root/run.crond.run.bak.*
```

**Step 2:** Edit the script:
```bash
vim /opt/gitlab/sv/crond/run
```

Find and remove this line:
```bash
--no-auto \
```

The file should look like:
```bash
#!/bin/bash
set -e

exec 2>&1

exec chpst -P \
  /opt/gitlab/embedded/bin/go-crond \
    --include=/var/opt/gitlab/crond
```

**Step 3:** Restart crond:
```bash
gitlab-ctl restart crond
gitlab-ctl status crond
# Should show: run: crond: (pid XXXX)
```

---

## 3. Background Migrations Stuck

### Symptoms
```bash
gitlab-rails runner "puts Gitlab::BackgroundMigration.remaining"
# Output: 47 (not decreasing)

# Or for batched migrations:
gitlab-rails runner "puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count"
# Output: 12 (stuck)
```

### Diagnosis

**Check Sidekiq status:**
```bash
gitlab-ctl status sidekiq
# Should show: run: sidekiq: (pid XXXX)
```

**Check Sidekiq logs:**
```bash
gitlab-ctl tail sidekiq

# Look for errors like:
# - Database deadlocks
# - Memory issues
# - Job timeouts
```

**Check queue stats:**
```bash
gitlab-rails runner "
  require 'sidekiq/api'
  stats = Sidekiq::Stats.new
  puts \"Processed: #{stats.processed}\"
  puts \"Failed: #{stats.failed}\"
  puts \"Busy: #{stats.workers_size}\"
  puts \"Enqueued: #{stats.enqueued}\"
  puts \"Retries: #{stats.retry_size}\"
"
```

### Solutions

**Solution 1: Restart Sidekiq**
```bash
gitlab-ctl restart sidekiq
sleep 10
gitlab-ctl tail sidekiq  # Monitor for activity
```

**Solution 2: Check for failed migrations**
```bash
gitlab-rails runner "
  Gitlab::Database::BackgroundMigration::BatchedMigration.failed.each do |m|
    puts \"FAILED: #{m.job_class_name} - #{m.table_name}\"
    puts \"Error: #{m.last_error}\"
    puts \"---\"
  end
"
```

**Solution 3: Retry failed migrations**
```bash
gitlab-rails runner "
  Gitlab::Database::BackgroundMigration::BatchedMigration.failed.each(&:retry_failed_jobs!)
"
```

**Solution 4: Increase Sidekiq concurrency (if memory allows)**

Edit `/etc/gitlab/gitlab.rb`:
```ruby
sidekiq['concurrency'] = 25  # Default is 10-20, increase cautiously
```

Then:
```bash
gitlab-ctl reconfigure
gitlab-ctl restart sidekiq
```

**Solution 5: Monitor progress over time**
```bash
# Create a monitoring script
watch -n 300 '
  echo "=== Legacy Migrations ==="
  gitlab-rails runner "puts Gitlab::BackgroundMigration.remaining"
  echo ""
  echo "=== Batched Migrations ==="
  gitlab-rails runner "puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count"
  echo ""
  echo "Time: $(date)"
'
```

### Expected Behavior

For large GitLab instances (100+ repos):
- **Minor version upgrades:** Migrations may take 30-90 minutes
- **Major version upgrades (14.x, 15.x, 16.x):** Can take 2-4 hours
- **Very large tables:** Some migrations process millions of rows

**Be patient.** As long as Sidekiq is running and the count is decreasing, migrations are progressing.

---

## 4. Disk Space Full During Upgrade

### Symptoms
```bash
df -h
# Filesystem      Size  Used Avail Use% Mounted on
# /dev/xvda1       80G   79G   100M  99% /

apt-get install gitlab-ce=X.Y.Z
# Error: No space left on device
```

### Root Cause
Each upgrade creates an automatic backup (8+ GB for large instances). After 10-15 upgrades, backup files consume all `/var` space.

### Immediate Fix

**Step 1: Identify large files:**
```bash
cd /var/opt/gitlab/backups/
ls -ltrh

# Output example:
# -rw------- 1 git git 8.1G Nov 15 17:35 1763227817_2025_11_15_15.4.6_gitlab_backup.tar
# -rw------- 1 git git 8.2G Nov 16 17:35 1763314229_2025_11_16_18.5.2_gitlab_backup.tar
# ... (many more)
```

**Step 2: Keep critical backups, remove old ones:**
```bash
# Keep last 3-4 backups (at least one full, recent backups)
rm -f 1763185386_2025_11_15_12.1.6_gitlab_backup.tar
rm -f 1763188811_2025_11_15_12.10.14_gitlab_backup.tar
rm -f 1763191107_2025_11_15_13.0.14_gitlab_backup.tar
# ... delete older backups

# Verify space freed
df -h
# Should show at least 20-30% free
```

**Or use the cleanup script:**
```bash
./scripts/cleanup-old-backups.sh --keep 5 --dry-run  # Preview
./scripts/cleanup-old-backups.sh --keep 5             # Execute
```

### Prevention

**Monitor disk usage:**
```bash
# Add to cron or monitoring
df -h | grep "/$"
```

**Configure automated cleanup:**

Edit `/etc/gitlab/gitlab.rb`:
```ruby
# Limit backup retention
gitlab_rails['backup_keep_time'] = 604800  # 7 days in seconds
```

Apply:
```bash
gitlab-ctl reconfigure
```

---

## 5. gitaly Configuration Deprecation (v16.0.0)

### Symptoms
```
gitaly['custom_hooks_dir'] has been deprecated since 15.10 
and was removed in 16.0. 
See: https://docs.gitlab.com/ee/update/#15100
```

### Solution

**Step 1:** Edit `/etc/gitlab/gitlab.rb`

Find line (around line 690-700):
```ruby
gitaly['custom_hooks_dir'] = "/var/opt/gitlab/gitaly/custom_hooks"
```

**Comment it out:**
```ruby
# gitaly['custom_hooks_dir'] = "/var/opt/gitlab/gitaly/custom_hooks"
```

**Step 2:** GitLab v16+ uses a different structure. If you need custom hooks, configure them per-repository or use server hooks. See: https://docs.gitlab.com/ee/administration/server_hooks.html

**Step 3:** Reconfigure:
```bash
gitlab-ctl reconfigure
```

**Step 4:** Retry the upgrade:
```bash
apt-get install gitlab-ce=16.3.9-ce.0
```

---

## 6. Upload Permission Errors

### Symptoms
```
Uploads directory permissions incorrect
Users cannot upload images/files
GitLab check shows upload permission warnings
```

### Solution

**Fix permissions:**
```bash
chown -R git:git /var/opt/gitlab/gitlab-rails/uploads

# Set correct file permissions
find /var/opt/gitlab/gitlab-rails/uploads -type f -exec chmod 0644 {} \;

# Set correct directory permissions
find /var/opt/gitlab/gitlab-rails/uploads -type d -not -path /var/opt/gitlab/gitlab-rails/uploads -exec chmod 0700 {} \;
```

**Verify:**
```bash
gitlab-rake gitlab:check SANITIZE=true
# Upload section should now pass
```

---

## 7. PostgreSQL Connection Issues

### Symptoms
```
could not connect to server
PG::ConnectionBad
Database migration errors
```

### Diagnosis

**Check PostgreSQL status:**
```bash
gitlab-ctl status postgresql
# Should show: run: postgresql: (pid XXXX)
```

**Check PostgreSQL logs:**
```bash
gitlab-ctl tail postgresql
```

**Test connectivity:**
```bash
gitlab-psql -c "SELECT version();"
```

### Solutions

**Solution 1: Restart PostgreSQL**
```bash
gitlab-ctl restart postgresql
sleep 10
gitlab-ctl status postgresql
```

**Solution 2: Check PostgreSQL version compatibility**
```bash
gitlab-psql --version

# GitLab version requirements:
# GitLab 12-13: PostgreSQL 10-11
# GitLab 14: PostgreSQL 12-13
# GitLab 15+: PostgreSQL 13+
```

**Solution 3: Manual PostgreSQL upgrade (if needed)**
```bash
gitlab-ctl pg-upgrade
```

---

## 8. 502 Bad Gateway After Upgrade

### Symptoms
- Web interface shows "502: Bad Gateway"
- nginx is running but GitLab is inaccessible

### Diagnosis

**Check all services:**
```bash
gitlab-ctl status

# Look for services that are "down"
```

**Check workhorse:**
```bash
gitlab-ctl tail gitlab-workhorse

# Should show active connections, not errors
```

**Verify workhorse config:**
```bash
ps aux | grep workhorse | grep authBackend
# Should show: -authBackend http://localhost:8085 (or your Puma port)
```

**Check nginx logs:**
```bash
gitlab-ctl tail nginx/gitlab_error.log
```

### Solutions

**Solution 1: Verify Puma is running and accessible**
```bash
gitlab-ctl status puma

# Test Puma directly
curl -I http://127.0.0.1:8085/-/health
```

**Solution 2: Restart services in order**
```bash
gitlab-ctl stop

# Start critical services first
gitlab-ctl start postgresql
sleep 5
gitlab-ctl start redis
sleep 5

# Start remaining services
gitlab-ctl start

# Wait for stabilization
sleep 30

gitlab-ctl status
```

**Solution 3: Check workhorse backend config**

Edit `/etc/gitlab/gitlab.rb`:
```ruby
gitlab_workhorse['auth_backend'] = "http://localhost:8085"
```

Apply:
```bash
gitlab-ctl reconfigure
gitlab-ctl restart
```

---

## 9. SSH Host Key Changed (Jenkins Fails)

### Symptoms

**After swapping to upgraded GitLab instance:**
- Git clone/push works from local machine
- GitLab web interface accessible
- **Jenkins pipelines fail** with:

```
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
Someone could be eavesdropping on you right now (man-in-the-middle attack)!
...
The fingerprint for the ECDSA key sent by the remote host is
SHA256:8+dD0uymc8MIcw4N8kpeZ2sIVn9ReRAqaej03bVnUzE.
Please contact your system administrator.
Add correct host key in /var/jenkins_home/.ssh/known_hosts to get rid of this message.
Offending ECDSA key in /var/jenkins_home/.ssh/known_hosts:11
Host key verification failed.
fatal: Could not read from remote repository.
```

### Root Cause

When you clone your GitLab instance using AMI and launch a new EC2 instance, **AWS generates new SSH host keys** (`/etc/ssh/ssh_host_*`). 

Even though you copied all GitLab data and configurations, the new instance has a different SSH identity (fingerprint). Systems like Jenkins that use SSH with strict host key checking will detect this as a potential security risk and refuse to connect.

**Why it works locally but not from Jenkins:**
- Local Git clients using **HTTPS** or **password auth** don't care about SSH keys
- Jenkins using **SSH with strict host checking** requires exact fingerprint match
- Jenkins has the **old fingerprint** in `/var/jenkins_home/.ssh/known_hosts`
- New instance has a **different fingerprint**
- SSH refuses connection

### Diagnosis

**Check fingerprints differ between old and new:**

```bash
# On OLD GitLab instance
ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub
# Output: SHA256:OldFingerprint...

# On NEW (upgraded) instance
ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub
# Output: SHA256:NewFingerprint... (DIFFERENT!)
```

**Test SSH connection from Jenkins:**

```bash
# From Jenkins server
ssh -T git@<gitlab-domain>
# Will show: WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
```

### Solutions

**Option 1: Copy SSH Host Keys from Old Instance (RECOMMENDED)**

This preserves the same SSH identity and requires **no changes** to Jenkins or other systems.

**Step 1:** Backup SSH host keys from old instance:

```bash
# On the OLD GitLab instance
sudo tar -czf /tmp/ssh_host_keys.tar.gz /etc/ssh/ssh_host_*

# Verify backup
tar -tzf /tmp/ssh_host_keys.tar.gz
```

**Step 2:** Copy to new instance:

```bash
# From your workstation
scp ubuntu@old-gitlab:/tmp/ssh_host_keys.tar.gz /tmp/
scp /tmp/ssh_host_keys.tar.gz ubuntu@new-gitlab:/tmp/
```

**Step 3:** Restore on new instance:

```bash
# On the NEW (upgraded) GitLab instance

# Backup current keys (just in case)
sudo tar -czf /tmp/new_ssh_keys_backup.tar.gz /etc/ssh/ssh_host_*

# Restore old keys
sudo tar -xzf /tmp/ssh_host_keys.tar.gz -C /

# Verify permissions
sudo chmod 600 /etc/ssh/ssh_host_*_key
sudo chmod 644 /etc/ssh/ssh_host_*_key.pub

# Restart SSH service
sudo systemctl restart ssh
```

**Step 4:** Verify fingerprint matches:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub
# Should now match the old instance fingerprint
```

**Step 5:** Test from Jenkins:

```bash
# From Jenkins server
ssh -T git@<gitlab-domain>
# Should connect without warnings
```

**Option 2: Update known_hosts on Jenkins (NOT RECOMMENDED)**

This requires updating **every system** that connects to GitLab via SSH.

```bash
# On Jenkins server or CI runner
ssh-keygen -R "git.yourdomain.com"

# Reconnect to update known_hosts
ssh -T git@git.yourdomain.com
# Type 'yes' to accept new fingerprint
```

**Problems with this approach:**
- Must update every Jenkins server, CI runner, developer machine
- Error-prone and time-consuming
- Breaks automation that relies on known fingerprints
- Future systems may have old fingerprint cached

### Prevention

**Before Cloning:**

If you haven't upgraded yet and plan to use AMI clone strategy:

1. **Backup SSH host keys BEFORE creating AMI:**
   ```bash
   sudo tar -czf /backup/ssh_host_keys.tar.gz /etc/ssh/ssh_host_*
   ```

2. **Include in your upgrade runbook:**
   - Step: "Restore SSH host keys after launch"
   - Command: `sudo tar -xzf /backup/ssh_host_keys.tar.gz -C / && sudo systemctl restart ssh`

3. **Test SSH connectivity** from all integration points before swapping instances

### Who This Affects

- **CI/CD Systems:** Jenkins, GitLab CI (external runners), GitHub Actions (self-hosted), CircleCI (on-prem)
- **Automated deployments:** Scripts using `git clone` via SSH
- **Monitoring tools:** Any system that SSH's to GitLab
- **Developer machines:** Less common (they usually use HTTPS), but possible

### Verification Checklist

Before declaring upgrade complete:

- [ ] Local Git clone/push works (HTTPS)
- [ ] Local Git clone/push works (SSH)
- [ ] Jenkins pipeline successfully clones repos
- [ ] Jenkins can access GitLab shared libraries
- [ ] External CI runners can connect
- [ ] Deployment scripts using SSH work
- [ ] SSH fingerprint matches old instance

**PRO TIP:** Keep the old GitLab instance running for 24-48 hours after cutover to quickly rollback if SSH issues affect systems you didn't test.

---

## Emergency Recovery

If multiple issues occur and GitLab is completely broken:

### Option 1: Rollback to Previous Version

```bash
# Stop GitLab
gitlab-ctl stop

# Install previous version
apt-get install gitlab-ce=<PREVIOUS_VERSION>

# Reconfigure
gitlab-ctl reconfigure
gitlab-ctl restart
```

### Option 2: Restore from AMI Snapshot (AWS)

1. Stop the current instance
2. Launch new instance from the AMI created before upgrade
3. Update DNS/ALB to point to new instance
4. Verify services are running

### Option 3: Restore from Backup

See [05-rollback-procedures.md](05-rollback-procedures.md) for detailed restoration steps.

---

## Getting Help

If you encounter issues not covered here:

1. **Check GitLab logs:**
   ```bash
   gitlab-ctl tail  # All logs
   gitlab-ctl tail <service>  # Specific service
   ```

2. **Run system check:**
   ```bash
   gitlab-rake gitlab:check SANITIZE=true
   ```

3. **Search GitLab forums:**
   - https://forum.gitlab.com/
   - Search for your specific error message

4. **Official documentation:**
   - https://docs.gitlab.com/ee/update/
   - https://docs.gitlab.com/ee/update/background_migrations.html

5. **Open an issue:**
   - GitHub: https://github.com/vishal-rath0d/gitlab-upgrade/issues
   - Include: GitLab version, error logs, steps taken

---

**Next:** [05-rollback-procedures.md](05-rollback-procedures.md) - Learn how to safely rollback if needed
