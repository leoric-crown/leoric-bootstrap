#!/bin/bash
set -euo pipefail

trap 'echo "❌ Error on line $LINENO"' ERR

# Cache sudo credentials at script start
echo "[+] Caching sudo credentials..."
sudo -v

# Detach the keepalive loop’s stdin *and* capture its PID
while true; do sudo -n true; sleep 60; done \
  2>/dev/null </dev/null &
SUDO_LOOP_PID=$!

# Ensure the loop is killed on script exit. The keepalive can die on its
# own mid-script if sudo cache expires during a long install (set -e inside
# the subshell catches it), so the kill must tolerate a dead PID — without
# the `2>/dev/null || true`, ERR trap fires after a clean run.
trap 'kill "$SUDO_LOOP_PID" 2>/dev/null || true' EXIT

SCRIPTSDIR="$HOME/scripts"

SSH_KEY_PATH="$HOME/.ssh/id_leoric_ed25519_github"
SSH_PUB_PATH="${SSH_KEY_PATH}.pub"
# Canonical personal key for general SSH (pi/ws/vm/etc). chezmoi-managed
# ssh_config references it for ssh_hosts entries. Separate from the
# github-specific key above so IdentitiesOnly remains clean per-host.
PERSONAL_KEY_PATH="$HOME/.ssh/id_ed25519"
PERSONAL_PUB_PATH="${PERSONAL_KEY_PATH}.pub"

DOTFILESREPO="git@github.com:leoric-crown/dotfiles.git"
SCRIPTSREPO="git@github.com:leoric-crown/leoric-scripts.git"

SCRIPTBRANCH="main"

# Detect OS
OS_TYPE="$(uname -s)"
PACKAGE_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""

sync_repo() {
  local url=$1 dir=$2 branch=$3
  if [ ! -d "$dir/.git" ]; then
    git clone --depth 1 --branch "$branch" "$url" "$dir"
  else
    git -C "$dir" fetch origin "$branch"
    git -C "$dir" checkout "$branch"
    git -C "$dir" reset --hard "origin/$branch"
  fi
}

prompt_yes_no() {
  read -rp "$1 [y/N] " ans < /dev/tty
  [[ $ans =~ ^[Yy]$ ]]
}

if [[ "$OS_TYPE" == "Darwin" ]]; then
  # Apple Silicon vs Intel brew prefix — hardcode because brew isn't on PATH yet.
  if [[ "$(uname -m)" == "arm64" ]]; then
    BREW_BIN="/opt/homebrew/bin/brew"
  else
    BREW_BIN="/usr/local/bin/brew"
  fi

  if [[ ! -x "$BREW_BIN" ]]; then
    if ! xcode-select -p &>/dev/null; then
      echo "[!] Command Line Tools (CLT) needed by Homebrew (~1-2GB)."
      echo "    The Homebrew installer triggers macOS's CLT install GUI — click 'Install'"
      echo "    when the popup appears, wait for it to finish, then this script resumes."
    fi
    echo "[+] Installing Homebrew (non-interactive)..."
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  # Always re-init brew PATH for the rest of this script.
  eval "$("$BREW_BIN" shellenv)"

  PACKAGE_MANAGER="brew"
  INSTALL_CMD="brew install"
  UPDATE_CMD="brew update"
elif [[ -f /etc/os-release ]]; then
  # Linux: detect package manager
  . /etc/os-release
  case "$ID" in
    ubuntu|debian)
      PACKAGE_MANAGER="apt"
      INSTALL_CMD="sudo apt-get install -y"
      UPDATE_CMD="sudo apt-get update"
      ;;
    fedora|rhel|centos)
      PACKAGE_MANAGER="dnf"
      INSTALL_CMD="sudo dnf install -y"
      UPDATE_CMD="sudo dnf makecache --refresh"
      ;;
    arch)
      PACKAGE_MANAGER="pacman"
      INSTALL_CMD="sudo pacman -S --noconfirm"
      UPDATE_CMD="sudo pacman -Sy"
      ;;
    *)(
      echo "❌ Unsupported Linux distribution: $ID" >&2
      exit 1
      )
      ;;
  esac
else
  echo "❌ Unsupported OS: $OS_TYPE" >&2
  echo "Supported OS: macOS, Linux (Fedora, Ubuntu, Debian, Arch)"
  exit 1
fi

echo "🚀 Starting bootstrap process..."

echo "Found package manager: $PACKAGE_MANAGER"
echo "Found install command: $INSTALL_CMD"
echo "Found update command: $UPDATE_CMD"

echo "[+] Updating package list..."
$UPDATE_CMD

