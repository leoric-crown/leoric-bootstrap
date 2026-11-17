# CLAUDE.md — leoric-bootstrap

## Status: SLIM curl-pipe entry point

Renamed `ansible-bootstrap` → `leoric-bootstrap` on 2026-05-14: the ansible invocation was removed in commit `22cdce9` (2026-05-13), so the old name was a documentation lie. The crown-jewel SSH/gh auth dance stays; provisioning is now done by chezmoi `run_onchange_*.sh.tmpl` scripts (see related repos).

Usage:

```bash
curl -fsSL "https://raw.githubusercontent.com/leoric-crown/leoric-bootstrap/main/bootstrap.bash?nocache=$(date +%s)" -o /tmp/bootstrap.bash && bash /tmp/bootstrap.bash 2>&1 | tee /tmp/bootstrap.log
```

**Download-then-exec, not pipe-to-bash.** Subprocesses inside the script (notably `brew install` on macOS) read from stdin; if bash itself is consuming the script from stdin (curl-pipe-bash form), those subprocess reads eat the unread portion of the script and bash silently terminates when it hits EOF. Caught the hard way on the M5 Macbook Air first run (2026-05-14). Using `-o /tmp/bootstrap.bash && bash /tmp/bootstrap.bash` makes bash read the script from a file argument; stdin is independent and subprocesses can consume it without scrambling execution.

(`curl` over `wget` — Arch base ships curl, not wget. The `tee` keeps a forensics log.)

**Branches:**
- `main` — current
- `archive/pre-2026-refactor` — preservation snapshot of the ansible-era state

## Crown jewel — DO NOT TOUCH

The following sections of `bootstrap.bash` represent 77 commits of accumulated bugfixes. Do not reorder, refactor for style, or "clean up." Edit only with specific reason and explicit user approval.

### Sudo keepalive (top of script, before `SCRIPTSDIR=`)

Background loop `sudo -n true; sleep 60` with PID captured and killed on EXIT trap. Subtle ordering; commit `85f0f8e` fixed double-agent spawning, commit `2591387` added the proper EXIT trap.

### SSH + gh + known_hosts dance (from `[+] Setting up SSH key for GitHub` to `[+] Pre-seeding github.com host keys`)

Ordering is **load-bearing**:

1. ed25519 keygen at `~/.ssh/id_leoric_ed25519_github` (idempotent: skips if exists)
2. ssh-agent spawn guard (only spawns if `SSH_AUTH_SOCK` unset **or** socket file gone — avoids classic double-agent footgun)
3. `ssh-add -l` grep before adding (idempotent)
4. SSH config heredoc with `IdentitiesOnly yes` (critical — prevents agent from offering wrong keys + getting rate-limited by GitHub)
5. **`insteadOf "https://github.com/" → git@github.com:`** rewrite, so subsequent HTTPS-style URLs resolve via SSH key. **Script-scoped since 2026-11-16** (git env-config `GIT_CONFIG_COUNT`/`KEY_0`/`VALUE_0`), never written to `~/.gitconfig`; see below.
6. SSH probe (`github_ssh_ok`): if GitHub already accepts the key, steps 6a/6b are skipped entirely, so a provisioned box never needs the scope refresh (which opens a browser).
   - 6a. `gh auth` with a `write:public_key` (or `admin:public_key`) scope — login or refresh.
   - 6b. `gh ssh-key add` with title `<hostname -s> bootstrap <date>`, skipped if the key material is already listed; then the probe runs again and reports. **This is what solves the chicken-and-egg** of "need GitHub access to clone the repos containing GitHub credentials."
7. `ssh-keyscan github.com >> ~/.ssh/known_hosts` (idempotent grep). Commit `b266f24` added this to fix the first-clone yes/no prompt.

Commits `9092f78` ("defer ssh-key add till later") and `b266f24` (known_hosts) explicitly fixed ordering bugs. **Do not reorder.**

### `insteadOf` rewrite, script-scoped (set in the SSH dance, cleared at `[+] Running chezmoi config`)

The rewrite lives only in the script's environment (`GIT_CONFIG_COUNT=1` + `GIT_CONFIG_KEY_0`/`VALUE_0`) and is `unset` right before the chezmoi pull/apply, so the chezmoi-managed `~/.gitconfig` is the only URL-rewrite source from then on. Until 2026-11-16 it was `git config --global` + `--unset`. On a provisioned box that wrote into the chezmoi-managed `~/.gitconfig`, and the unset left an empty `[url "git@github.com:"]` section behind, which made `chezmoi update` stop and ask about an externally modified file.

## Safe to re-run on any machine (2026-11-16)

The contract: a re-run on an already-provisioned box changes nothing that's already right, and never does anything destructive. Targets: leoric-ws (Omarchy 3.x, **packages frozen**), leoric-hp (Omarchy 4.x), leomba (macOS), predora (Fedora). What enforces it:

