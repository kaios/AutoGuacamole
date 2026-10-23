#!/bin/bash
#
# Installs Apache Guacamole (Docker) behind nginx with a Let's Encrypt
# certificate, plus a TigerVNC + XFCE4 desktop on the host that Guacamole
# connects to. Tested target: Debian 12 / Ubuntu 22.04+ with systemd.
#
set -euo pipefail

# --- CONFIGURATION ---

GUAC_VERSION="1.5.5"
VNC_DISPLAY=":1"
VNC_PORT="5901"
VNC_GEOMETRY="1920x1080"
SYSTEMD_SERVICE_NAME="vncserver@$VNC_DISPLAY"
DOCKER_DIR="/opt/guacamole"
COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"
ENV_FILE="$DOCKER_DIR/.env"
NGINX_CONF_HOST="$DOCKER_DIR/nginx.conf"
INIT_DIR="$DOCKER_DIR/init"
VNC_SERVICE_FILE="/etc/systemd/system/${SYSTEMD_SERVICE_NAME}.service"
RENEW_CRON_FILE="/etc/cron.d/guacamole-certbot"
# Fixed subnet for the compose network, so the firewall can let guacd reach
# the host's VNC server without exposing VNC to the internet.
GUAC_SUBNET="172.29.0.0/24"
MYSQL_UID="999" # uid of the mysql user inside the mysql:8.0 image

export DEBIAN_FRONTEND=noninteractive

COMPOSE=()

# --- FUNCTIONS ---

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[ERROR] This script must be run as root (try: sudo $0)."
        exit 1
    fi
}

detect_compose() {
    if docker compose version &>/dev/null; then
        COMPOSE=(docker compose)
    elif command -v docker-compose &>/dev/null; then
        COMPOSE=(docker-compose)
    else
        COMPOSE=()
    fi
}

compose() {
    (cd "$DOCKER_DIR" && "${COMPOSE[@]}" "$@")
}

# Escape a string for use inside a single-quoted MySQL literal.
sql_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\'/\'\'}
    printf '%s' "$s"
}

