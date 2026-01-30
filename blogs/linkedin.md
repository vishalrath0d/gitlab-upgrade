🕘 MONDAY MORNING, 9 AM

After 40+ hours, I swapped our upgraded GitLab into production and triggered a Jenkins pipeline.



ERROR. Build failed.

```

WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!

Host key verification failed.

fatal: Could not read from remote repository.

```

Every CI/CD pipeline was broken. This was supposed to be the easy part.



🧩 THE CONTEXT

Last month, I upgraded our production GitLab CE from v12.1.6 (August 2019) to v18.5.2 - 22 version upgrades + 2 OS migrations. 100+ repositories. One rule: zero data loss.



GitLab doesn't let you skip versions. Each upgrade must complete, including background migrations that took hours. One mistake could corrupt years of history.



⏳ THE WEEKEND

Friday

Created AMI clone. Upgraded on the clone, not production.



Saturday (8 AM-12 AM)

16-hour marathon through v12->15.

Watched migrations tick down: 47... 34... 21... 8... 2... 1... 0.



Sunday-Monday

Vivek joined. 26 straight hours through v15->18.



🚨 THE CRISIS MOMENTS

🔴 3 AM disk crisis

Backups filled the 150GB volume mid-upgrade. Cleaned 50GB while stuck between versions.



🔴 Background migrations

Some steps took 3+ hours processing millions of database rows. Can't rush it.



🔴 Monday 9 AM

Everything tested perfectly. Swapped load balancer. GitLab loaded. Jenkins failed.



🧨 THE PROBLEM

The SSH host keys had changed between the old and new instance. Jenkins had the old fingerprint and refused to connect.



Two hours debugging later:

copied `/etc/ssh/ssh_host_*` from original instance.

Five minutes to fix. Two hours to figure out.



🏁 THE RESULTS

✅ 22 GitLab upgrades + 2 OS migrations (Ubuntu 16->18->20)

✅ 100+ repositories intact

✅ Zero data loss

✅ All CI/CD pipelines working



Total: 40+ hours upgrade + 2 hours SSH debugging



🧠 WHAT MADE IT WORK

1️⃣ Clone strategy - AMI snapshot, not production. Instant rollback.

2️⃣ Performance - Increased EBS IOPS 3000->16000. Cut time by 30-40%.

3️⃣ Copy SSH host keys - The lesson that cost me 2 hours.

4️⃣ Disk monitoring - Keep 30%+ free. Each backup is 8GB+.



🎁 GIVING BACK

I've open-sourced the complete guide:

📝 Full story: https://vishalrath0d.hashnode.dev/gitlab-upgrade

🔧 GitHub: https://github.com/vishalrath0d/gitlab-upgrade



Includes:

• Step-by-step procedures for all 22 upgrades

• Automation scripts

• Monitoring tools

• Troubleshooting playbook

• Rollback procedures



Legacy infrastructure upgrades aren't glamorous.

Just the quiet satisfaction of enabling your team to access 6 years of GitLab improvements without losing a commit.



Planning a major upgrade? Drop a comment or DM.



---



#DevOps #GitLab #SRE #InfrastructureEngineering #AWS #Linux #Migration #OpenSource #CloudEngineering