- **Packages:** the index is refreshed lazily, only before an install that's actually needed. Arch never does a bare `pacman -Sy` (that's a partial upgrade); installs use `pacman -Syu --needed`. A box with git/curl/sudo/gh already present never touches the package manager.
- **gsettings dark theme** is skipped on Omarchy (either generation); its theme system owns gtk-theme/color-scheme.
- **chezmoi** is installed only when it's missing (`~/.local/bin`); upgrades are `chezmoi upgrade`.
- **Omarchy 4 tools:** `~/.local/share/mise/shims` is appended to PATH, so the gh/claude probes find Omarchy's mise copies and don't install duplicates.
- **GitHub key:** the SSH probe comes first; scope and upload run only when GitHub refuses the key.
- **`~/scripts`** (`sync_repo`): it's cloned if missing, otherwise fast-forwarded only. If the checkout is on another branch, has uncommitted changes or has diverged, the script warns and leaves it alone. There's no `reset --hard` and no branch switching.
- **chezmoi apply:**
  - The pull (`chezmoi update --apply=false`) and the apply run as separate steps, and the pending run-scripts are listed in between.
  - If `install-packages` is pending on a box chezmoi has provisioned before (`~/.config/chezmoi/chezmoistate.boltdb` exists), the script asks first, default no. That script runs `pacman -Syu` / brew upgrades, and it's the guard for leoric-ws's freeze.
  - A first provision doesn't ask.
- **First-init branch:** `DOTFILES_BRANCH=<branch>` as an env var; it's ignored once chezmoi is initialized.
- **bash 3.2:** a fresh Mac runs this with `/bin/bash` 3.2. With `set -u`, an empty `"${arr[@]}"` is an unbound-variable error there, so use `${arr[@]+"${arr[@]}"}`.

## Cruft deleted 2026-05-13

80 lines of Fedora desktop polish removed in one pass (PIA installer hunt, GNOME extension `xdg-open` prompts, fastfetch/neofetch branch, NVIDIA driver hint, COSMIC DE hint). Easily recreated via git history if ever needed; out of scope for the curl-pipe contract.

## OS branches

### Active targets

- **Fedora (dnf)** — current desktop; transitioning to Omarchy
- **Arch (pacman)** — for Omarchy; currently stub-quality, gets fleshed out on Omarchy day-one (in chezmoi, not here)
- **Darwin (brew)** — for Macbook Neo arrival; currently untested per L270's "macOS not tested yet" comment

### Passive / unmaintained

- **apt** — Debian/Ubuntu/WSL. WSL was the only recent consumer (now EPAM-gone), but keeping the branch is cheap insurance for Ubuntu VMs, Raspberry Pi setups, loaned-laptop scenarios. Don't actively maintain; don't delete.

## Refactor checklist

- [x] Add Claude Code provisioning block after the SSH/gh dance — **done 2026-05-14**. Uses the cross-platform official installer at `https://claude.ai/install.sh` (download-then-exec), then `claude login` for device-code auth. Plugin replay happens automatically via chezmoi's `run_onchange_install-claude-plugins.sh.tmpl` once `claude` is on PATH + authed.
- [x] Delete desktop-polish cruft (80 lines) — done 2026-05-13.
- [x] Drop ansible invocation + ansible clone/sync + `SKIP_ANSIBLE` arg-parser — done 2026-05-13.
- [x] Verify Darwin branch on Macbook Air M5 (Tahoe 26.5) — **done 2026-05-14**. Fixed three bugs (hardcoded brew prefix via `uname -m`, NONINTERACTIVE=1, shellenv outside the install-conditional). Also fixed: resilient EXIT trap kill (sudo keepalive can die naturally on long brew installs), download-then-exec recommended entry point (curl-pipe-bash scrambled execution when brew consumed stdin), helper menu now selective (Pi keys cross-platform, Samba + BitLocker Linux-only).

## Don't

- Don't reorder the SSH + gh + known_hosts dance.
- Don't "modernize" the sudo keepalive without testing on a clean VM.
- Don't add new flags to the arg parser without thinking about curl-pipe UX (parser currently removed; the curl-pipe contract is zero args).
- Don't delete the apt branch.
- Don't merge `bootstrap.bash` and the helper menu (`[+] Running optional helper scripts`: pi-keys, mnt_shared, BitLocker) until the menu has been extracted cleanly to a post-bootstrap script.
- Don't add a step that only works on first run. Every step must be safe to repeat on a provisioned box (see the section above).

## Related repos

- `~/ansible/` — being sunset. Bootstrap currently invokes it (L262-274); refactor drops this invocation.
- `~/.local/share/chezmoi/` — provisioning destination. `chezmoi apply` runs the `run_onchange_*.sh.tmpl` scripts that will replace the ansible role logic.
- `~/scripts/` (`leoric-scripts` repo) — host of helper scripts referenced by the helper menu (Pi/Samba/BitLocker tooling).
