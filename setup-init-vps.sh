
#!/usr/bin/env bash

set -Eeuo pipefail

# ==================================================
# JTECH VPS INITIAL SECURITY SETUP
# Supported: Ubuntu / Debian
# ==================================================

DEFAULT_USER="jtech"
DEFAULT_SSH_PORT="2626"

SSH_CONFIG="/etc/ssh/sshd_config"
SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
BACKUP_DIR="/root/vps-setup-backup"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# ==================================================
# CHECK ROOT
# ==================================================

if [[ "$EUID" -ne 0 ]]; then
    error "Jalankan script menggunakan root atau sudo."
fi

if [[ ! -f /etc/os-release ]]; then
    error "Sistem operasi tidak dikenali."
fi

source /etc/os-release

if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    error "Script hanya mendukung Ubuntu dan Debian."
fi

if ! command -v apt-get >/dev/null 2>&1; then
    error "APT tidak ditemukan."
fi

if ! command -v systemctl >/dev/null 2>&1; then
    error "Systemd tidak ditemukan."
fi

# ==================================================
# USER INPUT
# ==================================================

clear

echo ""
echo -e "${CYAN}==============================================${NC}"
echo -e "${CYAN}       JTECH VPS INITIAL SECURITY SETUP${NC}"
echo -e "${CYAN}==============================================${NC}"
echo ""
echo "Operating System : $PRETTY_NAME"
echo ""

read -r -p "Username baru [$DEFAULT_USER]: " INPUT_USER
NEW_USER="${INPUT_USER:-$DEFAULT_USER}"

read -r -p "SSH Port [$DEFAULT_SSH_PORT]: " INPUT_PORT
SSH_PORT="${INPUT_PORT:-$DEFAULT_SSH_PORT}"

# ==================================================
# VALIDATE INPUT
# ==================================================