install_if_missing() {
  local pkg="$1"                 # probe binary (command name)
  local pkgname="${2:-$1}"       # package name — may differ from the binary (e.g. gh -> github-cli on Arch)
  if ! command -v "$pkg" &>/dev/null; then
    echo "[+] Installing $pkg (pkg: $pkgname)..."
    $INSTALL_CMD "$pkgname"
  else
    echo "[✓] $pkg already installed."
  fi
}

# Ensure required commands are installed
install_if_missing git
install_if_missing curl
install_if_missing sudo

for cmd in git curl sudo; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ $cmd is required but not installed. Please install it manually first."
    exit 1
  fi
done

cd "$HOME"
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/bin:$PATH"

# Run in a subshell with `set +e` so errors never bubble out
(
  set +e

  # Only try gsettings if it exists and there's a session bus
  if command -v gsettings &>/dev/null && [ -S "/run/user/$(id -u)/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    echo "[+] Setting dark theme..."
    gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark' || true
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true
  fi
)

# Install GitHub CLI (gh). Omarchy ships it OOTB (VM smoke test passed), so this
# usually no-ops — but on Arch the package is `github-cli`, not `gh`, so a bare
# `pacman -S gh` would "target not found" and (under set -e) abort the whole bootstrap.
if [[ "${PACKAGE_MANAGER:-}" == "pacman" ]]; then
  install_if_missing gh github-cli
else
  install_if_missing gh
fi

# Ensure chezmoi is installed.
# -b "$HOME/.local/bin": the installer defaults to ./bin (i.e. ~/bin when run
# from HOME), which is NOT on the durable interactive PATH — only ~/.local/bin
# is (via chezmoi-managed dot_zshrc). Without -b, chezmoi works for the rest
# of THIS script (line ~148 adds ~/bin to the script's PATH) but disappears
# from the user's shell afterward. Install straight into a PATH dir instead.
echo "[+] Ensuring chezmoi is installed/up-to-date..."
curl -fsLS get.chezmoi.io | sh -s -- -b "$HOME/.local/bin"


echo "[+] Setting up SSH key for GitHub..."

# Generate the GitHub-specific SSH key if it doesn't exist
if [ ! -f "$SSH_KEY_PATH" ]; then
  echo "[+] Generating new SSH key at $SSH_KEY_PATH..."
  ssh-keygen -t ed25519 -C "leoric@$(hostname)" -f "$SSH_KEY_PATH" -N ""
else
  echo "[✓] SSH key already exists at $SSH_KEY_PATH"
fi

# Generate the canonical personal SSH key (idempotent; only if missing).
# Used by chezmoi-managed ssh_config for pi/ws/vm/etc. ssh-copy-id helpers
# downstream assume this exists.
if [ ! -f "$PERSONAL_KEY_PATH" ]; then
  echo "[+] Generating personal SSH key at $PERSONAL_KEY_PATH..."
  ssh-keygen -t ed25519 -C "leoric@$(hostname)" -f "$PERSONAL_KEY_PATH" -N ""
else
  echo "[✓] Personal SSH key already exists at $PERSONAL_KEY_PATH"
fi

# Add to ssh-agent
if [[ -z "${SSH_AUTH_SOCK:-}" || ! -S "$SSH_AUTH_SOCK" ]]; then
  echo "[+] Starting new ssh-agent..."
  eval "$(ssh-agent -s)" >/dev/null
fi

# Add both keys if not already loaded
if ! ssh-add -l 2>/dev/null | grep -q "$SSH_KEY_PATH"; then
  echo "[+] Adding SSH key to agent: $SSH_KEY_PATH"
  ssh-add "$SSH_KEY_PATH"
else
  echo "[✓] SSH key already loaded in agent"
fi
if ! ssh-add -l 2>/dev/null | grep -q "$PERSONAL_KEY_PATH"; then
  echo "[+] Adding personal SSH key to agent: $PERSONAL_KEY_PATH"
  ssh-add "$PERSONAL_KEY_PATH"
else
  echo "[✓] Personal SSH key already loaded in agent"
fi

# Ensure SSH config for GitHub uses this key
SSH_CONFIG_ENTRY=$(cat <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile $SSH_KEY_PATH
  IdentitiesOnly yes
EOF
)

mkdir -p ~/.ssh
touch ~/.ssh/config
chmod 600 ~/.ssh/config
if ! grep -q "$SSH_KEY_PATH" ~/.ssh/config 2>/dev/null; then
  echo "[+] Adding SSH config for github.com..."
  echo "$SSH_CONFIG_ENTRY" >> ~/.ssh/config
else
  echo "[✓] SSH config for github.com already set"
fi
echo "[✓] SSH config for github.com set. Key fingerprint: $(ssh-keygen -lf "$SSH_PUB_PATH")"

# Ensure Git is using SSH
git config --global url."git@github.com:".insteadOf "https://github.com/"

# Ensure GitHub CLI is authenticated WITH the write:public_key scope so we can
# upload our SSH pubkey below. The interactive --web flow skips the
# "upload SSH key?" prompt in a non-TTY (curl-pipe) context, so we request the
# scope upfront and do the upload explicitly.
echo "[+] Checking GitHub authentication..."
required_scope="write:public_key"
if ! gh auth status 2>&1 | grep -q "$required_scope"; then
  if gh auth status >/dev/null 2>&1; then
    echo "[+] Refreshing gh token to add $required_scope scope..."
    gh auth refresh --hostname github.com -s "$required_scope"
  else
    gh auth login --hostname github.com --git-protocol ssh --web -s "$required_scope"
  fi
else
  echo "[✓] gh already authed with $required_scope scope"
fi

# Upload SSH pubkey to GitHub if not already there. Idempotent — grep by the
# key material itself (column 2 of the .pub file), not by title.
pubkey_material=$(awk '{print $2}' "$SSH_PUB_PATH")
if ! gh ssh-key list 2>/dev/null | grep -qF "$pubkey_material"; then
  echo "[+] Uploading SSH public key to GitHub..."
  gh ssh-key add "$SSH_PUB_PATH" --title "$(hostname) bootstrap $(date +%Y-%m-%d)"
else
  echo "[✓] SSH public key already registered on GitHub"
fi

# Pre-seed github.com into known_hosts so the upcoming chezmoi/git clones
# don't prompt for host-key acceptance. `ssh-keygen -F` is the canonical
# "is this host already trusted?" check — handles hashed entries that
# `grep` would miss.
echo "[+] Pre-seeding github.com host keys in known_hosts..."
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/known_hosts"
if ssh-keygen -F github.com >/dev/null 2>&1; then
  echo "[✓] github.com already trusted"
elif command -v ssh-keyscan >/dev/null 2>&1; then
  if ssh-keyscan -t ed25519,rsa github.com 2>/dev/null >> "$HOME/.ssh/known_hosts"; then
    echo "[✓] github.com host keys added"
  else
    echo "⚠️  ssh-keyscan failed; will fall back to StrictHostKeyChecking=accept-new"
  fi
else
  echo "⚠️  ssh-keyscan not available; will fall back to StrictHostKeyChecking=accept-new"
fi

# Install Claude Code so chezmoi's run_onchange_install-claude-plugins.sh.tmpl
# can register marketplaces + replay plugins on first apply. Cross-platform
# official installer; same URL works on macOS and Linux. Defensive
# download-then-exec — the installer is short but consistency matters.
if ! command -v claude &>/dev/null; then
  echo "[+] Installing Claude Code..."
  claude_install="$(mktemp)"
  curl -fsSL "https://claude.ai/install.sh" -o "$claude_install"
  bash "$claude_install" || echo "⚠️  Claude installer returned non-zero; continuing."
  rm -f "$claude_install"
  # The installer updates the user's shell rc, but that doesn't help THIS
  # script's PATH. Probe likely install locations and prepend explicitly.
  for d in "$HOME/.local/bin" "$HOME/.claude/local"; do
    if [[ -x "$d/claude" && ":$PATH:" != *":$d:"* ]]; then
      export PATH="$d:$PATH"
    fi
  done
  hash -r
else
  echo "[✓] Claude Code already installed."
fi

if command -v claude &>/dev/null; then
  echo "[✓] Claude Code at $(command -v claude)"
  # Authentication note: `claude login` is a status-probe CLI subcommand
  # (returns non-zero when not authed and prints "Please run /login").
  # Actual auth happens inside the REPL via the `/login` slash command —
  # there's no programmatic auth, so we don't try here. The chezmoi
  # run_onchange_install-claude-plugins.sh.tmpl exits 1 on unauth'd
  # marketplace list, so subsequent `chezmoi apply` runs auto-retry once
  # the user completes /login.
  echo "    To authenticate after bootstrap: open a fresh terminal, run 'claude',"
  echo "    type '/login', complete the browser flow. Then: chezmoi apply"
else
  echo "⚠️  Claude not on PATH after install attempt — plugin replay will be skipped."
  echo "    After bootstrap: install Claude manually (https://claude.ai/install.sh),"
  echo "    fresh terminal → 'claude' → '/login', then chezmoi apply."
fi

echo "[+] Initializing chezmoi..."
if [ -d "$HOME/.local/share/chezmoi" ]; then
  echo "[✓] chezmoi already initialized"
else
  echo "[+] First-time init of chezmoi"
  # accept-new auto-trusts unknown hosts but still rejects changed keys —
  # safety net if the ssh-keyscan above couldn't preload.
  GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
    chezmoi init "$DOTFILESREPO"
fi

# Scripts repo — sync_repo handles both clone-if-missing and fetch+reset
# if already present, so existing checkouts always end at origin/$SCRIPTBRANCH.
echo "[+] Syncing leoric-scripts repo (branch: $SCRIPTBRANCH)…"
sync_repo "$SCRIPTSREPO" "$SCRIPTSDIR" "$SCRIPTBRANCH"

# Apply chezmoi config
echo "[+] Running chezmoi config..."
# Revert the in-bootstrap insteadOf rewrite (set during the SSH/gh dance) so
# the chezmoi-managed ~/.gitconfig becomes the authoritative URL-rewrite source.
git config --global --unset url."git@github.com:".insteadOf

# Use `chezmoi update` (pull + apply) so re-runs of bootstrap pick up upstream
# chezmoi commits — this is what makes the full bootstrap one-liner idempotent
# end-to-end. On first run, the pull is a no-op (source was just cloned).
#
# If chezmoi update fails (e.g. a run_onchange_ script bailed because sudo
# wasn't cached), don't crash bootstrap.bash — try once with refreshed sudo,
# then surface the failure cleanly.
if ! chezmoi update; then
  echo
  echo "⚠️  chezmoi apply returned non-zero. Most common cause: a run_onchange_"
  echo "    script needed sudo and the cached credentials expired."
  echo "[+] Refreshing sudo and retrying once..."
  if sudo -v && chezmoi update; then
    echo "✓ chezmoi update succeeded on retry."
  else
    echo "✗ chezmoi update still failing — inspect output above. You can rerun"
    echo "  manually any time with: sudo -v && chezmoi update"
    echo "  Bootstrap will continue to the helper menu so you can still use"
    echo "  the partially-provisioned system."
  fi
fi

# Helper scripts.
# Dropped from this menu (2026-05-13):
#   - add-gh-ssh-keys.bash → bootstrap.bash now uploads the personal SSH key
#     inline; the helper was designed for a dual-account flow (personal +
#     EPAM `id_rleon1_*`) that we purged earlier.
#   - sync-pihole-hosts.bash → manual /etc/hosts sync from pihole, not
#     bootstrap-critical. Still runnable on-demand from ~/scripts/linux/.
PI_KEYS_SCRIPT="$SCRIPTSDIR/ssh/add-pi-ssh-keys.bash"
MNT_SHARED_SCRIPT="$SCRIPTSDIR/linux/mnt_shared.bash"
BITLOCKER_SCRIPT="$SCRIPTSDIR/linux/bitlocker/bitlocker-setup.bash"
# BRIDGE_SCRIPT="$SCRIPTSDIR/linux/fedora/br0.bash" # TODO

echo "[+] Running optional helper scripts..."

# Parallel arrays — avoids `declare -A name=(["key with spaces"]=val)` which
# trips bash's set -u in some versions (arithmetic eval on the key names the
# inner words as variables; reproduced as "Pis: unbound variable" on macOS
# bash 4). Pi-keys helper is cross-platform (ssh-copy-id); Samba mount +
# BitLocker are Linux-only (systemd .mount / cryptsetup), so we omit them
# on macOS — SMB on Mac: Finder → Cmd+K → smb://<host>/<share>.
helper_names=("Add SSH keys to Pis")
helper_paths=("$PI_KEYS_SCRIPT")
if [[ "$OS_TYPE" != "Darwin" ]]; then
  helper_names+=("Mount Samba share" "Set up BitLocker mounts")
  helper_paths+=("$MNT_SHARED_SCRIPT" "$BITLOCKER_SCRIPT")
fi
# To add another helper: append to both arrays in parallel.
# "Set up br0 bridge interface" / "$BRIDGE_SCRIPT" # TODO


for i in "${!helper_names[@]}"; do
  desc="${helper_names[$i]}"
  path="${helper_paths[$i]}"
  if [ -f "$path" ]; then
    if prompt_yes_no "Do you want to ${desc}?"; then
      echo "[+] ${desc}..."
      chmod +x "$path"
      # Helpers are optional + interactive; don't kill the bootstrap if one
      # fails (e.g. user typos a password during ssh-copy-id).
      if ! bash "$path"; then
        echo "⚠️  ${desc} exited non-zero; continuing with next helper"
      fi
    else
      echo "⏭️  Skipping ${desc}."
    fi
  else
    echo "⚠️  ${desc} script not found at $path — skipping"
  fi
done

echo "✓ Done! To apply your new login shell and desktop entries, log out and back in (or reboot)."
echo
echo "Enjoy your new workstation!"
echo

exit 0
