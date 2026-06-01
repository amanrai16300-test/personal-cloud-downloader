# Security

This project is for private Tailscale-only access.

## Required Rules

- Use Tailscale for private access.
- Keep qBittorrent Web UI private.
- Keep FastAPI private.
- Keep Nginx file links private.
- Use a strong qBittorrent password.
- Use a strong `APP_API_KEY`.
- Keep `backend/.env` out of git.
- Download only legal files.

## Firewall Rules

Public inbound rules should stay minimal.

Recommended public access:

- SSH only, ideally restricted to your IP

Tailscale-only access:

- qBittorrent Web UI port, commonly `8080`
- FastAPI backend port, commonly `8000`
- Nginx file server port, commonly `8090`

Example UFW rules:

```bash
sudo ufw allow OpenSSH
sudo ufw allow in on tailscale0 to any port 8080 proto tcp
sudo ufw allow in on tailscale0 to any port 8000 proto tcp
sudo ufw allow in on tailscale0 to any port 8090 proto tcp
sudo ufw enable
```

## Do Not Expose Publicly

- qBittorrent port `8080`
- FastAPI port `8000`
- Nginx file server port `8090`

Do not add these ports to public cloud security lists.
