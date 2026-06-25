#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2.0"
STEP=0
RED='\033[0;31m'; GRN='\033[0;32m'; CYN='\033[0;36m'; YLW='\033[0;33m'; RST='\033[0m'
msg()  { echo -e "\n[${CYN}$((++STEP))/$TOTAL${RST}] $*"; }
ok()   { echo -e "  ${GRN}✓${RST} $*"; }
info() { echo -e "  ${CYN}→${RST} $*"; }
warn() { echo -e "  ${YLW}⚠${RST} $*"; }
err()  { echo -e "  ${RED}✗${RST} $*"; }
TOTAL=11

echo "╔══════════════════════════════════════════════════╗"
echo "║   Secrets Vault v${SCRIPT_VERSION}                         ║"
echo "╚══════════════════════════════════════════════════╝"

# repo root
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info "Repo: $REPO_DIR"

# user
if [ -n "${SUDO_USER:-}" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
else
    err "Run with sudo: sudo ./setup-secrets.sh"
    exit 1
fi
info "User: $REAL_USER  ($REAL_HOME)"

# 1. Packages
msg "Installing packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq oathtool pass pass-otp qrencode python3 openssl 2>/dev/null || true
for cmd in oathtool pass gpg python3 openssl; do
    command -v "$cmd" &>/dev/null || { err "$cmd not found"; apt-get install -y -qq "$cmd" 2>/dev/null || true; }
done
command -v python3 &>/dev/null || { err "python3 required"; exit 1; }
ok "Packages installed"

# 2. Generate TOTP secret
msg "Generating TOTP secret..."
mkdir -p /root/.secrets-otp
python3 -c "import os,base64; print(base64.b32encode(os.urandom(20)).decode().rstrip('='), end='')" > /root/.secrets-otp/totp-secret
chmod 600 /root/.secrets-otp/totp-secret
chown root:root /root/.secrets-otp/totp-secret
ok "/root/.secrets-otp/totp-secret"

# 3. Sudoers
msg "Creating sudoers..."
cat > /etc/sudoers.d/secrets-otp << 'SUDO'
# Secrets Vault — passwordless access for OTP tools
# Only scripts that read /root/.secrets-otp/totp-secret internally
ALL ALL=(root) NOPASSWD: /usr/local/bin/secrets-otp *
ALL ALL=(root) NOPASSWD: /usr/local/bin/secrets-verify *
ALL ALL=(root) NOPASSWD: /usr/local/bin/secrets-bash-executor *
ALL ALL=(root) NOPASSWD: /usr/local/bin/secrets-encrypted-op *
# NEVER add /bin/cat here — agent would read the TOTP secret
# User reads the key via: sudo cat /root/.secrets-otp/totp-secret (with password)
SUDO
chmod 440 /etc/sudoers.d/secrets-otp
ok "/etc/sudoers.d/secrets-otp"

# 4. Install scripts
msg "Installing scripts..."
for f in secrets-otp secrets-verify secret-exec secrets-encrypted-op; do
    if [ -f "$REPO_DIR/$f" ]; then
        cp "$REPO_DIR/$f" "/usr/local/bin/$f"
        chmod 755 "/usr/local/bin/$f"
        ok "/usr/local/bin/$f"
    else
        warn "$f not found in repo"
    fi
done

# secrets-bash-executor (bash wrapper + Python core)
for f in secrets-bash-executor .secrets-bash-executor-core.py; do
    if [ -f "$REPO_DIR/$f" ]; then
        cp "$REPO_DIR/$f" "/usr/local/bin/$f"
        chmod 755 "/usr/local/bin/$f"
        ok "/usr/local/bin/$f"
    else
        warn "$f not found in repo"
    fi
done
if [ -f "$REPO_DIR/secrets-uri" ]; then
    cp "$REPO_DIR/secrets-uri" /usr/local/bin/secrets-uri
    chmod 700 /usr/local/bin/secrets-uri
    chown root:root /usr/local/bin/secrets-uri
    ok "/usr/local/bin/secrets-uri"
fi
mkdir -p /usr/local/share/secrets-vault
if [ -f "$REPO_DIR/secrets-vault-app.html" ]; then
    cp "$REPO_DIR/secrets-vault-app.html" /usr/local/share/secrets-vault/index.html
    chmod 644 /usr/local/share/secrets-vault/index.html
    ok "/usr/local/share/secrets-vault/index.html"
fi

# 5. Provisioning info
msg "Provisioning QR..."
python3 -c 'import base64; k=open("/root/.secrets-otp/totp-secret").read().strip(); print("otpauth://totp/Secrets-Vault?secret="+k+"&issuer=MyClaw")' > /tmp/sv-uri.txt
URI=`cat /tmp/sv-uri.txt`
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  📱  ADD TO PHONE AUTHENTICATOR                       │"
echo "  │                                                        │"
echo "  │  URI: $URI"
echo "  │                                                        │"
if command -v qrencode &>/dev/null; then
    echo "$URI" | qrencode -t UTF8 2>/dev/null | while IFS= read -r line; do
        printf "  │  %-55s  │\n" "$line"
    done
fi
echo "  │                                                        │"
echo "  │  Also copy vault-app.html to phone:                    │"
echo "  │  $REPO_DIR/secrets-vault-app.html    │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""

# 6. GPG key
msg "Setting up GPG..."
if su - "$REAL_USER" -c "gpg --list-secret-keys --keyid-format=long 2>/dev/null | grep -q ^sec"; then
    KEY_ID=`su - "$REAL_USER" -c "gpg --list-secret-keys --keyid-format=long 2>/dev/null | grep ^sec | head -1 | sed 's/.*\\///;s/ .*//'"`
    ok "Existing GPG key: $KEY_ID"
else
    warn "Generating Ed25519 GPG key..."
    sudo -u "$REAL_USER" gpg --batch --passphrase '' --quick-gen-key \
        "Secrets Vault <vault@`hostname`.local>" ed25519 sign 0 2>&1
    KEY_ID=`su - "$REAL_USER" -c "gpg --list-secret-keys --keyid-format=long 2>/dev/null | grep ^sec | head -1 | sed 's/.*\\///;s/ .*//'"`
    ok "GPG key: $KEY_ID"
fi

# 7. Pass store
msg "Initializing pass..."
if [ -f "$REAL_HOME/.password-store/.gpg-id" ]; then
    ok "pass already initialized"
else
    sudo -u "$REAL_USER" pass init "$KEY_ID" 2>&1
    ok "pass initialized"
fi

# 8. GPG agent — no caching (each secret operation asks passphrase)
msg "Hardening GPG agent..."
mkdir -p "$REAL_HOME/.gnupg"
chmod 700 "$REAL_HOME/.gnupg"
GPG_CONF="$REAL_HOME/.gnupg/gpg-agent.conf"
if grep -q '^default-cache-ttl' "$GPG_CONF" 2>/dev/null; then
    sed -i 's/^default-cache-ttl.*/default-cache-ttl 0/' "$GPG_CONF"
else
    echo 'default-cache-ttl 0' >> "$GPG_CONF"
fi
# Also disable ssh-agent-like passphrase caching
if grep -q '^max-cache-ttl' "$GPG_CONF" 2>/dev/null; then
    sed -i 's/^max-cache-ttl.*/max-cache-ttl 0/' "$GPG_CONF"
else
    echo 'max-cache-ttl 0' >> "$GPG_CONF"
fi
chown -R "$REAL_USER:" "$REAL_HOME/.gnupg"
sudo -u "$REAL_USER" gpgconf --reload gpg-agent 2>/dev/null || true
ok "GPG agent: default-cache-ttl = 0 (пароль спрашивается каждый раз)"

# 9. Bash aliases
msg "Adding aliases..."
BASHRC="$REAL_HOME/.bashrc"
if [ -f "$BASHRC" ] && ! grep -q 'secrets-otp' "$BASHRC" 2>/dev/null; then
    cat >> "$BASHRC" << 'BASHRC'

# --- Secrets Vault ---
alias otp='sudo secrets-otp'
alias otp-cmd='sudo secrets-otp'
alias pass-list='pass show'
BASHRC
    chown "$REAL_USER:" "$BASHRC" 2>/dev/null || true
    ok "Aliases added"
else
    ok "Aliases already present"
fi

# 10. Setup info
msg "Saving setup info..."
cat > /root/.secrets-otp/setup-info.txt << META
Secrets Vault Setup v${SCRIPT_VERSION}
Date:       `date -u +%Y-%m-%dT%H:%M:%SZ`
Host:       `hostname`
User:       ${REAL_USER}
Home:       ${REAL_HOME}
GPG Key:    ${KEY_ID:-N/A}
TOTP File:  /root/.secrets-otp/totp-secret
Repo:       ${REPO_DIR}
META
chmod 600 /root/.secrets-otp/setup-info.txt
ok "Setup info saved"

# 11. Smoke test
msg "Smoke test..."
echo -n "  TOTP:            "; sudo -n secrets-otp 2>&1 || echo "FAIL"
echo -n "  TEST_KEY:        "; sudo -n secrets-otp "TEST_KEY" 2>&1 || echo "FAIL"
C=`sudo -n secrets-otp "TEST_KEY" 2>/dev/null`
echo -n "  verify correct:  "; sudo -n secrets-verify "TEST_KEY" "$C" 2>&1 || echo "FAIL"
echo -n "  verify wrong:    "; sudo -n secrets-verify "TEST_KEY" "000000" 2>&1 || echo "FAIL"
echo ""
ok "All checks done"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ✅  SETUP COMPLETE                            ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  📱  PHONE:  Scan QR + copy vault-app.html"
echo "  🔑  ADD:    pass insert <name>"
echo "  🔄  RE-RUN: sudo $0"
echo ""