cleanup_docker() {
    echo "[*] Cleaning up Docker containers and volumes..."
    detect_compose
    if [[ -f "$COMPOSE_FILE" && ${#COMPOSE[@]} -gt 0 ]]; then
        # -v removes the MySQL volume so the database is re-initialised.
        compose down -v || true
    else
        echo "[*] No existing stack found, skipping docker compose down."
    fi
}

cleanup_files() {
    echo "[*] Removing config files if they exist..."
    # nginx.conf can end up as a directory if Docker created the mount first
    rm -rf "$NGINX_CONF_HOST"
    rm -rf "$INIT_DIR"
    rm -f "$COMPOSE_FILE" "$ENV_FILE" "$RENEW_CRON_FILE"
    if [[ -f "$VNC_SERVICE_FILE" ]]; then
        systemctl disable --now "$SYSTEMD_SERVICE_NAME" 2>/dev/null || true
        rm -f "$VNC_SERVICE_FILE"
        systemctl daemon-reload
    fi
}

ask_clean_run() {
    read -rp "Do you want a clean run? This deletes the existing Guacamole database. (y/n): " clean_run
    if [[ "$clean_run" =~ ^[Yy]$ ]]; then
        echo "[*] Performing clean run..."
        if command -v docker &>/dev/null; then
            cleanup_docker
        fi
        cleanup_files
    else
        echo "[*] Continuing without clean run..."
    fi
}

check_user_exists() {
    local user="$1"
    if [[ "$user" == "root" ]]; then
        echo "[ERROR] Do not run the VNC desktop as root. Use a regular user."
        exit 1
    fi
    if ! id -u "$user" &>/dev/null; then
        echo "[ERROR] User '$user' not found. Exiting."
        exit 1
    fi
    VNC_HOME=$(getent passwd "$user" | cut -d: -f6)
    if [[ -z "$VNC_HOME" || ! -d "$VNC_HOME" ]]; then
        echo "[ERROR] Home directory for '$user' is missing. Exiting."
        exit 1
    fi
}

read_password() {
    # Usage: read_password <prompt> <min_len> <max_len>; result in $REPLY_PASS
    local prompt="$1" min="$2" max="$3" p1 p2
    while true; do
        read -rsp "$prompt: " p1
        echo
        if (( ${#p1} < min || ${#p1} > max )); then
            echo "Password must be between $min and $max characters."
            continue
        fi
        read -rsp "Confirm password: " p2
        echo
        if [[ "$p1" == "$p2" ]]; then
            REPLY_PASS="$p1"
            return
        fi
        echo "Passwords do not match, try again."
    done
}

collect_input() {
    read -rp "Enter the domain name to use with Let's Encrypt: " DOMAIN
    [[ -n "$DOMAIN" ]] || { echo "[ERROR] Domain is required."; exit 1; }

    read -rp "Enter the email address for Let's Encrypt notices: " LE_EMAIL
    [[ "$LE_EMAIL" == *@*.* ]] || { echo "[ERROR] A valid email is required."; exit 1; }

    read -rp "Enter username for VNC session: " VNC_USER
    check_user_exists "$VNC_USER"

    # VNC authentication only uses the first 8 characters of a password.
    read_password "Enter password for VNC session (6-8 chars)" 6 8
    VNC_PASS="$REPLY_PASS"

    read_password "Enter a new password for the Guacamole 'guacadmin' user" 8 128
    GUAC_ADMIN_PASS="$REPLY_PASS"
}

install_packages() {
    echo "[*] Installing required packages..."
    apt-get update
    apt-get install -y ufw dnsutils curl ca-certificates openssl \
        xfce4 xfce4-goodies dbus-x11 \
        tigervnc-standalone-server tigervnc-common
    # Newer Ubuntu releases ship vncpasswd in a separate package.
    if apt-cache show tigervnc-tools &>/dev/null; then
        apt-get install -y tigervnc-tools
    fi

    # Skip docker.io if Docker (e.g. docker-ce) is already installed.
    if ! command -v docker &>/dev/null; then
        apt-get install -y docker.io
    fi
    systemctl enable --now docker

    detect_compose
    if [[ ${#COMPOSE[@]} -eq 0 ]]; then
        apt-get install -y docker-compose-v2 || apt-get install -y docker-compose
        detect_compose
    fi
    if [[ ${#COMPOSE[@]} -eq 0 ]]; then
        echo "[ERROR] Could not install Docker Compose."
        exit 1
    fi
}

setup_firewall() {
    echo "[*] Configuring firewall..."
    local ssh_port
    ssh_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    ssh_port=${ssh_port:-22}

    ufw default deny incoming
    ufw default allow outgoing

    # Always allow SSH (on whatever port sshd actually uses)
    ufw allow "$ssh_port/tcp"

    # HTTP stays open for Let's Encrypt renewals and the HTTPS redirect.
    ufw allow 80/tcp
    ufw allow 443/tcp

    # Let the guacd container reach the host VNC server; block everyone else.
    ufw allow from "$GUAC_SUBNET" to any port "$VNC_PORT" proto tcp

    ufw --force enable
    echo "[*] Firewall configured (SSH on port $ssh_port)."
}

check_dns_propagation() {
    local domain="$1"
    echo "[*] Checking DNS propagation for $domain..."
    local ip public_ip
    ip=$(dig +short A "$domain" | grep -E '^[0-9.]+$' | tail -n1 || true)
    if [[ -z "$ip" ]]; then
        echo "[ERROR] DNS for $domain has not propagated or no A record found."
        exit 1
    fi
    echo "[+] DNS resolved successfully: $ip"

    public_ip=$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)
    if [[ -n "$public_ip" && "$public_ip" != "$ip" ]]; then
        echo "[WARN] $domain points to $ip but this server's public IP is $public_ip."
        read -rp "Continue anyway? (y/n): " cont
        [[ "$cont" =~ ^[Yy]$ ]] || exit 1
    fi
}

write_env_file() {
    mkdir -p "$DOCKER_DIR"
    # Reuse existing secrets so a non-clean re-run still matches the database.
    if [[ -f "$ENV_FILE" ]]; then
        echo "[*] Reusing existing secrets from $ENV_FILE"
        return
    fi
    echo "[*] Generating database passwords..."
    cat > "$ENV_FILE" <<EOF
COMPOSE_PROJECT_NAME=guacamole
GUAC_VERSION=$GUAC_VERSION
GUAC_SUBNET=$GUAC_SUBNET
MYSQL_PASSWORD=$(openssl rand -hex 24)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)
EOF
    chmod 600 "$ENV_FILE"
}

write_db_init() {
    echo "[*] Preparing Guacamole database schema..."
    mkdir -p "$INIT_DIR"
    docker run --rm "guacamole/guacamole:$GUAC_VERSION" \
        /opt/guacamole/bin/initdb.sh --mysql > "$INIT_DIR/01-initdb.sql"

    local admin_pw vnc_pw
    admin_pw=$(sql_escape "$GUAC_ADMIN_PASS")
    vnc_pw=$(sql_escape "$VNC_PASS")

    # Replace the default guacadmin/guacadmin password and pre-create a
    # connection to the host's VNC desktop.
    cat > "$INIT_DIR/02-setup.sql" <<EOF
SET @salt = UNHEX(SHA2(UUID(), 256));
UPDATE guacamole_user
   SET password_salt = @salt,
       password_hash = UNHEX(SHA2(CONCAT('$admin_pw', HEX(@salt)), 256)),
       password_date = NOW()
 WHERE entity_id = (SELECT entity_id FROM guacamole_entity
                     WHERE name = 'guacadmin' AND type = 'USER');

INSERT INTO guacamole_connection (connection_name, protocol)
VALUES ('XFCE Desktop ($VNC_USER)', 'vnc');
SET @conn_id = LAST_INSERT_ID();

INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
VALUES (@conn_id, 'hostname', 'host.docker.internal'),
       (@conn_id, 'port', '$VNC_PORT'),
       (@conn_id, 'password', '$vnc_pw');

INSERT INTO guacamole_connection_permission (entity_id, connection_id, permission)
SELECT entity_id, @conn_id, 'READ' FROM guacamole_entity
 WHERE name = 'guacadmin' AND type = 'USER';
EOF
    chmod 644 "$INIT_DIR/01-initdb.sql"
    # Contains passwords: readable only by the mysql user inside the container.
    chown "$MYSQL_UID:$MYSQL_UID" "$INIT_DIR/02-setup.sql"
    chmod 600 "$INIT_DIR/02-setup.sql"
}

write_docker_compose() {
    echo "[*] Writing docker-compose.yml..."
    mkdir -p "$DOCKER_DIR"
    cat > "$COMPOSE_FILE" <<'EOF'
services:
  guacamole:
    image: guacamole/guacamole:${GUAC_VERSION}
    restart: always
    depends_on:
      - guacd
      - mysql
    environment:
      GUACD_HOSTNAME: guacd
      MYSQL_HOSTNAME: mysql
      MYSQL_PORT: 3306
      MYSQL_DATABASE: guacamole_db
      MYSQL_USER: guacamole_user
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      # Serve Guacamole at / instead of /guacamole/
      WEBAPP_CONTEXT: ROOT

  guacd:
    image: guacamole/guacd:${GUAC_VERSION}
    restart: always
    extra_hosts:
      - "host.docker.internal:host-gateway"

  mysql:
    image: mysql:8.0
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: guacamole_db
      MYSQL_USER: guacamole_user
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - mysql_data:/var/lib/mysql
      - ./init:/docker-entrypoint-initdb.d:ro

  nginx:
    image: nginx:alpine
    container_name: guac-nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certbot/www:/var/www/certbot:ro
      - ./certbot/conf:/etc/letsencrypt:ro

networks:
  default:
    ipam:
      config:
        - subnet: ${GUAC_SUBNET}

volumes:
  mysql_data:
EOF
}

# HTTP-only config used while the certificate does not exist yet; nginx
# refuses to start if the ssl_certificate files are missing.
write_nginx_conf_http() {
    echo "[*] Writing bootstrap nginx.conf (HTTP only)..."
    mkdir -p "$DOCKER_DIR/certbot/www" "$DOCKER_DIR/certbot/conf"
    rm -rf "$NGINX_CONF_HOST"
    cat > "$NGINX_CONF_HOST" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 404;
    }
}
EOF
}

write_nginx_conf_https() {
    echo "[*] Writing final nginx.conf (HTTPS)..."
    cat > "$NGINX_CONF_HOST" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    add_header Strict-Transport-Security "max-age=31536000" always;
    client_max_body_size 100m;

    location / {
        proxy_pass http://guacamole:8080/;
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_set_header Host \$host;
        access_log off;
    }
}
EOF
}

certbot_run() {
    docker run --rm \
        -v "$DOCKER_DIR/certbot/www:/var/www/certbot" \
        -v "$DOCKER_DIR/certbot/conf:/etc/letsencrypt" \
        certbot/certbot "$@"
}

request_letsencrypt_cert() {
    local domain="$1"

    echo "[*] Starting nginx for Let's Encrypt validation..."
    compose up -d nginx

    echo "[*] Requesting Let's Encrypt SSL certificate for $domain..."
    if ! certbot_run certonly --webroot -w /var/www/certbot -d "$domain" \
        --non-interactive --agree-tos --keep-until-expiring --email "$LE_EMAIL"; then
        echo "[ERROR] Let's Encrypt certificate request failed."
        echo "        Check that $domain points to this server and port 80 is reachable."
        compose down || true
        exit 1
    fi

    echo "[*] SSL certificate successfully obtained."
}

setup_cert_renewal() {
    echo "[*] Installing daily certificate renewal job..."
    cat > "$RENEW_CRON_FILE" <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root docker run --rm -v $DOCKER_DIR/certbot/www:/var/www/certbot -v $DOCKER_DIR/certbot/conf:/etc/letsencrypt certbot/certbot renew --quiet && docker exec guac-nginx nginx -s reload >/dev/null 2>&1
EOF
    chmod 644 "$RENEW_CRON_FILE"
}

setup_vnc() {
    echo "[*] Configuring VNC server and XFCE4 for user $VNC_USER..."

    # Password goes over stdin so it never appears in the process list.
    printf '%s\n' "$VNC_PASS" | su - "$VNC_USER" -c \
        'mkdir -p ~/.vnc && vncpasswd -f > ~/.vnc/passwd && chmod 600 ~/.vnc/passwd'

    cat > "$VNC_HOME/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources"
exec dbus-launch --exit-with-session startxfce4
EOF
    chown "$VNC_USER":"$VNC_USER" "$VNC_HOME/.vnc/xstartup"
    chmod +x "$VNC_HOME/.vnc/xstartup"

    # VNC listens on all interfaces so the guacd container can reach it;
    # the firewall only allows the Guacamole Docker subnet.
    cat > "$VNC_SERVICE_FILE" <<EOF
[Unit]
Description=VNC Server for user $VNC_USER on display $VNC_DISPLAY
After=network.target

[Service]
Type=simple
User=$VNC_USER
WorkingDirectory=$VNC_HOME
ExecStartPre=-/usr/bin/vncserver -kill $VNC_DISPLAY
ExecStart=/usr/bin/vncserver $VNC_DISPLAY -fg -localhost no -geometry $VNC_GEOMETRY -depth 24
ExecStop=/usr/bin/vncserver -kill $VNC_DISPLAY
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SYSTEMD_SERVICE_NAME"
    systemctl restart "$SYSTEMD_SERVICE_NAME"
}

# --- MAIN SCRIPT ---

echo "Starting Guacamole + SSL + VNC setup script."

require_root

ask_clean_run

collect_input

install_packages

setup_firewall

check_dns_propagation "$DOMAIN"

write_env_file

write_docker_compose

write_db_init

write_nginx_conf_http

request_letsencrypt_cert "$DOMAIN"

write_nginx_conf_https

echo "[*] Starting Guacamole Docker stack..."
compose up -d
compose restart nginx

setup_cert_renewal

setup_vnc

echo
echo "[*] Setup complete."
echo "    URL:      https://$DOMAIN/"
echo "    Login:    guacadmin / (the password you entered)"
echo "    Desktop:  'XFCE Desktop ($VNC_USER)' connection is pre-configured."
echo "    Secrets:  $ENV_FILE"
echo "    Note: the admin password and VNC connection are only applied when the"
echo "    database is first created. Use a clean run to reset them."
