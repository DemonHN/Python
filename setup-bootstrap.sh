#!/usr/bin/env bash
# setup-bootstrap.sh — Idempotent Ubuntu bootstrap for EC2 (safe edition)
# Location: scripts/main-setup/setup-bootstrap.sh
# Usage (recommended): sudo bash setup-bootstrap.sh
# Run this before running firewall-setup.sh

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ------------------------- logging helpers -------------------------
log()       { echo -e "\n[BOOTSTRAP] $*"; }
warn()      { echo -e "\n[WARN] $*" >&2; }
error_exit(){ echo -e "\n[ERROR] $*\n" >&2; exit 1; }

# ------------------------- sanity checks ---------------------------
if ! command -v uname >/dev/null 2>&1; then
  error_exit "This script requires a POSIX environment."
fi

if [[ "$(id -u)" -ne 0 ]]; then
  warn "Run with sudo for best results. Attempting to continue, but some steps may fail."
fi

if command -v lsb_release >/dev/null 2>&1; then
  DISTRO=$(lsb_release -is 2>/dev/null || echo "Unknown")
  if [[ "$DISTRO" != "Ubuntu" ]]; then
    warn "This script is optimized for Ubuntu. Detected: $DISTRO"
  fi
else
  warn "lsb_release not found; skipping distro check."
fi

# ------------------------- ask for repo URL ------------------------
# Allow passing as positional arg or env var; otherwise prompt.
GITHUB_REPO="${1:-${GITHUB_REPO:-}}"
if [[ -z "${GITHUB_REPO}" ]]; then
  echo
  echo "Enter your GitHub repository URL (HTTPS or SSH)."
  echo "Examples:"
  echo "  HTTPS: https://github.com/owner/repo.git"
  echo "  SSH:   git@github.com:owner/repo.git"
  read -rp "Repo URL: " GITHUB_REPO
fi
[[ -n "$GITHUB_REPO" ]] || error_exit "No repository URL provided."

# Normalize target dir (clone into $HOME/<repo-name>)
CURRENT_USER=$(logname 2>/dev/null || echo "$SUDO_USER" || echo "$USER")
HOME_DIR=$(getent passwd "$CURRENT_USER" | cut -d: -f6 2>/dev/null || echo "/home/$CURRENT_USER")
REPO_NAME_RAW="${GITHUB_REPO%.git}"
REPO_NAME=$(basename "$REPO_NAME_RAW")
TARGET_DIR="$HOME_DIR/$REPO_NAME"

