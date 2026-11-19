
#!/usr/bin/env bash

set -euo pipefail

# ==================================================
# Git SSH Setup - Per Repository
# Platform: GitHub
# ==================================================

# Check Git repository
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: Jalankan script dari dalam folder Git repository."
    exit 1
fi

# Repository information
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$REPO_ROOT")
REPO_NAME=${REPO_NAME%.git}

REMOTE_URL=$(git remote get-url origin)

if [[ -z "$REMOTE_URL" ]]; then
    echo "ERROR: Remote origin tidak ditemukan."
    exit 1
fi

# Generate safe key name
KEY_NAME=$(echo "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-')
KEY_NAME=${KEY_NAME%-}

# SSH configuration
SSH_DIR="$HOME/.ssh"
KEY_FILE="$SSH_DIR/id_ed25519_$KEY_NAME"
CONFIG_FILE="$SSH_DIR/config"
SSH_ALIAS="github-$KEY_NAME"

# ==================================================
# Detect GitHub remote
# ==================================================

if [[ "$REMOTE_URL" =~ ^https?://([^/]+)/(.+)$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    REPO_PATH="${BASH_REMATCH[2]}"
elif [[ "$REMOTE_URL" =~ ^git@([^:]+):(.+)$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    REPO_PATH="${BASH_REMATCH[2]}"
elif [[ "$REMOTE_URL" =~ ^ssh://git@([^/]+)/(.+)$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    REPO_PATH="${BASH_REMATCH[2]}"
else
    echo "ERROR: Format remote URL tidak didukung:"
    echo "$REMOTE_URL"
    exit 1
fi

if [[ "$HOST" != "github.com" ]]; then
    echo "ERROR: Script ini khusus untuk GitHub."
    echo "Detected host: $HOST"
    exit 1
fi

REPO_PATH="${REPO_PATH%.git}"
REPO_PATH="${REPO_PATH#/}"
REPO_PATH="$REPO_PATH.git"

GITHUB_REPO="https://github.com/${REPO_PATH%.git}/settings/keys"

# ==================================================
# Create SSH directory
# ==================================================

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

echo
echo "=================================================="
echo "             GIT SSH CONFIGURATION"
echo "=================================================="
echo
echo "Repository : $REPO_NAME"
echo "Remote     : $REMOTE_URL"
echo "GitHub     : https://github.com/${REPO_PATH%.git}"
echo "SSH Alias  : $SSH_ALIAS"
echo

# ==================================================
# Generate SSH Key
# ==================================================

if [[ ! -f "$KEY_FILE" ]]; then

    echo "[1/4] Generating SSH Key..."

    ssh-keygen \
        -t ed25519 \
        -C "$REPO_NAME" \
        -f "$KEY_FILE" \
        -N ""

    echo "SSH Key generated successfully."

else

    echo "[1/4] SSH Key already exists."
    echo "Using existing key: $KEY_FILE"

fi

chmod 600 "$KEY_FILE"
chmod 644 "$KEY_FILE.pub"

# ==================================================
# Configure SSH Config
# ==================================================

echo
echo "[2/4] Configuring SSH..."

if ! grep -qFx "Host $SSH_ALIAS" "$CONFIG_FILE"; then

    cat >> "$CONFIG_FILE" <<EOF

Host $SSH_ALIAS
    HostName github.com
    User git
    IdentityFile $KEY_FILE
    IdentitiesOnly yes
EOF

    echo "SSH configuration added."

else

    echo "SSH configuration already exists."

fi

# ==================================================
# Update Git Remote
# ==================================================

echo
echo "[3/4] Updating Git Remote..."

SSH_REMOTE="$SSH_ALIAS:$REPO_PATH"

git remote set-url origin "$SSH_REMOTE"

echo "Remote updated successfully."

# ==================================================
# Display GitHub Instructions
# ==================================================

PUBLIC_KEY=$(cat "$KEY_FILE.pub")

echo
echo
echo "=================================================="
echo "          GITHUB SSH KEY CONFIGURATION"
echo "=================================================="
echo
echo "STEP 1 - Open GitHub Repository Settings"
echo
echo "Open this URL:"
echo
echo "$GITHUB_REPO"
echo
echo "--------------------------------------------------"
echo
echo "STEP 2 - Add Deploy Key"
echo
echo "Click: Add deploy key"
echo
echo "Fill in the following:"
echo
echo "Title:"
echo "VPS - $REPO_NAME"
echo
echo "Key type:"
echo "Authentication Key"
echo
echo "Allow write access:"
echo "ENABLE (Required for Git Push)"
echo
echo "--------------------------------------------------"
echo
echo "STEP 3 - COPY THIS PUBLIC KEY"
echo
echo "Copy the complete key below:"
echo
echo "--------------------------------------------------"
echo "$PUBLIC_KEY"
echo "--------------------------------------------------"
echo
echo "IMPORTANT:"
echo "- Copy the entire line."
echo "- Do not copy the private key."
echo "- Only copy the key displayed above."
echo
echo "STEP 4 - Save Deploy Key"
echo
echo "Click Add key on GitHub."
echo
echo "=================================================="
echo "             AFTER CONFIGURATION"
echo "=================================================="
echo
echo "After adding the key to GitHub, run:"
echo
echo "1. Test SSH connection:"
echo
echo "   ssh -T $SSH_ALIAS"
echo
echo "2. Git Pull:"
echo
echo "   git pull"
echo
echo "3. Git Push:"
echo
echo "   git push"
echo
echo "=================================================="
echo "               CONFIGURATION INFO"
echo "=================================================="
echo
echo "Repository : $REPO_NAME"
echo "GitHub     : https://github.com/${REPO_PATH%.git}"
echo "SSH Alias  : $SSH_ALIAS"
echo "Private Key: $KEY_FILE"
echo "Public Key : $KEY_FILE.pub"
echo
echo "Current Git Remote:"
git remote -v
echo
echo "=================================================="
echo "                  COMPLETED"
echo "=================================================="