if [[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
    error "Format username tidak valid."
fi

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] ||
   (( 10#$SSH_PORT < 1 || 10#$SSH_PORT > 65535 )); then
    error "Port harus berupa angka antara 1 sampai 65535."
fi

SSH_PORT=$((10#$SSH_PORT))

if [[ "$SSH_PORT" -lt 1024 ]]; then
    warn "Port di bawah 1024 memerlukan hak khusus."
fi

echo ""
echo "=============================================="
echo "Konfigurasi VPS"
echo "=============================================="
echo "OS       : $PRETTY_NAME"
echo "Username : $NEW_USER"
echo "SSH Port : $SSH_PORT"
echo "=============================================="
echo ""

read -r -p "Lanjutkan setup? (yes/no): " CONFIRM

[[ "$CONFIRM" == "yes" ]] || exit 0

# ==================================================
# UPDATE SYSTEM
# ==================================================

info "Memperbarui package system..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get upgrade -y

# ==================================================
# INSTALL PACKAGES
# ==================================================

info "Menginstall security packages..."

apt-get install -y \
    sudo \
    ufw \
    fail2ban \
    unattended-upgrades \
    apt-listchanges \
    openssh-server \
    ca-certificates \
    curl

# ==================================================
# BACKUP SSH CONFIGURATION
# ==================================================

if [[ ! -f "$SSH_CONFIG" ]]; then
    error "File konfigurasi SSH tidak ditemukan."
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

mkdir -p "$BACKUP_DIR"

SSH_BACKUP="$BACKUP_DIR/ssh_$TIMESTAMP"

info "Membuat backup konfigurasi SSH..."

mkdir -p "$SSH_BACKUP"

cp -a /etc/ssh/. "$SSH_BACKUP/"

info "Backup tersedia: $SSH_BACKUP"

# ==================================================
# CREATE USER
# ==================================================

info "Memeriksa user $NEW_USER..."

if id "$NEW_USER" >/dev/null 2>&1; then
    warn "User $NEW_USER sudah tersedia."
else
    info "Membuat user $NEW_USER..."

    adduser --disabled-password --gecos "" "$NEW_USER"
fi

info "Memberikan akses sudo..."

usermod -aG sudo "$NEW_USER"

info "Mengatur password user $NEW_USER..."

passwd "$NEW_USER"

# ==================================================
# SSH CONFIGURATION
# ==================================================

info "Mengamankan konfigurasi SSH..."

mkdir -p "$SSH_DROPIN_DIR"

# Hapus konfigurasi JTech lama dan directive
# yang akan dikelola oleh script ini.
# Backup asli sudah tersedia.

SSH_FILES=("$SSH_CONFIG")

for file in "$SSH_DROPIN_DIR"/*.conf; do
    [[ -f "$file" ]] && SSH_FILES+=("$file")
done

for file in "${SSH_FILES[@]}"; do

    TEMP_FILE=$(mktemp)

    # Hapus blok JTech sebelumnya.
    awk '
        /^# BEGIN JTECH VPS HARDENING$/ {
            skip=1
            next
        }

        /^# END JTECH VPS HARDENING$/ {
            skip=0
            next
        }

        !skip {
            print
        }
    ' "$file" > "$TEMP_FILE"

    # Hilangkan directive lama agar tidak terjadi
    # konflik dengan konfigurasi baru.
    sed -E -i \
        '/^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|KbdInteractiveAuthentication|UsePAM|X11Forwarding|MaxAuthTries|LoginGraceTime)[[:space:]]+/Id' \
        "$TEMP_FILE"

    cat "$TEMP_FILE" > "$file"

    rm -f "$TEMP_FILE"

done

# Tambahkan konfigurasi utama di awal file.
# Diletakkan sebelum Include agar nilainya
# tidak tertimpa konfigurasi drop-in.

TEMP_CONFIG=$(mktemp)

cat > "$TEMP_CONFIG" <<EOF
# BEGIN JTECH VPS HARDENING

Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30

# END JTECH VPS HARDENING

EOF

cat "$SSH_CONFIG" >> "$TEMP_CONFIG"

cat "$TEMP_CONFIG" > "$SSH_CONFIG"

rm -f "$TEMP_CONFIG"

# ==================================================
# VALIDATE SSH CONFIGURATION
# ==================================================

info "Memvalidasi konfigurasi SSH..."

if ! sshd -t; then

    warn "Konfigurasi SSH tidak valid."

    info "Memulihkan konfigurasi SSH dari backup..."

    rm -rf /etc/ssh

    mkdir -p /etc/ssh

    cp -a "$SSH_BACKUP/." /etc/ssh/

    error "SSH configuration gagal. Backup telah dipulihkan."

fi

info "Konfigurasi SSH valid."

# ==================================================
# UFW FIREWALL
# ==================================================

info "Mengkonfigurasi UFW Firewall..."

# Izinkan port SSH baru terlebih dahulu.
ufw allow "$SSH_PORT/tcp" comment 'SSH Custom Port'

# Default firewall policy.
ufw default deny incoming
ufw default allow outgoing

# Matikan logging UFW agar tidak memenuhi console.
ufw logging off

# Aktifkan firewall.
ufw --force enable

info "UFW berhasil dikonfigurasi."

# ==================================================
# FAIL2BAN
# ==================================================

info "Mengkonfigurasi Fail2ban..."

mkdir -p /etc/fail2ban/jail.d

cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

# ==================================================
# AUTOMATIC SECURITY UPDATES
# ==================================================

info "Mengaktifkan automatic security updates..."

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# ==================================================
# DISABLE ROOT ACCOUNT
# ==================================================

info "Mengunci akun root..."

passwd -l root

# ==================================================
# SSH SERVICE
# ==================================================

info "Mengaktifkan SSH service..."

# Ubuntu / Debian menggunakan ssh.service.
# Hindari sshd.service yang dapat berupa alias.

if ! systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q 'ssh.service'; then
    warn "ssh.service tidak ditemukan, memeriksa sshd.service..."

    if systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -q 'sshd.service'; then
        SSH_SERVICE="sshd.service"
    else
        error "SSH service tidak ditemukan."
    fi
else
    SSH_SERVICE="ssh.service"
fi

systemctl enable "$SSH_SERVICE"

if ! systemctl restart "$SSH_SERVICE"; then

    warn "SSH gagal direstart. Memulihkan konfigurasi..."

    rm -rf /etc/ssh

    mkdir -p /etc/ssh

    cp -a "$SSH_BACKUP/." /etc/ssh/

    systemctl restart "$SSH_SERVICE" || true

    error "SSH gagal direstart. Konfigurasi lama dipulihkan."

fi

if ! systemctl is-active --quiet "$SSH_SERVICE"; then
    error "SSH service tidak aktif."
fi

info "SSH service berhasil dijalankan."

# ==================================================
# FAIL2BAN SERVICE
# ==================================================

info "Mengaktifkan Fail2ban..."

systemctl enable fail2ban

systemctl restart fail2ban

# ==================================================
# FINAL VERIFICATION
# ==================================================

echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}       VPS SETUP COMPLETED SUCCESSFULLY${NC}"
echo -e "${GREEN}==============================================${NC}"

echo ""
echo "USER INFORMATION"
echo "----------------------------------------------"

id "$NEW_USER"

echo ""
echo "SSH CONFIGURATION"
echo "----------------------------------------------"

sshd -T | grep -E \
    '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication) '

echo ""
echo "SSH SERVICE"
echo "----------------------------------------------"

systemctl status "$SSH_SERVICE" --no-pager -l | head -n 10

echo ""
echo "UFW FIREWALL"
echo "----------------------------------------------"

ufw status verbose

echo ""
echo "FAIL2BAN"
echo "----------------------------------------------"

fail2ban-client status sshd || true

echo ""
echo "BACKUP"
echo "----------------------------------------------"

echo "$SSH_BACKUP"

echo ""
echo -e "${CYAN}==============================================${NC}"
echo "SSH CONNECTION"
echo "=============================================="
echo ""
echo "ssh -p $SSH_PORT $NEW_USER@YOUR_SERVER_IP"
echo ""
echo "PENTING:"
echo "1. Jangan tutup sesi SSH yang sekarang."
echo "2. Pastikan firewall provider membuka port $SSH_PORT."
echo "3. Test login user $NEW_USER dari terminal baru."
echo "4. Pastikan akses sudo berhasil."
echo "5. Daftarkan public key sebelum menonaktifkan password login."
echo ""
echo "UFW logging: OFF"
echo "Root SSH login: DISABLED"
echo "Root account: LOCKED"
echo ""
echo -e "${GREEN}VPS siap digunakan.${NC}"
echo "=============================================="
