---
title: "Upgrading GitLab CE v12 to v18: The SSH Surprise That Almost Ruined Everything"
seoTitle: "GitLab Upgrade"
seoDescription: "Learn about the technical challenges and solutions of upgrading GitLab from version 12 to 18, ensuring zero data loss."
datePublished: Thu Jan 15 2026 15:11:34 GMT+0000 (Coordinated Universal Time)
cuid: cmkfl7zi1000602l1h5osb4o2
slug: gitlab-upgrade
tags: git, developer, devops, ssh, infrastructure, gitlab, devops-articles, devops-journey, ssh-git, devopscommunity

---

40 hours. 24 upgrade steps. 100+ repositories. Zero data loss.

I thought I was done.

It was Monday morning, 9 AM. I'd been working since Friday night - a weekend marathon through 22 GitLab versions and 2 OS migrations. Every check passed: GitLab version correct, all services running, Git operations working from my laptop.

Time for the production cutover. I swapped the Load Balancer to the upgraded instance and triggered a Jenkins pipeline.

```bash
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
Host key verification failed.
fatal: Could not read from remote repository.
```

My heart sank. **Work hours were starting in an hour.** Every CI/CD pipeline was broken.

But let me start from the beginning.

## The Problem: Six Years of Technical Debt

Our GitLab instance was running version 12.1.6. To put that in perspective, this version was released in **August 2019**. Meanwhile, GitLab had already shipped version 18 with massive improvements in CI/CD, security scanning, and container registry management.

But here's the thing about GitLab upgrades - you can't just jump from v12 to v18. GitLab's architecture relies heavily on background database migrations, and skipping versions means you'll corrupt your data. The official upgrade path looked like this:

```plaintext
12.1.6 → 12.10.14 → 13.0.14 → 13.1.11 → 13.8.8 → 13.12.15 
→ Ubuntu 16.04 → 18.04 (OS upgrade)
→ 14.0.12 → 14.3.6 → 14.9.5 → 14.10.5 → 15.0.5 → 15.4.6 
→ 15.11.13 → 16.3.9 → 16.7.10 → 16.11.10 
→ Ubuntu 18.04 → 20.04 (OS upgrade)
→ 17.1.8 → 17.3.7 → 17.5.5 → 17.8.7 → 17.11.7 
→ 18.2.8 → 18.5.2
```

**22 upgrade steps. 2 full OS migrations. ~40 hours of execution time.**

And every single step had to complete successfully, or we'd be stuck with a broken GitLab instance serving 100+ repositories in production.

## Why We Couldn't Delay This Any Longer

You might be wondering: "Why not just spin up a new GitLab instance on the latest version?"

Fair question. Here's why that wasn't an option:

1. **100+ repositories** with years of commit history, issues, merge requests, CI/CD variables
    
2. **Active development teams** across multiple modules of the product
    
3. **Integrated CI/CD pipelines** that were tightly coupled to this instance
    
4. **No documented migration path** for moving that much data safely
    
5. **Zero budget** for downtime during business hours
    

We needed an **in-place upgrade** strategy that prioritized data integrity over speed.

## The Strategy: Clone, Optimize, Upgrade

**Never upgrade production directly.** I created an AMI snapshot, launched a clone, performed all 24 upgrades there, then swapped via Load Balancer. Instant rollback capability if needed.

**Performance hack:** Increased EBS IOPS from 3000 to 16000 and throughput to 1000 MB/s before starting. Background migrations are I/O-bound, not CPU-bound. This cut migration time by **30-40%**.

**The hard truth about GitLab upgrades:**

* You cannot skip versions (database migrations are sequential)
    
* Background migrations must reach **zero** before proceeding
    
* Large instances need 2-4 hours per major version
    
* Disk space will kill you (each backup is 8GB+)
    

## The Verified Upgrade Path

Before diving in, here's the exact path I followed (tested and proven):

