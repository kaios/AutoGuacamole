# AutoGuacamole

An automation script that sets up and configures [Apache Guacamole](https://guacamole.apache.org/) with security and Certbot.

`guacamole_install_ssl.sh` turns a fresh Debian or Ubuntu server into a browser-accessible remote desktop:

- Guacamole runs in Docker, with a MySQL database and the `guacd` proxy daemon.
- nginx sits in front of Guacamole and serves it over HTTPS with a free Let's Encrypt certificate.
- A TigerVNC + XFCE4 desktop runs on the host, and a Guacamole connection to it is created for you.
- A ufw firewall allows only SSH, HTTP and HTTPS from the internet.

Once it finishes, open `https://your-domain/` in any browser, log in, and click the desktop connection.

## Architecture

```
Browser ──HTTPS──▶ nginx ──▶ guacamole ──▶ guacd ──VNC──▶ host desktop (TigerVNC :1, XFCE4)
                     │           │
               Let's Encrypt   MySQL
```

nginx, guacamole, guacd and MySQL are Docker containers on a private network (`172.29.0.0/24`). The VNC server runs on the host and only accepts connections from that network.

## Requirements

- A Debian 12 or Ubuntu 22.04+ server with systemd
- Root access (`sudo`)
- A domain name with an **A record pointing to the server's public IP**
- Ports **80** and **443** reachable from the internet (also check your cloud provider's firewall or security group)
- An existing **non-root** Linux user to own the VNC desktop session
- About 2 GB of RAM and a few GB of disk for the desktop packages and containers

## Usage

```bash
git clone <this-repo-url> AutoGuacamole
cd AutoGuacamole
sudo ./guacamole_install_ssl.sh
```

The script asks for everything at the start:

| Prompt | Notes |
| --- | --- |
| Clean run? | `y` stops the stack and **deletes the existing Guacamole database**, config files and VNC service. Use it to start over. |
| Domain name | For example, `remote.example.com`. It must already resolve to this server. |
| Let's Encrypt email | Used for certificate expiry notices. |
| VNC username | An existing non-root user whose desktop will be shared. |
| VNC password | 6–8 characters, because VNC only uses the first 8. |
| Guacamole admin password | Replaces the default `guacadmin` password. At least 8 characters. |

After that it runs unattended and prints the URL when it's done.

## What the script does

1. Installs Docker and Docker Compose (it skips Docker if it's already installed), ufw, XFCE4 and TigerVNC.
2. Configures ufw: denies incoming traffic by default, allows SSH on whatever port `sshd` uses, and allows 80/443. VNC port 5901 is allowed only from the Guacamole Docker subnet. Existing ufw rules are kept.
3. Checks that the domain resolves, and warns if it points somewhere other than this server.
4. Generates random MySQL passwords and stores them in `/opt/guacamole/.env`, readable only by root.
5. Generates the Guacamole database schema and an init script that sets your admin password and creates the VNC connection.
6. Starts nginx with an HTTP-only config, gets a certificate from Let's Encrypt, then switches nginx to HTTPS.
7. Starts the full Docker stack.
8. Installs a daily certificate renewal job.
9. Configures the VNC password and an XFCE startup script for your user, and runs VNC display `:1` as a systemd service.

## Files and services

| Path | Purpose |
| --- | --- |
| `/opt/guacamole/docker-compose.yml` | Docker stack definition |
| `/opt/guacamole/.env` | Generated database passwords (keep this safe) |
| `/opt/guacamole/nginx.conf` | nginx reverse proxy config |
| `/opt/guacamole/init/` | Database init SQL, used only when the database is first created |
| `/opt/guacamole/certbot/conf/` | Let's Encrypt certificates |
| `/etc/cron.d/guacamole-certbot` | Daily certificate renewal (03:17) |
| `/etc/systemd/system/vncserver@:1.service` | VNC desktop service |
| `~<user>/.vnc/` | VNC password and `xstartup` |

## Day-to-day management

```bash
cd /opt/guacamole

docker compose ps                  # container status (or docker-compose on older systems)
docker compose logs -f guacamole   # follow Guacamole logs
docker compose restart             # restart the stack

systemctl status 'vncserver@:1'    # VNC desktop status
systemctl restart 'vncserver@:1'   # restart the desktop session
```

To test certificate renewal without changing anything:

```bash
docker run --rm \
  -v /opt/guacamole/certbot/www:/var/www/certbot \
  -v /opt/guacamole/certbot/conf:/etc/letsencrypt \
  certbot/certbot renew --dry-run
```

## Re-running the script

- **Without a clean run**, the existing database and `.env` secrets are kept. The admin password and VNC connection are **not** changed, because they're only applied when the database is first created. Change them in the Guacamole web interface instead (Settings → Users / Connections).
- **With a clean run**, everything is removed and rebuilt from scratch, including all Guacamole users and connections.

## Configuration

These variables at the top of the script can be changed before you run it:

| Variable | Default | Description |
| --- | --- | --- |
| `GUAC_VERSION` | `1.5.5` | Guacamole and guacd image version |
| `VNC_DISPLAY` / `VNC_PORT` | `:1` / `5901` | VNC display and matching port |
| `VNC_GEOMETRY` | `1920x1080` | Desktop resolution |
| `DOCKER_DIR` | `/opt/guacamole` | Install directory |
| `GUAC_SUBNET` | `172.29.0.0/24` | Docker network subnet. Change it if it clashes with your LAN. |

## Troubleshooting

- **The certificate request fails:** check that `dig +short your-domain` returns this server's IP, and that port 80 is open in any external firewall. Let's Encrypt rate-limits repeated failures, so wait before retrying.
- **The login page appears but login fails:** the database may still be initialising on first start. Give it a minute, then check `docker compose logs mysql`.
- **The desktop connection shows a black screen or disconnects:** check `journalctl -u 'vncserver@:1'` and `~<user>/.vnc/*.log`.
- **Ports 80/443 are already in use:** stop any other web server, or an older `~/docker` stack from a previous version of this script.

## Security notes

- Only SSH, 80 and 443 are open to the internet. Guacamole (8080), MySQL and VNC aren't exposed.
- Docker-published ports bypass ufw. That's why only nginx publishes ports.
- Consider adding TOTP two-factor authentication to Guacamole (the `guacamole-auth-totp` extension) and restricting SSH to key-based logins.

## License

See [LICENSE](LICENSE).
