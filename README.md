# 🚀 leoric-bootstrap

Curl-pipe entry point that provisions a fresh workstation (Linux or macOS) by bootstrapping the GitHub auth chain and handing off to chezmoi.

This script automates:

- ✅ GitHub CLI login + SSH pubkey upload to GitHub
- ✅ Bootstrapping Homebrew on macOS (CLT install auto-triggered by brew's installer)
- ✅ Cloning your private [dotfiles](https://github.com/leoric-crown/dotfiles) via chezmoi
- ✅ `chezmoi apply` → `run_onchange_*` scripts handle packages, shell, plugins

---

## ⚡ Usage

Run this on a freshly installed Arch (Omarchy), Fedora, Ubuntu/WSL, or macOS system:

```bash
curl -fsSL "https://raw.githubusercontent.com/leoric-crown/leoric-bootstrap/main/bootstrap.bash?nocache=$(date +%s)" -o /tmp/bootstrap.bash && bash /tmp/bootstrap.bash 2>&1 | tee /tmp/bootstrap.log
```

**Why download-then-exec instead of curl-pipe-bash?** Subprocesses inside the script (notably `brew install` on macOS) read from stdin. In the `curl … | bash` form, bash is also reading the script from stdin — so those subprocess reads eat the unread portion of the script. Bash then silently hits EOF and terminates. Caught the hard way on a fresh M5 Macbook Air. Using `-o /tmp/bootstrap.bash && bash /tmp/bootstrap.bash` makes bash read the script from a file argument; subprocesses can consume stdin freely.

Safe to re-run on a machine that's already set up: it skips what's already in place, never resets `~/scripts`, and asks before a pending `install-packages` re-runs on a provisioned box.

To start a fresh machine on a non-default dotfiles branch, set `DOTFILES_BRANCH` (used only for the first `chezmoi init`):

```bash
curl -fsSL "https://raw.githubusercontent.com/leoric-crown/leoric-bootstrap/main/bootstrap.bash?nocache=$(date +%s)" -o /tmp/bootstrap.bash && DOTFILES_BRANCH=quattro-stack bash /tmp/bootstrap.bash 2>&1 | tee /tmp/bootstrap.log
```

`curl` is preferred because Arch base doesn't ship `wget`. The `tee` keeps a local log at `/tmp/bootstrap.log` for forensics — handy if anything in the pipeline fails partway.