```plaintext
# 22 GitLab version steps + 2 OS upgrades
12.1.6 → 12.10.14 → 13.0.14 → 13.1.11 → 13.8.8 → 13.12.15 
→ Ubuntu 16.04 → 18.04 (OS upgrade)
→ 14.0.12 → 14.3.6 → 14.9.5 → 14.10.5 → 15.0.5 → 15.4.6 
→ 15.11.13 → 16.3.9 → 16.7.10 → 16.11.10 
→ Ubuntu 18.04 → 20.04 (OS upgrade)
→ 17.1.8 → 17.3.7 → 17.5.5 → 17.8.7 → 17.11.7 
→ 18.2.8 → 18.5.2
```

Each step followed this workflow:

```bash
# 1. Stop services
gitlab-ctl stop puma
gitlab-ctl stop sidekiq
# OR gitlab-ctl stop

# 2. Install target version
apt-get install gitlab-ce=<VERSION>-ce.0

# 3. Reconfigure and restart
gitlab-ctl reconfigure
gitlab-ctl restart
sleep 180  # Wait for stabilization

# 4. Verify
gitlab-ctl status
gitlab-rake gitlab:check SANITIZE=true

# 5. CRITICAL: Wait for migrations to complete
gitlab-rails runner "puts Gitlab::BackgroundMigration.remaining"
# Must be 0 before proceeding

gitlab-rails runner "puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count"
# Must be 0 (for v14+) before proceeding
```

Simple in theory. Reality had other plans.

## The Journey: Saturday Morning to Monday Crisis

### **Saturday 8 AM: Steps 1-5 (v12 → v13)**

First few upgrades went smooth. Then hit **v13.0.14**:

```bash
Error: Puma failed to bind to 127.0.0.1:8080
```

GitLab v13 replaced Unicorn with Puma. Nginx was still pointing to Unicorn's port.

**Fix:** Updated `/etc/gitlab/gitlab.rb`:

```ruby
puma['port'] = 8085
gitlab_workhorse['auth_backend'] = "http://localhost:8085"
```

Reconfigured. Back on track.

**Lesson 1: Read release notes for breaking changes.**

### **Saturday Evening: The Waiting Game Begins (v14.0.12)**

This was the first version with **batched background migrations**. Ran the check:

```bash
gitlab-rails runner "puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count"
# Output: 47
```

Watched the count tick down over **3 hours**: `47 → 34 → 21 → 8 → 2 → 1 → 0`

Sidekiq was crunching through millions of database rows. No way to speed it up - just wait.

**Lesson 2: Budget 2-4 hours per major version for large instances. Get coffee.**

### **Sunday Afternoon: Steps 10-15 (v15 → v16)**

Hitting stride. Then **v16.3.9** failed:

```bash
gitaly['custom_hooks_dir'] has been deprecated since 15.10 and was removed in 16.0.
```

Had to comment out the old config line. GitLab keeps deprecating and changing config structure.

**Lesson 3: Check deprecation notices. They WILL break your upgrade.**

### **Sunday Night 11 PM: The Disk Space Crisis (v17.8.7)**

Halfway through step 19, the upgrade froze. Checked disk:

```bash
df -h
# Filesystem   Size  Used Avail Use% Mounted on
# /dev/xvda1   150G  149G  0    100%  /
```

**Zero bytes free.** Each upgrade created an 8GB backup. After 17 steps = ~136GB of backups, plus the OS and GitLab installation filled the 150GB volume completely.

Emergency cleanup:

```bash
cd /var/opt/gitlab/backups/
ls -ltrh  # List oldest first
rm -f <old-backups>  # Kept last 3-4 critical ones
df -h  # Now 23% free
```

Resumed the upgrade.

**Lesson 4: Keep 30% free space. Monitor obsessively.**

### **Monday 7 AM: Final Push (v17 → v18)**

Vivek, my colleague had joined me Sunday night. We powered through the last 5 versions. By 9 AM, reached **v18.5.2**.

Every check passed:

```bash
cat /opt/gitlab/version-manifest.txt | grep gitlab-ce
# gitlab-ce 18.5.2

gitlab-rake gitlab:check SANITIZE=true
# All checks passed ✅

git clone https://<gitlab>/test-repo.git  # Worked ✅
```

Time for production cutover.

## The Final Boss: SSH Host Keys

**Monday morning, 9 AM.** I'd been working since Friday night:

