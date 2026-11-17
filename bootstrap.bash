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
# Branch for a FIRST chezmoi init only (an existing source dir keeps whatever
# branch it's on). Env var, not a flag, to keep the zero-arg curl contract:
#   DOTFILES_BRANCH=quattro-stack bash /tmp/bootstrap.bash
DOTFILES_BRANCH="${DOTFILES_BRANCH:-}"

# Omarchy (either generation) owns the desktop theme and ships its own tool
# set; several steps below defer to it. Gen 4 = /usr/share/omarchy (system
# package), gen 3 = ~/.local/share/omarchy (git checkout).
IS_OMARCHY=0
if [[ -d /usr/share/omarchy || -d "$HOME/.local/share/omarchy" ]]; then
  IS_OMARCHY=1
fi

# Detect OS
OS_TYPE="$(uname -s)"
PACKAGE_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""

# Clone if missing; otherwise fast-forward only. Never reset --hard, never
# switch branches: an existing checkout may hold local work (leoric-scripts is
# edited in place), so anything that isn't a clean fast-forward on $branch is
# reported and left alone. chezmoi's run_before_pull-leoric-scripts keeps it
# current on later applies anyway.
sync_repo() {
  local url=$1 dir=$2 branch=$3 current
  if [ ! -d "$dir/.git" ]; then
    git clone --branch "$branch" "$url" "$dir"
    return
  fi
  current="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  if [[ "$current" != "$branch" ]]; then
    echo "⚠️  $dir is on branch '$current', not '$branch'; leaving it alone."
    return
  fi
  if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
    echo "⚠️  $dir has uncommitted changes; leaving it alone."
    return
  fi
  if ! git -C "$dir" fetch origin "$branch"; then
    echo "⚠️  fetch failed for $dir; leaving it as is."
    return
  fi
  if git -C "$dir" merge --ff-only "origin/$branch" >/dev/null 2>&1; then
    echo "[✓] $dir at origin/$branch"
  else
    echo "⚠️  $dir has diverged from origin/$branch; leaving it alone (resolve by hand)."
  fi
}

# Does GitHub accept our SSH key? GitHub answers a successful auth with exit 1
# and "successfully authenticated", a refused key with 255. accept-new trusts
# github.com on first contact (same TOFU as the ssh-keyscan step) but still
# rejects a CHANGED host key.
github_ssh_ok() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes \
      -i "$SSH_KEY_PATH" -T git@github.com 2>&1 | grep -q "successfully authenticated"
}

prompt_yes_no() {
  read -rp "$1 [y/N] " ans < /dev/tty
  [[ $ans =~ ^[Yy]$ ]]
}

# Report SSH reachability as "<sshd_active> <port22>" e.g. "active open" /
# "inactive blocked". Read-only. Linux-only (sshd/ufw) — callers gate on
# OS_TYPE. "open" also covers the no-firewall case (nothing dropping :22).
ssh_status() {
  local active port
  active="$(systemctl is-active sshd 2>/dev/null || true)"
  if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -qi '^Status: active'; then
    if sudo ufw status 2>/dev/null | grep -qE '22/tcp|OpenSSH'; then port="open"; else port="blocked"; fi
  else
    port="open"
  fi
  echo "$active $port"
}

