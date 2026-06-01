# AWS EC2 Free Tier Setup

AWS EC2 Free Tier is the practical small-storage path for this project. Keep downloads small, private, and temporary.

Target:

- Region: Asia Pacific Tokyo, `ap-northeast-1`
- Instance: `t2.micro` or `t3.micro`, Free Tier eligible
- OS: Ubuntu 24.04 LTS or Ubuntu 22.04 LTS
- Storage: 30 GB gp3 EBS maximum
- Download folder target: under 10 GB
- Access: SSH first, then Tailscale
- Public inbound: SSH only from your IP
- qBittorrent Web UI, Nginx files, and FastAPI: Tailscale-only

Do not use:

- Elastic IP
- NAT Gateway
- Load Balancer
- S3 storage for downloaded files
- Extra EBS volume
- Public qBittorrent, Nginx, or FastAPI ports

## 1. AWS Account Safety Checklist

Before creating EC2:

- Confirm you are in AWS Free Tier or understand current charges.
- Use region `Asia Pacific (Tokyo) ap-northeast-1`.
- Use only Free Tier eligible EC2 instance types.
- Use one root EBS volume only.
- Keep EBS storage at or below 30 GB gp3.
- Do not allocate Elastic IP.
- Do not create NAT Gateway.
- Do not create Load Balancer.
- Do not create extra EBS volumes.
- Do not use S3 for downloaded files.

## 2. Budget Alert Setup

Create a budget before running the project.

AWS Console:

```text
Billing and Cost Management
→ Budgets
→ Create budget
→ Use a template
→ Zero spend budget or Monthly cost budget
```

Recommended:

- Budget type: Cost budget
- Period: Monthly
- Amount: low alert amount you are comfortable with
- Email alerts: your email address
- Alert threshold: 80% and 100%

Wait until the budget exists before creating the instance.

## 3. EC2 Instance Creation

AWS Console:

```text
EC2
→ Instances
→ Launch instances
```

Use:

```text
Name: personal-cloud-downloader
Region: Asia Pacific Tokyo, ap-northeast-1
AMI: Ubuntu Server 24.04 LTS or Ubuntu Server 22.04 LTS
Architecture: x86_64
Instance type: t2.micro or t3.micro, Free Tier eligible
Key pair: create new or select existing
Storage: 30 GB gp3 maximum
Public IP: enabled for SSH setup
```

Do not add extra storage.

## 4. Security Group Rules

Create one security group for the instance.

Inbound rules:

| Type | Port | Source |
|---|---:|---|
| SSH | 22 | Your current public IP only |

Do not add inbound rules for:

- `8080` qBittorrent Web UI
- `8090` Nginx files
- `8000` FastAPI

Outbound can stay default for initial setup.

## 5. SSH Key Handling

If creating a new key pair:

- Type: RSA or ED25519
- Format: `.pem` for macOS/Linux/WSL
- Store it somewhere private
- Do not commit it to git

Set local permissions:

```bash
chmod 600 /path/to/key.pem
```

Connect:

```bash
ssh -i /path/to/key.pem ubuntu@EC2_PUBLIC_IP
```

If SSH fails, check:

- EC2 instance state is running
- Security group allows port 22 from your current IP
- Username is `ubuntu`
- Key file matches the EC2 key pair

## 6. Server Install Plan

After SSH works, install only base packages first:

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y curl wget git unzip htop ufw
```

Check disk:

```bash
df -h
```

Create small torrent folders:

```bash
sudo mkdir -p /srv/torrents/downloads /srv/torrents/incomplete /srv/torrents/watch
```

Keep downloaded files under 10 GB total.

## 7. Tailscale Private Access

Install Tailscale after SSH works:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Confirm Tailscale IP:

```bash
tailscale ip -4
```

Use this Tailscale IP for private qBittorrent, Nginx, and FastAPI access later.

Keep AWS security group public inbound as SSH only.

## 8. qBittorrent Setup

Install qBittorrent only after base server and Tailscale access are ready:

```bash
sudo apt install -y qbittorrent-nox
```

Recommended settings:

- Web UI private through Tailscale only
- Strong qBittorrent password
- Default save path: `/srv/torrents/downloads`
- Incomplete path: `/srv/torrents/incomplete`
- Start torrents paused: on
- Max active downloads: 1
- Keep total download folder under 10 GB

Do not open qBittorrent port `8080` in AWS security group.

## 9. Nginx File Streaming

Install Nginx when ready to stream completed files privately:

```bash
sudo apt install -y nginx
```

Serve completed files from:

```text
/srv/torrents/downloads
```

Use a Tailscale-only URL:

```text
http://TAILSCALE_SERVER_IP:8090/files/
```

Do not open Nginx file port `8090` in AWS security group.

## 10. Cleanup Rule

On AWS Free Tier, storage is small. Delete files older than 1 day.

Example cleanup values:

```bash
DOWNLOAD_DIR="/srv/torrents/downloads"
INCOMPLETE_DIR="/srv/torrents/incomplete"
DAYS_TO_KEEP_COMPLETED=1
DAYS_TO_KEEP_INCOMPLETE=1
```

Manual cleanup command pattern:

```bash
find "$DOWNLOAD_DIR" -type f -mtime +"$DAYS_TO_KEEP_COMPLETED" -print -delete
find "$INCOMPLETE_DIR" -type f -mtime +"$DAYS_TO_KEEP_INCOMPLETE" -print -delete
find "$DOWNLOAD_DIR" "$INCOMPLETE_DIR" -type d -empty -print -delete
```

Review paths before running delete commands.

## 11. Cost Safety Checklist

Before leaving the server running:

- AWS Budget alert exists.
- Region is `ap-northeast-1`.
- Instance type is Free Tier eligible.
- EBS root volume is 30 GB gp3 maximum.
- No Elastic IP allocated.
- No NAT Gateway exists.
- No Load Balancer exists.
- No extra EBS volume attached.
- No S3 bucket used for downloaded files.
- Security group inbound has SSH only from your IP.
- qBittorrent, Nginx, and FastAPI are reachable only over Tailscale.
- Download folder target stays under 10 GB.
- Cleanup deletes completed and incomplete files older than 1 day.