* Friday: 3 hours of prep and planning
    
* Saturday: 16 hours straight (8AM-12AM) through versions 12-15
    
* Sunday: Started 7AM, worked through the night with my colleague Vivek
    
* Monday: Reached v18.5.2 at 9 AM, ready for cutover
    

I ran all verification checks. Everything passed:

* ✅ GitLab version correct
    
* ✅ All services running
    
* ✅ Git clone/push working from my laptop
    
* ✅ Web interface accessible
    

Time to celebrate, right?

I swapped the Load Balancer to point to the upgraded instance. Then I triggered a Jenkins pipeline to deploy our dev environment.

**ERROR. Build failed.**

```bash
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
Someone could be eavesdropping on you right now (man-in-the-middle attack)!
...
Host key verification failed.
fatal: Could not read from remote repository.
```

My heart sank. The error message screamed "**SECURITY BREACH**" in all caps.

### The Mystery

Here's what was confusing:

* Git operations worked fine from my laptop
    
* The GitLab web interface was accessible
    
* I could browse repos, view code, everything looked normal
    
* But Jenkins couldn't connect via SSH
    

I swapped back to the old instance. Jenkins pipelines worked immediately.

Swapped to the upgraded instance. Pipelines failed with the same SSH error.

### The Root Cause

After couple of hours of debugging, I discovered: **The SSH host keys had changed between the old and new instance.**

When you clone a GitLab instance and the SSH host keys change (whether due to cloud-init regeneration, security scripts, or manual changes), systems like Jenkins that use SSH with strict host key checking will detect this as a security risk.

**Why this happens with AMI clones:**