# Collapse duplicate entries in $PATH (keep first occurrence). Bash has no
# zsh-style `typeset -U path`; a duplicate ~/.local/bin makes the Astral uv
# installer emit a spurious "uv/uvx shadowed by other commands" warning.
dedupe_path() {
  local IFS=: dir out="" seen=":"
  for dir in $PATH; do
    if [ -z "$dir" ]; then continue; fi
    case "$seen" in *":$dir:"*) continue ;; esac
    out="${out:+$out:}$dir"
    seen="${seen}${dir}:"
  done
  PATH="$out"
  export PATH
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
  # Match on ID first, then each ID_LIKE entry: derivatives report their own
  # ID (Omarchy 4: ID=omarchy, ID_LIKE=arch; Omarchy 3.x said plain ID=arch).
  distro=""
  for candidate in "$ID" ${ID_LIKE:-}; do
    case "$candidate" in
      ubuntu|debian|fedora|rhel|centos|arch) distro="$candidate"; break ;;
    esac
  done
  case "$distro" in
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
      # Never a bare `pacman -Sy`: syncing the db and then installing with
      # -S is a partial upgrade, which Arch doesn't support. Installs go
      # through -Syu --needed instead, and only when something is actually
      # missing, so a fully provisioned (or package-frozen) Arch box never
      # touches pacman here.
      PACKAGE_MANAGER="pacman"
      INSTALL_CMD="sudo pacman -Syu --needed --noconfirm"
      UPDATE_CMD=""
      ;;
    *)
      # Plain exit, not inside ( ... ): a subshell's exit only leaves the
      # subshell.
      echo "❌ Unsupported Linux distribution: $ID (ID_LIKE: ${ID_LIKE:-none})" >&2
      exit 1
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
echo "Found update command: ${UPDATE_CMD:-<none; folded into install>}"

# The package index is refreshed lazily: only right before the first install
# that's actually needed. A re-run on a provisioned box changes nothing.
PKG_INDEX_FRESH=0
refresh_pkg_index_once() {
  if [[ $PKG_INDEX_FRESH -eq 0 && -n "$UPDATE_CMD" ]]; then
    echo "[+] Updating package list..."
    $UPDATE_CMD
  fi
  PKG_INDEX_FRESH=1
}

