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
curl -fsSL "https://raw.githubusercontent.com/leoric-crown/leoric-bootstrap/main/bootstrap.bash?nocache=$(date +%s)" \
  | bash 2>&1 | tee /tmp/bootstrap.log
```

`curl` is preferred because Arch base doesn't ship `wget`. The `tee` keeps a local log at `/tmp/bootstrap.log` for forensics — handy if anything in the pipeline fails partway.