* Some cloud-init configurations regenerate SSH keys on first boot ([cloud-init docs](https://cloudinit.readthedocs.io/en/latest/reference/modules.html#ssh))
    
* Security hardening scripts may regenerate keys
    
* Manual SSH service restarts with key regeneration
    
* Different hostname/IP requiring new known\_hosts entry
    

**The mismatch:**

* **Jenkins had:** Old GitLab's SSH fingerprint in `/var/jenkins_home/.ssh/known_hosts`
    
* **New instance had:** Different SSH host keys
    
* **SSH's response:** Refuse connection (potential man-in-the-middle attack)
    

### The Fix

I needed to copy the original SSH host keys from the old instance to the upgraded instance:

```bash
# On the OLD GitLab instance
sudo tar -czf /tmp/ssh_host_keys.tar.gz /etc/ssh/ssh_host_*

# Copy to the new instance
scp /tmp/ssh_host_keys.tar.gz new-gitlab-instance:/tmp/

# On the UPGRADED GitLab instance
sudo tar -xzf /tmp/ssh_host_keys.tar.gz -C /
sudo systemctl restart ssh

# Verify the fingerprint now matches the old instance
ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub
```

After restarting SSH, I triggered the Jenkins pipeline again.

**Build succeeded. ✅**

**Time: 11 AM Monday.** The team could start work with zero disruption.

### The Lesson

If you're using an AMI clone strategy for upgrades (which I still recommend), remember:

* **SSH host keys might change**
    
* **Any SSH clients with strict host key checking will fail**
    
* **Copy the original** `/etc/ssh/ssh_host_*` files to preserve identity
    

This issue would affect:

* CI/CD systems (Jenkins, GitLab CI runners on other servers, GitHub Actions self-hosted)
    
* Automated deploy scripts using SSH
    
* Any system with GitLab's SSH fingerprint in `known_hosts`
    

## The Results: Zero Data Loss, Hard-Won Lessons

After 40+ hours of upgrade work + 2 hours debugging SSH, we finally had a fully functional GitLab **v18.5.2**.

**Metrics:**

* ✅ **22 upgrade steps completed**
    
* ✅ **Zero data loss** across 100+ repositories
    
* ✅ **2 OS migrations** (Ubuntu 16 → 18 → 20)
    
* ✅ **All CI/CD pipelines working** (after SSH key fix)
    

**Final verification:**

```bash
# Verify version
cat /opt/gitlab/version-manifest.txt | grep gitlab-ce
# Output: gitlab-ce 18.5.2

# Full system health check
gitlab-rake gitlab:check SANITIZE=true
# Output: All checks passed ✓

# Test git operations
git clone https://<gitlab-url>/test-repo.git
cd test-repo
touch test.txt
git add . && git commit -m "Post-upgrade test" && git push
# Success ✓
```

## What I'd Do Differently

Looking back, here's what I learned:

### 1\. **Automate Migration Monitoring**

I wrote this script midway through:

```bash
#!/bin/bash
# check-migrations.sh

echo "=== Background Migrations ==="
gitlab-rails runner "puts Gitlab::BackgroundMigration.remaining"

echo "=== Batched Migrations (v14+) ==="
gitlab-rails runner "puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count"

echo "=== Active Batched Migrations ==="
gitlab-rails runner "
  Gitlab::Database::BackgroundMigration::BatchedMigration.active.each do |m|
    puts \"#{m.job_class_name} - #{m.table_name} (#{m.progress}%)\"
  end
"
```

Saved me hours of manual checking.

### 2\. **Pre-allocate Disk Space**

I should have:

* Expanded the EBS volume by 50-100GB **before** starting
    
* Configured automated cleanup of old backups
    
* Monitored disk usage with CloudWatch alarms
    

### 3\. **Document Every Config Change**

I made ~15 config changes across `/etc/gitlab/gitlab.rb`. Tracking them in a version-controlled file would have saved confusion during rollback scenarios.

### 4\. **Test Rollback Procedures**

I created AMI snapshots but never tested restoring from them. In production, you want to **verify** your rollback path works, not discover it's broken when you need it most.

## Key Takeaways

If you're planning a major GitLab upgrade:

1. **Clone first, upgrade later** - Work on an AMI clone, not production
    
2. **Copy SSH host keys** from old to new instance to preserve identity
    
3. **Increase EBS IOPS/throughput** - Migrations are I/O-bound (saves hours)
    
4. **Read the official upgrade path tool**: [https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/)
    
5. **Never skip versions** - You'll corrupt your database
    
6. **Wait for background migrations to finish** - Both types must be zero
    
7. **Monitor disk space aggressively** - Backups will fill your drives (keep 30% free)
    
8. **Budget 2-4 hours per major version** for large instances
    
9. **Test integration points** - Don't just check Git works, test your CI/CD
    
10. **Document everything** - You'll need it when troubleshooting
    

## The GitHub Repository

I've open-sourced my complete upgrade documentation, scripts, and runbooks on GitHub:

**🔗** [gitlab-upgrade](https://github.com/vishalrath0d/gitlab-upgrade)

It includes:

* Step-by-step upgrade procedures
    
* Backup automation scripts
    
* Migration monitoring tools
    
* Troubleshooting playbook
    
* Rollback procedures
    

## Final Thoughts

Upgrading legacy infrastructure is unglamorous work. There are no shiny new features, no satisfying green CI/CD badges at the end. Just the quiet satisfaction of knowing your team can now access 6 years of GitLab improvements without losing a single line of code history.

Was it worth 40+ hours of my life? Absolutely.

Would I recommend this to someone else? Only if you're patient, thorough, and have a solid backup strategy.

---

**Got questions or war stories from your own experiences?** Drop a comment below or connect with me on [LinkedIn](https://linkedin.com/in/vishalrath0d). I'd love to hear what challenges you faced.

If you found this helpful, give the GitHub repo a ⭐ - it helps others find it!

---

**About the Author**

I'm Vishal Rathod, a DevOps Engineer with 3+ years of experience building AWS production infrastructure, CI/CD pipelines, and containerized platforms. Currently working on Kubernetes (EKS) migrations and GitOps implementations.

📫 [vishaljanusingrathod@gmail.com](mailto:vishaljanusingrathod@gmail.com)  
💼 [LinkedIn](https://linkedin.com/in/vishalrath0d)  
🐙 [GitHub](https://github.com/vishalrath0d)

---

**Special Thanks**

To my teammates who supported me through this weekend marathon-especially Vivek, who stayed up through Sunday night and Monday morning debugging sessions. Your support and countless cups of coffee made this possible. 🙏