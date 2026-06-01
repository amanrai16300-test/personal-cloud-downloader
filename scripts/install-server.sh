#!/usr/bin/env bash
set -euo pipefail

echo "Personal Cloud Downloader server setup checklist"
echo
echo "This script prints safe setup steps only. Review each command before running it."
echo
echo "1. Update server packages:"
echo "   sudo apt update"
echo "   sudo apt upgrade -y"
echo
echo "2. Install required packages:"
echo "   sudo apt install -y python3 python3-venv python3-pip nginx qbittorrent-nox ufw curl"
echo
echo "3. Create torrent folders:"
echo "   sudo mkdir -p /srv/torrents/downloads /srv/torrents/incomplete"
echo
echo "4. Install and connect Tailscale:"
echo "   curl -fsSL https://tailscale.com/install.sh | sh"
echo "   sudo tailscale up"
echo
echo "5. Configure firewall for private Tailscale access:"
echo "   sudo ufw allow OpenSSH"
echo "   sudo ufw allow in on tailscale0 to any port 8080 proto tcp"
echo "   sudo ufw allow in on tailscale0 to any port 8000 proto tcp"
echo "   sudo ufw allow in on tailscale0 to any port 8090 proto tcp"
echo "   sudo ufw enable"
echo
echo "Do not open qBittorrent, FastAPI, or Nginx file ports publicly."
