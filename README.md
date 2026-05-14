# 🚀 bootstrap-ansible

Provision Ubuntu/Fedora workstations in minutes using GitHub + Ansible + chezmoi.

This script automates:

- ✅ GitHub CLI login
- ✅ Cloning your private [dotfiles](https://github.com/leoric-crown/dotfiles) via chezmoi
- ✅ Cloning and applying your [ansible](https://github.com/leoric-crown/ansible) provisioning repo
- ✅ Mostly unattended workstation setup

---

## ⚡ Usage

Run this on a freshly installed Arch (Omarchy), Fedora, or Ubuntu/WSL system:

```bash
curl -fsSL "https://raw.githubusercontent.com/leoric-crown/ansible-bootstrap/main/bootstrap.bash?nocache=$(date +%s)" \
  | bash 2>&1 | tee /tmp/bootstrap.log
```

`curl` is preferred because Arch base doesn't ship `wget`. The `tee` keeps a local log at `/tmp/bootstrap.log` for forensics — handy if anything in the pipeline fails partway.
