# Deploying to AWS EC2

Two paths. Pick the one that matches what you have:

| You have | Use | Start at |
|---|---|---|
| An Ubuntu instance already running | `ubuntu-setup.sh` + `attach-role.sh` | [Ubuntu: existing instance](#ubuntu-adopting-an-instance-you-already-have) |
| Nothing yet, want it fully automated | `01` → `02` → `03` | [Fresh Amazon Linux instance](#fresh-amazon-linux-instance) |

Either way, HP credentials live in AWS Secrets Manager and are never stored in
the repo or baked into an image.

---

## Ubuntu: adopting an instance you already have

For a box where you cloned the repo by hand (e.g. `/home/ubuntu/HPAPI`) and are
running `uvicorn` from the terminal. This keeps your code where it is and adds
the missing production pieces: a working virtualenv, systemd so the app survives
logout and reboot, nginx on port 80, and Secrets Manager wiring.

**Rotate your HP credentials first** — see [Before you start](#before-you-start).

### 1. On your Mac — store the credentials

```bash
cd ~/FreedomPaper/ClaudeDesign/hp_printer_images
./deploy/01-put-secrets.sh
```

### 2. On your Mac — give the instance permission to read them

```bash
./deploy/attach-role.sh
```

Auto-detects your instance if only one is running; otherwise pass
`INSTANCE_ID=i-xxxxxxxx`. Creates an IAM role scoped to that single secret and
attaches it. No instance restart needed — credentials appear within a minute.

### 3. On the instance — run setup

```bash
ssh ubuntu@<your-ip>
cd ~/HPAPI
git pull
sudo ./deploy/ubuntu-setup.sh
```

This is the step that fixes the `.venv/bin/python3: No such file or directory`
error: it installs `python3-venv` (missing by default on Ubuntu, which is why
venv creation failed) and rebuilds the virtualenv from scratch.

It prints a health check and your app URL when it finishes. If step 2 hasn't
propagated yet the script falls back to your local `.env` and warns — re-run
`sudo systemctl restart hp-printer-images-secrets hp-printer-images` once the
role is live.

If a different layout: `sudo APP_DIR=/path/to/repo APP_USER=someuser ./deploy/ubuntu-setup.sh`.

### 4. Day to day

```bash
sudo hp-printer-images-update              # git pull + deps + restart + health check
sudo journalctl -u hp-printer-images -f    # live logs
sudo systemctl restart hp-printer-images   # restart
sudo systemctl status hp-printer-images    # status
```

To rotate a credential: edit `.env` on your Mac → `./deploy/01-put-secrets.sh` →
on the box, `sudo systemctl restart hp-printer-images-secrets hp-printer-images`.

Make sure the instance's security group allows inbound **TCP 80**, or nothing
will reach nginx.

---

## Fresh Amazon Linux instance

Builds everything from nothing on Amazon Linux 2023, with HP credentials held in
AWS Secrets Manager and never stored in the repo or on the instance image.

```
GitHub (public repo)  ──git clone/pull──►  EC2 instance
                                            ├── nginx  :80  ──proxy──► uvicorn :8000
                                            └── systemd pulls credentials at start
                                                        ▲
                                            AWS Secrets Manager (hp-printer-images/env)
```

---

## Before you start

**Rotate your HP credentials first.** `HP_CATALOG_CLIENT_ID` and
`HP_CATALOG_CLIENT_SECRET` were committed to the public repo in commit `1be715a`
and are still readable in git history. Issue new ones in the HP partner portal
and put the new values in your local `.env` before running step 1.

You need, on your Mac:

```bash
brew install awscli          # if you don't have it
aws configure                # access key, secret, default region
aws sts get-caller-identity  # should print your account — confirms it works
```

Your IAM user needs permissions for EC2, IAM (role creation), and Secrets
Manager. An admin-level user is simplest; if you're scoping it down, the calls
used are listed at the bottom of this file.

---

## Deploy (fresh instance)

All commands run from the repo root.

### 1. Review settings

```bash
$EDITOR deploy/config.sh
```

Defaults: `us-east-1`, `t3.small`, HTTP open to the world, SSH locked to your
current public IP. Change `AWS_REGION` and `HTTP_CIDR` if either is wrong for
you.

### 2. Upload credentials to Secrets Manager

```bash
./deploy/01-put-secrets.sh
```

Reads your local `.env` and writes it as a JSON secret named
`hp-printer-images/env`. If you have HP client certificates, include them:

```bash
CLIENT_CERT_FILE=./Freedompaper.pem CLIENT_KEY_FILE=./FreedompaperApi.pem \
  ./deploy/01-put-secrets.sh
```

The PEM contents go into the secret and are materialised on the instance at
`/etc/hp-printer-images/client-cert.pem` at start time — the script rewrites the
`HP_CATALOG_CLIENT_CERT` path for you, so your local paths don't matter.

### 3. Provision infrastructure and launch

```bash
./deploy/02-provision.sh
```

Creates the IAM role (scoped to read *only* this one secret), security group,
key pair (saved to `~/.ssh/hp-printer-images-key.pem`), and launches the
instance. Prints the public IP when done.

Bootstrap then runs for 3–5 minutes on the instance. Watch it:

```bash
ssh -i ~/.ssh/hp-printer-images-key.pem ec2-user@<IP> \
  'sudo tail -f /var/log/hp-printer-images-bootstrap.log'
```

Confirm it's up:

```bash
curl http://<IP>/api/health
# {"status":"ok","catalog_api_configured":true,"country":"US"}
```

Then open `http://<IP>/` in a browser.

### 4. Redeploy after any code change

```bash
git push origin main
./deploy/03-deploy.sh
```

Pulls the new commit, reinstalls dependencies, re-reads secrets, restarts, and
health-checks. Roughly 20 seconds.

To rotate a credential without touching code: edit `.env`, run
`./deploy/01-put-secrets.sh`, then `./deploy/03-deploy.sh`.

---

## Operating a fresh (Amazon Linux) instance

```bash
IP=$(grep PUBLIC_IP deploy/.instance | cut -d= -f2)
SSH="ssh -i ~/.ssh/hp-printer-images-key.pem ec2-user@$IP"

$SSH 'sudo journalctl -u hp-printer-images -f'        # live app logs
$SSH 'sudo systemctl restart hp-printer-images'       # restart
$SSH 'sudo systemctl status hp-printer-images'        # status
$SSH 'sudo tail -f /var/log/nginx/access.log'         # request log
```

Tear it all down when you're finished:

```bash
./deploy/99-destroy.sh
```

---

## Cost

At `t3.small` in `us-east-1`, running continuously: roughly **$15–17/month** for
the instance, **$2/month** for the 20 GB gp3 volume, and **$0.40/month** for the
Secrets Manager secret. Dropping to `t3.micro` halves the compute (set
`INSTANCE_TYPE=t3.micro` in `config.sh`) but leaves little headroom during `pip
install`. Stopping the instance overnight cuts compute proportionally — note the
public IP changes on restart unless you attach an Elastic IP.

---

## Script reference

| Script | Runs on | Purpose |
|---|---|---|
| `config.sh` | — | Shared settings. Sourced by the Mac-side scripts. |
| `01-put-secrets.sh` | Mac | Read local `.env` (+ optional PEMs) → Secrets Manager. |
| `attach-role.sh` | Mac | Create IAM role, attach to an **existing** instance. |
| `ubuntu-setup.sh` | Instance (sudo) | Adopt an existing Ubuntu box: venv, systemd, nginx, secrets. |
| `02-provision.sh` | Mac | Create all AWS resources and launch a **new** AL2023 instance. |
| `user-data.sh` | — | Bootstrap embedded into a new instance by `02-provision.sh`. |
| `03-deploy.sh` | Mac | Redeploy to an instance built by `02-provision.sh`. |
| `99-destroy.sh` | Mac | Tear down everything the scripts created. |

`03-deploy.sh` assumes the Amazon Linux layout (`ec2-user`, `/opt/...`). On the
adopted Ubuntu box use `sudo hp-printer-images-update` on the instance instead.

## Things this setup deliberately does not do

- **No HTTPS.** Traffic is plain HTTP on port 80. For anything beyond testing,
  point a domain at the instance and run `certbot --nginx`, or put an
  Application Load Balancer with an ACM certificate in front of it.
- **No autoscaling or redundancy.** One instance; if it dies, the app is down
  until it restarts. `Restart=always` covers process crashes, not host failure.
- **No Elastic IP.** The public IP changes if you stop and start the instance.
  `03-deploy.sh` re-resolves it each run, so deploys keep working, but any
  bookmark or DNS record won't.
- **No secret caching.** Secrets Manager is read once per service start, not per
  request, so there's no meaningful API cost — but a rotated secret needs a
  restart to take effect.

## AWS API calls used

`sts:GetCallerIdentity` · `ec2:{DescribeVpcs,DescribeSecurityGroups,CreateSecurityGroup,AuthorizeSecurityGroupIngress,DescribeKeyPairs,CreateKeyPair,DescribeInstances,RunInstances,TerminateInstances,DeleteKeyPair,DeleteSecurityGroup}` · `iam:{GetRole,CreateRole,PutRolePolicy,AttachRolePolicy,GetInstanceProfile,CreateInstanceProfile,AddRoleToInstanceProfile,PassRole}` · `secretsmanager:{CreateSecret,PutSecretValue,DescribeSecret,GetSecretValue,DeleteSecret}` · `ssm:GetParameters`
