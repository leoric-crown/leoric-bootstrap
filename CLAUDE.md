# CLAUDE.md — ansible-bootstrap

## Status: REFACTORING

Curl-pipe entry point for fresh-machine bootstrap:

```bash
wget -qO- "https://raw.githubusercontent.com/leoric-crown/ansible-bootstrap/main/bootstrap.bash?nocache=$(date +%s)" | bash
```

This repo is **being slimmed**, not sunset. The crown-jewel SSH/gh auth dance stays; ansible invocation is being removed in favor of `chezmoi apply` running `run_onchange_*.sh.tmpl` scripts directly.

**Branches:**
- `main` — refactor target
- `archive/pre-2026-refactor` — preservation snapshot

**Future:** Once ansible invocation is gone, repo will likely be renamed (e.g., `workstation-bootstrap`) or folded into the dotfiles repo as `dotfiles/bootstrap/`.

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

- [ ] Add Claude Code provisioning block after the SSH/gh dance (post known_hosts seeding, pre chezmoi apply): install `claude` binary (curl installer or npm), run `claude login`. Plugin replay then happens automatically via chezmoi `run_onchange_install-claude-plugins.sh.tmpl`.
- [x] Delete desktop-polish cruft (80 lines) — done 2026-05-13.
- [x] Drop ansible invocation + ansible clone/sync + `SKIP_ANSIBLE` arg-parser — done 2026-05-13 on the strength of all four `run_onchange_*` scripts existing in chezmoi. Bootstrap is now chezmoi-only; awaiting clean-VM smoke test.
- [ ] Verify Darwin branch (L69-79 region) when Macbook Neo arrives. Note Apple Silicon `/opt/homebrew` vs Intel `/usr/local` brew path divergence.

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