install_if_missing() {
  local pkg="$1"                 # probe binary (command name)
  local pkgname="${2:-$1}"       # package name — may differ from the binary (e.g. gh -> github-cli on Arch)
  if ! command -v "$pkg" &>/dev/null; then
    refresh_pkg_index_once
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
# Prepend personal bin dirs, then collapse dupes so a ~/.local/bin already on
# PATH (parent shell / Omarchy profile) isn't doubled — a duplicate entry
# triggers a spurious "uv/uvx shadowed" warning from the Astral installer.
PATH="$HOME/bin:$HOME/.local/bin:$PATH"
# Omarchy 4 provides gh, claude, node, uv... as mise tools (shims install on
# first use). Append the shim dir so the "already installed?" probes below see
# them instead of installing a second copy. Appended, not prepended: same
# order as Omarchy's own env-bootstrap.
if [[ -d "$HOME/.local/share/mise/shims" ]]; then
  PATH="$PATH:$HOME/.local/share/mise/shims"
fi
dedupe_path

# Run in a subshell with `set +e` so errors never bubble out
(
  set +e

  # Only try gsettings if it exists and there's a session bus. Not on Omarchy:
  # its theme system sets gtk-theme/color-scheme per theme (light themes
  # included), and forcing Adwaita-dark on every run would fight it.
  if [[ $IS_OMARCHY -eq 0 ]] && command -v gsettings &>/dev/null && [ -S "/run/user/$(id -u)/bus" ]; then
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
# Install only when missing: reinstalling on every run would drop a second
# copy into ~/.local/bin on a box whose chezmoi lives elsewhere (e.g. ~/bin
# from a manual install). Upgrading is `chezmoi upgrade`, at the user's cadence.
if command -v chezmoi &>/dev/null; then
  echo "[✓] chezmoi already installed at $(command -v chezmoi)"
else
  echo "[+] Installing chezmoi..."
  curl -fsLS get.chezmoi.io | sh -s -- -b "$HOME/.local/bin"
fi


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

# Ensure Git is using SSH — for THIS script's git calls only. Set through
# git's env-config (GIT_CONFIG_COUNT/KEY_n/VALUE_n), not `git config --global`:
# on a provisioned box ~/.gitconfig is chezmoi-managed, and the old
# write-then-unset left an empty [url] section behind that made the next
# `chezmoi update` stop and ask about an externally modified file. Nothing
# here touches disk; it's cleared again before the chezmoi apply below.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0='url.git@github.com:.insteadOf'
export GIT_CONFIG_VALUE_0='https://github.com/'

# Upload the SSH pubkey to GitHub, unless GitHub already accepts it. The SSH
# probe comes first so a box whose key is registered never needs the
# public_key scope (asking for it opens a browser every run otherwise).
echo "[+] Checking GitHub SSH access..."
if github_ssh_ok; then
  echo "[✓] GitHub already accepts $SSH_KEY_PATH; skipping gh key upload"
else
  # Ensure GitHub CLI is authenticated WITH a public_key write scope so we can
  # upload our SSH pubkey below. The interactive --web flow skips the
  # "upload SSH key?" prompt in a non-TTY (curl-pipe) context, so we request
  # the scope upfront and do the upload explicitly. admin:public_key also
  # counts (it includes write).
  echo "[+] Checking GitHub authentication..."
  required_scope="write:public_key"
  if ! gh auth status 2>&1 | grep -qE "(write|admin):public_key"; then
    if gh auth status >/dev/null 2>&1; then
      echo "[+] Refreshing gh token to add $required_scope scope..."
      gh auth refresh --hostname github.com -s "$required_scope"
    else
      gh auth login --hostname github.com --git-protocol ssh --web -s "$required_scope"
    fi
  else
    echo "[✓] gh already authed with a public_key write scope"
  fi

  # Upload SSH pubkey to GitHub if not already there. Idempotent — grep by the
  # key material itself (column 2 of the .pub file), not by title.
  pubkey_material=$(awk '{print $2}' "$SSH_PUB_PATH")
  if ! gh ssh-key list 2>/dev/null | grep -qF "$pubkey_material"; then
    echo "[+] Uploading SSH public key to GitHub..."
    gh ssh-key add "$SSH_PUB_PATH" --title "$(hostname -s) bootstrap $(date +%Y-%m-%d)"
  else
    echo "[✓] SSH public key already registered on GitHub"
  fi

  if github_ssh_ok; then
    echo "[✓] GitHub now accepts $SSH_KEY_PATH"
  else
    echo "⚠️  GitHub still refuses $SSH_KEY_PATH; the clones below will likely fail."
  fi
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
# Recorded before init: "provisioned" = chezmoi has applied on this box
# before. Gates the install-packages confirmation further down.
FIRST_APPLY=1
if [[ -f "$HOME/.config/chezmoi/chezmoistate.boltdb" ]]; then
  FIRST_APPLY=0
fi

if [ -d "$HOME/.local/share/chezmoi" ]; then
  echo "[✓] chezmoi already initialized (branch: $(git -C "$HOME/.local/share/chezmoi" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'))"
  if [[ -n "$DOTFILES_BRANCH" ]]; then
    echo "    DOTFILES_BRANCH=$DOTFILES_BRANCH ignored: it only applies to a first init."
  fi
else
  echo "[+] First-time init of chezmoi${DOTFILES_BRANCH:+ (branch: $DOTFILES_BRANCH)}"
  init_args=()
  if [[ -n "$DOTFILES_BRANCH" ]]; then
    init_args=(--branch "$DOTFILES_BRANCH")
  fi
  # accept-new auto-trusts unknown hosts but still rejects changed keys —
  # safety net if the ssh-keyscan above couldn't preload.
  GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
    chezmoi init ${init_args[@]+"${init_args[@]}"} "$DOTFILESREPO"  # bash 3.2 (fresh macOS) + set -u: empty "${a[@]}" is unbound
fi

# Scripts repo — sync_repo handles both clone-if-missing and fetch+reset
# if already present, so existing checkouts always end at origin/$SCRIPTBRANCH.
echo "[+] Syncing leoric-scripts repo (branch: $SCRIPTBRANCH)…"
sync_repo "$SCRIPTSREPO" "$SCRIPTSDIR" "$SCRIPTBRANCH"

# Apply chezmoi config
echo "[+] Running chezmoi config..."
# Drop the script-scoped insteadOf rewrite (set during the SSH/gh dance) so
# the chezmoi-managed ~/.gitconfig is the only URL-rewrite source for the
# pull and apply below.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# Pull upstream chezmoi commits first, then apply as a separate step, so
# re-runs of bootstrap pick up new commits (that's what makes the one-liner
# idempotent end-to-end) but we can look at what will run before it runs.
# On first run, the pull is a no-op (source was just cloned).
if ! chezmoi update --apply=false; then
  echo "⚠️  chezmoi couldn't pull upstream; applying the local source as is."
fi

# Show which run-scripts this apply will execute. install-packages is the
# heavy one: on Arch it runs `pacman -Syu`, which must never happen behind
# the back of a box whose packages are deliberately frozen (leoric-ws, until
# its Quattro upgrade). On a box chezmoi has provisioned before, it only
# runs when someone changed it upstream, so ask (default: no). A first
# provision doesn't ask; installing packages is the point.
pending_scripts="$(chezmoi status --include=scripts 2>/dev/null | awk '{print $NF}' || true)"
if [[ -n "$pending_scripts" ]]; then
  echo "[+] Scripts this apply will run:"
  printf '      %s\n' $pending_scripts
fi
DO_APPLY=1
if [[ $FIRST_APPLY -eq 0 ]] && grep -q 'install-packages' <<<"$pending_scripts"; then
  echo "⚠️  install-packages is pending on an already-provisioned box."
  echo "    It installs/upgrades system packages (Arch: pacman -Syu; macOS: brew)."
  if ! prompt_yes_no "Run it now (applies everything else too)?"; then
    DO_APPLY=0
    echo "⏭️  Skipping chezmoi apply. Run it later with: sudo -v && chezmoi apply"
  fi
fi

# If the apply fails (e.g. a run_onchange_ script bailed because sudo wasn't
# cached), don't crash bootstrap.bash — try once with refreshed sudo, then
# surface the failure cleanly.
if [[ $DO_APPLY -eq 1 ]] && ! chezmoi apply; then
  echo
  echo "⚠️  chezmoi apply returned non-zero. Most common cause: a run_onchange_"
  echo "    script needed sudo and the cached credentials expired."
  echo "[+] Refreshing sudo and retrying once..."
  if sudo -v && chezmoi apply; then
    echo "✓ chezmoi apply succeeded on retry."
  else
    echo "✗ chezmoi apply still failing — inspect output above. You can rerun"
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

# Remote access: offer to open SSH so a future degraded run can be
# troubleshot from another machine (see the report printed at end of run).
# Only prompts when the box isn't already reachable, so it's silent on a
# box that's already set up. Opt-in — enabling sshd is a posture choice.
if [[ "$OS_TYPE" == "Linux" ]]; then
  read -r _sshd _port <<<"$(ssh_status)"
  if [[ "$_sshd" != "active" || "$_port" == "blocked" ]]; then
    if prompt_yes_no "Enable SSH server + open the firewall for remote access?"; then
      if sudo systemctl enable --now sshd; then echo "✓ sshd enabled"; else echo "⚠️  could not enable sshd"; fi
      if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -qi '^Status: active'; then
        sudo ufw allow ssh >/dev/null 2>&1 && echo "✓ ufw: port 22 opened" || true
      fi
    else
      echo "⏭️  Skipping SSH remote-access setup."
    fi
  fi
fi

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

# Remote-access cheat-sheet — always printed on Linux so the IP + the exact
# fix commands are one glance away if you ever need to SSH in to recover a
# degraded box (the toil this whole block exists to kill).
if [[ "$OS_TYPE" == "Linux" ]]; then
  _ips="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | paste -sd' ' - || true)"
  read -r _sshd _port <<<"$(ssh_status)"
  echo "── Remote access (SSH) ──"
  echo "  Host: $(hostname)    LAN IP: ${_ips:-<none found>}"
  if [[ "$_sshd" == "active" ]]; then echo "  sshd:    active ✓"; else echo "  sshd:    OFF     → sudo systemctl enable --now sshd"; fi
  if [[ "$_port" == "open" ]]; then echo "  port 22: reachable ✓"; else echo "  port 22: BLOCKED → sudo ufw allow ssh"; fi
  [[ -n "${_ips:-}" ]] && echo "  Connect: ssh $(id -un)@$(awk '{print $1}' <<<"$_ips")"
  echo
fi

echo "Enjoy your new workstation!"
echo

exit 0
