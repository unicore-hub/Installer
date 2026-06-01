#!/bin/bash
set -e

echo "===== UNICOREHUB FULL INSTALL START ====="

#############################################
# ROOT CHECK
#############################################
if [ "$EUID" -ne 0 ]; then
  echo "please execute as root (sudo ./script.sh)"
  exit 1
fi

#############################################
# VARIABLES
#############################################
CURRENT_USER="${SUDO_USER:-$USER}"
PROJECT_DIR="/opt/unicorehub/backend"
GIT_DIR="/opt/unicorehub"
GIT_REPO="https://github.com/unicore-hub/INIT_SETUP.git"
PG_VER=$(psql -V | awk '{print $3}' | cut -d. -f1)
PG_HBA="/etc/postgresql/$PG_VER/main/pg_hba.conf"

echo "user: $CURRENT_USER"
echo "base: /opt/unicorehub"

#############################################
# 1. RECOVERY SYSTEM
#############################################
echo "[1/4] installing recovery system..."

tee /usr/local/bin/unicorehub_recovery.sh > /dev/null << 'EOF'
#!/bin/bash
LOGFILE="/var/log/unicorehub_recovery.log"
exec >> "$LOGFILE" 2>&1

echo "=== unicorehub Auto-Recovery ==="
date

if findmnt -n -o OPTIONS / | grep -q ro; then
    echo "WARNING: Root-FS is read-only!"
    touch /forcefsck
    reboot
    exit 1
fi

echo "Recovery check complete"
exit 0
EOF

chmod +x /usr/local/bin/unicorehub_recovery.sh

tee /etc/systemd/system/unicorehub_recovery.service > /dev/null << 'EOF'
[Unit]
Description=unicorehub Auto-Recovery Service
After=local-fs.target
Before=postgresql.service nginx.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/unicorehub_recovery.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable unicorehub_recovery.service

#############################################
# 2. BASE SETUP
#############################################
mkdir -p "$GIT_DIR"
chown -R "$CURRENT_USER":"$CURRENT_USER" "$GIT_DIR"

#############################################
# 3. PACKAGES
#############################################
echo "[3/4] installing packages..."

apt update

apt install -y \
    git python3 python3-venv python3-pip \
    nginx postgresql postgresql-contrib \
    avahi-daemon avahi-utils

#############################################
# GIT CLONE
#############################################
echo "cloning repository..."

if [ ! -d "$PROJECT_DIR" ]; then
    sudo -u "$CURRENT_USER" git clone "$GIT_REPO" "$GIT_DIR"
else
    echo "repository exists -> skipping clone"
fi

#############################################
# POSTGRES
#############################################
systemctl enable postgresql
systemctl restart postgresql

sed -i "s/^local\s\+all\s\+postgres.*/local   all   postgres   peer/" "$PG_HBA"
sed -i "s/^local\s\+all\s\+all.*/local   all   all   peer/" "$PG_HBA"
sed -i "s/^local\s\+replication\s\+all.*/local   replication   all   peer/" "$PG_HBA"

systemctl restart postgresql

sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'UniC0rE_dEf4ulT';"

sed -i "s/^host\s\+all\s\+all\s\+127.0.0.1\/32.*/host all all 127.0.0.1\/32 scram-sha-256/" "$PG_HBA"
sed -i "s/^host\s\+all\s\+all\s\+::1\/128.*/host all all ::1\/128 scram-sha-256/" "$PG_HBA"

systemctl restart postgresql

#############################################
# PYTHON VENV
#############################################
cd /opt/unicorehub
python3 -m venv venv

#############################################
# SYSTEMD APP SERVICE
#############################################
tee /etc/systemd/system/unicorehub.service > /dev/null <<EOF
[Unit]
Description=Unicorehub FastAPI Server
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=root
Group=root
WorkingDirectory=/opt/unicorehub/backend
Environment="PYTHONUNBUFFERED=1"

ExecStartPre=/bin/sh -c 'until pg_isready -q; do sleep 1; done'

ExecStart=/opt/unicorehub/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8877

Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable unicorehub

#############################################
# NGINX
#############################################
rm -f /etc/nginx/sites-enabled/default

tee /etc/nginx/sites-available/unicorehub > /dev/null <<EOF
server {
    listen 80;
    server_name unicorehub.local;

    location / {
        proxy_pass http://127.0.0.1:8877;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    client_max_body_size 50M;
}
EOF

ln -sf /etc/nginx/sites-available/unicorehub /etc/nginx/sites-enabled/unicorehub
systemctl restart nginx

#############################################
# MDNS
#############################################
hostnamectl set-hostname unicorehub

tee /etc/avahi/services/unicorehub.service > /dev/null <<EOF
<?xml version="1.0"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
    <name>unicorehub</name>
    <service>
        <type>_http._tcp</type>
        <port>80</port>
    </service>
</service-group>
EOF

systemctl restart avahi-daemon

#############################################
# WEEKLY UPDATE SYSTEM
#############################################

echo "installing weekly update system..."

tee /etc/systemd/system/unicorehub_weekly_update.service > /dev/null <<EOF
[Unit]
Description=Unicorehub Weekly Repo Update

[Service]
Type=oneshot
User=root
WorkingDirectory=/opt/unicorehub/backend

ExecStart=/opt/unicorehub/venv/bin/python -c "from general_services.repo_operations.update_repos import weekly_repo_update; import asyncio; asyncio.run(weekly_repo_update())"
EOF

tee /etc/systemd/system/unicorehub_weekly_update.timer > /dev/null <<EOF
[Unit]
Description=Run Unicorehub update every Sunday 01:00

[Timer]
OnCalendar=Sun *-*-* 01:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable unicorehub_weekly_update.timer
systemctl start unicorehub_weekly_update.timer

#############################################
# FILE PERMISSIONS
#############################################
chmod -R 755 "$PROJECT_DIR/static"


#############################################
# FIREWALL (UFW)
#############################################

echo "[FIREWALL] configuring UFW..."

apt install -y ufw

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow 22/tcp

# HTTP (Nginx)
ufw allow 80/tcp

# optional später HTTPS
# ufw allow 443/tcp

ufw --force enable

echo "[FIREWALL] active"
ufw status

#############################################
# DONE
#############################################

echo "===== INSTALLATION COMPLETE ====="
echo "http://unicorehub.local"

sleep 2
reboot