# Derive both HTTPS and SSH forms (for fallback)
# Supports:
#   https://github.com/owner/repo(.git)
#   git@github.com:owner/repo(.git)
OWNER_REPO=""
if [[ "$GITHUB_REPO" =~ ^https?://github\.com/([^/]+/[^/]+)(\.git)?$ ]]; then
  OWNER_REPO="${BASH_REMATCH[1]}"
elif [[ "$GITHUB_REPO" =~ ^git@github\.com:([^/]+/[^/]+)(\.git)?$ ]]; then
  OWNER_REPO="${BASH_REMATCH[1]}"
else
  warn "Unrecognized GitHub URL format. Will try to clone as-is."
fi

REPO_HTTPS="${GITHUB_REPO}"
REPO_SSH="${GITHUB_REPO}"
if [[ -n "$OWNER_REPO" ]]; then
  REPO_HTTPS="https://github.com/${OWNER_REPO}.git"
  REPO_SSH="git@github.com:${OWNER_REPO}.git"
fi

# ------------------------- system update --------------------------
log "Updating system packages (apt update/upgrade)…"
apt-get update -y
apt-get upgrade -y

# ------------------------- core packages --------------------------
log "Installing core packages (curl, git, etc.)…"
apt-get install -y \
  ca-certificates curl gnupg lsb-release git unzip zip nano tree net-tools ufw wget \
  qrencode python3 python3-pip htop openssh-client

# ------------------------- docker install -------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker from the official repository…"
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
  log "Docker already installed — skipping."
fi

# Enable & start docker if systemd exists
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now docker || true
fi

# Add login user to docker group (idempotent)
if ! id -nG "$CURRENT_USER" | grep -qw docker; then
  log "Adding '$CURRENT_USER' to the 'docker' group…"
  usermod -aG docker "$CURRENT_USER" || warn "Could not add $CURRENT_USER to docker group."
  echo -e "\n[INFO] Re-login or re-SSH is required for docker group membership to take effect."
fi

# ------------------------- wireguard tools ------------------------
log "Installing WireGuard userland tools…"
apt-get install -y wireguard wireguard-tools

# ------------------------- optional firewall ----------------------
if ufw status | grep -q inactive; then
  log "UFW is inactive. Enabling only SSH for safety."
  ufw allow OpenSSH
  ufw --force enable
else
  log "UFW already active — leaving as-is."
fi

# ------------------------- git clone/update -----------------------
clone_attempt() {
  local url="$1"
  if [[ -d "$TARGET_DIR/.git" ]]; then
    log "Repository already present at $TARGET_DIR — fetching latest from origin."
    git -C "$TARGET_DIR" fetch --all --prune
    return 0
  fi
  log "Cloning repository from: $url"
  git clone "$url" "$TARGET_DIR"
}

ensure_github_ssh_ready() {
  # Prefer ed25519; fallback to RSA if needed
  mkdir -p "$HOME_DIR/.ssh"
  chown -R "$CURRENT_USER":"$CURRENT_USER" "$HOME_DIR/.ssh"
  chmod 700 "$HOME_DIR/.ssh"

  local KEYFILE_ED25519="$HOME_DIR/.ssh/id_ed25519"
  local KEYFILE_RSA="$HOME_DIR/.ssh/id_rsa"
  local PUBKEY=""
  local KEYFILE=""

  if [[ -f "$KEYFILE_ED25519" ]]; then
    KEYFILE="$KEYFILE_ED25519"
  elif [[ -f "$KEYFILE_RSA" ]]; then
    KEYFILE="$KEYFILE_RSA"
  else
    log "Generating a new SSH key (ed25519)…"
    sudo -u "$CURRENT_USER" ssh-keygen -t ed25519 -C "$CURRENT_USER@$(hostname)-$(date +%F)" -f "$KEYFILE_ED25519" -N ""
    KEYFILE="$KEYFILE_ED25519"
  fi

  PUBKEY="${KEYFILE}.pub"
  chmod 600 "$KEYFILE" || true
  chmod 644 "$PUBKEY" || true
  chown "$CURRENT_USER":"$CURRENT_USER" "$KEYFILE" "$PUBKEY" || true

  # Start agent & add key (best effort)
  if command -v ssh-agent >/dev/null 2>&1; then
    eval "$(ssh-agent -s)" >/dev/null 2>&1 || true
    sudo -u "$CURRENT_USER" ssh-add "$KEYFILE" >/dev/null 2>&1 || true
  fi

  echo
  echo "==> Add this SSH public key to GitHub (Settings → SSH and GPG keys):"
  echo "-------------------------------------------------------------------"
  cat "$PUBKEY"
  echo "-------------------------------------------------------------------"
  echo "URL: https://github.com/settings/keys"
  echo

  # Loop until GitHub accepts the key
  while true; do
    echo "Testing GitHub SSH access…"
    set +e
    # Exit code 1 is normal for github (no shell access); we check output text
    GH_MSG=$(sudo -u "$CURRENT_USER" ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1)
    GH_CODE=$?
    set -e
    if echo "$GH_MSG" | grep -qi "successfully authenticated"; then
      log "GitHub SSH authentication looks good."
      break
    fi
    echo
    echo "[INFO] GitHub hasn’t accepted the key yet."
    read -rp "Press Enter to retry, or type 'skip' to abort SSH setup: " ans
    if [[ "${ans,,}" == "skip" ]]; then
      error_exit "SSH setup aborted by user."
    fi
  done
}

# Try HTTPS first (works for public repos). If it fails, guide SSH setup.
if ! clone_attempt "$REPO_HTTPS"; then
  warn "HTTPS clone failed (private repo or perms). Switching to SSH setup."
  ensure_github_ssh_ready
  clone_attempt "$REPO_SSH" || error_exit "Clone via SSH failed."
fi

# ------------------------- checkout default branch ----------------
DEFAULT_BRANCH=$(git -C "$TARGET_DIR" remote show origin | sed -n 's/.*HEAD branch: //p')
if [[ -z "$DEFAULT_BRANCH" ]]; then
  warn "Could not determine default branch. Falling back to 'main' (or 'master' if missing)."
  if git -C "$TARGET_DIR" rev-parse --verify main >/dev/null 2>&1; then
    DEFAULT_BRANCH="main"
  elif git -C "$TARGET_DIR" rev-parse --verify master >/dev/null 2>&1; then
    DEFAULT_BRANCH="master"
  else
    error_exit "No 'main' or 'master' branch found."
  fi
fi

log "Checking out default branch: $DEFAULT_BRANCH"
git -C "$TARGET_DIR" checkout "$DEFAULT_BRANCH"
git -C "$TARGET_DIR" pull --ff-only origin "$DEFAULT_BRANCH" || true

# ------------------------- verification ---------------------------
log "Verifying installations…"
docker --version || error_exit "Docker not installed correctly."
if ! docker compose version >/dev/null 2>&1; then
  error_exit "Docker Compose plugin missing. Re-run: apt-get install -y docker-compose-plugin"
fi
git --version  >/dev/null 2>&1 || error_exit "Git not installed correctly."

# ------------------------- next steps -----------------------------
echo
echo "=================================================================="
echo "✅ Bootstrap complete."
echo "Repo cloned to: $TARGET_DIR"
echo
echo "Next steps (typical):"
echo "  cd \"$TARGET_DIR\""
echo "  # configure .env then start the stack"
echo "  ./scripts/main-setup/deploy.sh"
echo
echo "If you were just added to the 'docker' group, re-login or re-SSH now."
echo "=================================================================="


# HASSAN SHOAIB
