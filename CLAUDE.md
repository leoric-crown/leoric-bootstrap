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

### Sudo keepalive (L20-32)

Background loop `sudo -n true; sleep 60` with PID captured and killed on EXIT trap. Subtle ordering; commit `85f0f8e` fixed double-agent spawning, commit `2591387` added the proper EXIT trap.

### SSH + gh + known_hosts dance (L170-227)

Ordering is **load-bearing**:

1. ed25519 keygen at `~/.ssh/id_leoric_ed25519_github` (idempotent: skips if exists)
2. ssh-agent spawn guard (only spawns if `SSH_AUTH_SOCK` unset **or** socket file gone — avoids classic double-agent footgun)
3. `ssh-add -l` grep before adding (idempotent)
4. SSH config heredoc with `IdentitiesOnly yes` (critical — prevents agent from offering wrong keys + getting rate-limited by GitHub)
5. **`insteadOf "https://github.com/" → git@github.com:`** rewrite, so subsequent HTTPS-style URLs resolve via SSH key
6. `gh auth login --git-protocol ssh --web` — uploads the freshly-generated pubkey to GitHub when the user completes the device-code flow. **This is what solves the chicken-and-egg** of "need GitHub access to clone the repos containing GitHub credentials."
7. `ssh-keyscan github.com >> ~/.ssh/known_hosts` (idempotent grep). Commit `b266f24` added this to fix the first-clone yes/no prompt.

Commits `9092f78` ("defer ssh-key add till later") and `b266f24` (known_hosts) explicitly fixed ordering bugs. **Do not reorder.**

### `insteadOf` rewrite-then-unset (L262-281)

After chezmoi + ansible apply, L280 unsets the `insteadOf` rewrite **before** running `chezmoi apply`, so the chezmoi-managed `~/.gitconfig` becomes the authoritative URL-rewrite source going forward. Subtle but load-bearing — without the unset, you'd have two conflicting `insteadOf` blocks.

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

- Don't reorder L170-227.
- Don't "modernize" the sudo keepalive (L20-32) without testing on a clean VM.
- Don't add new flags to the arg parser without thinking about curl-pipe UX (parser currently removed; the curl-pipe contract is zero args).
- Don't delete the apt branch.
- Don't merge `bootstrap.bash` and the helper menu (L283-329 helpers: gh-keys, pi-keys, pihole, mnt_shared, BitLocker) until the menu has been extracted cleanly to a post-bootstrap script.

## Related repos

- `~/ansible/` — being sunset. Bootstrap currently invokes it (L262-274); refactor drops this invocation.
- `~/.local/share/chezmoi/` — provisioning destination. `chezmoi apply` runs the `run_onchange_*.sh.tmpl` scripts that will replace the ansible role logic.
- `~/scripts/` (`leoric-scripts` repo) — host of helper scripts referenced by the menu at L283-329 (Pi/PiHole/Samba/BitLocker tooling).
