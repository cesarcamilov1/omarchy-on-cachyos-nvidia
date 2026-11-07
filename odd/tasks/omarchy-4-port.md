# Feature: Omarchy 4.x support on CachyOS (omarchy-4-port)

Locator: `odd/tasks/omarchy-4-port.md` · Engram mirror: `odd/omarchy-4-port/tasks`
Branch: `feat/omarchy-4-support` (base `ae225eb` on `main`)

## Objective
Install Omarchy v4.5.0 (latest stable 4.x) on top of an existing CachyOS + NVIDIA system using this repo's installer.

## Problem
The installer targets the Omarchy 3.x layout (root `install.sh`, `~/.local/share/omarchy`, patchable step scripts).
Omarchy 4.x (repo moved to `omacom/omarchy`) ships as pacman packages (`omarchy`, `omarchy-settings`, `omarchy-keyring`)
with `OMARCHY_PATH=/usr/share/omarchy`; orchestration lives in its ISO. Root entry points are
`bin/omarchy-apply-system --install-user USER --first-install` (root) and `bin/omarchy-provision-user --first-install` (user).
Running the 3.x installer against 4.x fails (`install.sh` missing) and several 4.x defaults conflict with CachyOS.

## Why
User explicitly chose 4.5.0 after being told about the risks (2026-11-06).

## Constraints
- Must not remove CachyOS repos, kernel (`linux-cachyos`), boot loader, or initramfs HOOKS.
- Must keep `pacman -Syu` / `yay -Syu` usable (neutralise Omarchy's update guard hook).
- Conflict protection must survive package updates (use pacman `NoExtract`, not one-off file deletes).
- NVIDIA stays on proprietary 580xx via `chwd`.
- Fish remains the interactive shell.
- Cannot be executed from the author's macOS machine: verification is static (`bash -n`, shellcheck if available) plus evidence from Omarchy v4.5.0 sources. End-to-end install is untested until the user runs it on CachyOS.

## Known 4.x conflicts (evidence: omarchy v4.5.0 @ ac2690c)
- `etc/mkinitcpio.conf.d/00-omarchy-hooks.conf` replaces HOOKS.
- `default/libalpm/hooks/00-omarchy-update-guard.hook` + `bin/omarchy-update-pacman-guard:8` blocks direct `-Su`.
- `install/post-install/pacman.sh:25` → `bin/omarchy-apply-pacman` overwrites `/etc/pacman.conf` + mirrorlist.
- `install/config/snapper.sh:17-24` overwrites snapper root config, enables limine-snapper-sync.
- `install/hardware/nvidia.sh` installs nvidia-open/580xx dkms itself (conflicts with chwd).
- `etc/limine-entry-tool.d/omarchy-defaults.conf` (only matters if CachyOS uses limine-entry-tool).
- `omarchy-other.packages` lists `linux-omarchy`, limine*, nvidia rows.
- Repo URL must be `https://pkgs.omarchy.org/stable/$arch` (current script lacks `/stable/`).

## Tasks
- [x] T1 — fetch-omarchy.sh: list stable 4.x tags (no rc) from `omacom/omarchy`, clone the chosen one into `$OMARCHY_DIR`.
  - Route: inline in writer. Evidence: `bash -n` OK, `shellcheck` clean; tag filter `^v4\.[0-9]+\.[0-9]+$` checked against live `git ls-remote` output (drops v4.5.0-rc*, v4.0.0-beta3, v3.x). Kept-dir path still `exit 0`; installer validates the tree (T4).
- [x] T2 — pacman setup: correct `[omarchy]` stable repo, keyring, `NoExtract` for conflicting package files, keep CachyOS repos.
  - Route: delegated writer (installer rewrite). NoExtract installed paths PROVEN: omarchy-pkgs `pkgbuilds/omarchy-settings/PKGBUILD` `cp -a etc/. "$pkgdir/etc/"` and docs/file-layout.md (`etc/** -> /etc/**`); `pkgbuilds/omarchy/PKGBUILD` installs `00-omarchy-update-guard.hook` to `/usr/share/libalpm/hooks/`. List: `etc/mkinitcpio.conf.d/00-omarchy-hooks.conf`, `etc/mkinitcpio.conf.d/omarchy_hooks.conf` (rewrites HOOKS, drops kms on NVIDIA-only), `etc/limine-entry-tool.d/omarchy-defaults.conf`, `etc/limine-entry-tool.d/omarchy-uki.conf` (ENABLE_UKI=yes), `usr/share/libalpm/hooks/00-omarchy-update-guard.hook`. Marked block inserted right after `[options]`, replaced on re-run; `[omarchy]` section removed and re-appended last (no SigLevel line, global `Required DatabaseOptional`, key recv+lsign first). Verified with `pacman-conf`. awk transforms tested twice on a sample CachyOS-style pacman.conf: idempotent, old wrong `[omarchy]` URL replaced.
  - NOT neutralisable by NoExtract (scriptlet `cp -f` in omarchy-settings.install `_etc_overrides_apply`): `/etc/os-release`, `/etc/nsswitch.conf`, `/etc/security/faillock.conf`, `/etc/plymouth/plymouthd.conf`, `/etc/skel/.bashrc`, cups files. Backed up + documented as accepted.
- [x] T3 — package install: `omarchy-keyring omarchy-settings omarchy` + filtered base package list (no tldr, linux-omarchy, limine*, nvidia rows, iwd).
  - NEW CONFLICT FOUND: published `omarchy 4.5.0-3` (repo DB `pkgs.omarchy.org/stable/x86_64/omarchy.db`) hard-depends on `limine limine-mkinitcpio-hook limine-snapper-sync snapper` (PKGBUILD `depends_x86_64`). Deviation: installer aborts unless `limine` is installed, and asks before pulling the rest. `plymouth` and `sddm` are hard deps (omarchy-settings / omarchy) and cannot be filtered; plymouth stays inert without the NoExtract'd HOOKS/cmdline drop-ins.
  - Filter evidence: v4.5.0 base list (162 entries) loses only `tldr` (tealdeer) and `omarchy-power-profiles-daemon` (ARM fix per list comment; conflicts `power-profiles-daemon`); guard regex for linux-omarchy*/limine*/nvidia*/*-dkms/iwd matches nothing today. Stock `power-profiles-daemon` added when unsatisfied (enable-services.sh enables it). Packages absent from sync DBs are skipped with a warning. `omarchy-other.packages` (ISO list) is not installed. pacman runs interactively (no --noconfirm) so conflict prompts reach the user; old yay bootstrap removed (yay comes from the base list via pacman).
  - Version guard: clone tag vs `pacman -Sddp --print-format %v omarchy`; mismatch asks.
- [x] T4 — step patches on the cloned tree + run `omarchy-apply-system` / `omarchy-provision-user` with `OMARCHY_PATH` pointing to it; drop obsolete 3.x patches.
  - Clone patches (sed by path, verified with grep/cmp): drop `post-install/pacman.sh`, drop `config/snapper.sh`, replace `install/hardware/nvidia.sh`. Tree validated as 4.x before use (kept-dir path).
  - `sudo env OMARCHY_PATH=$OMARCHY_DIR OMARCHY_INSTALL=... omarchy-apply-system --install-user $USER --first-install`; override honoured at v4.5.0 `bin/omarchy-apply-system:83-86` and `bin/omarchy-apply-hardware:74-77`; only `install/config/ssh-command-path.sh` comment and `install/user/xcompose.sh` (user side) hard-code /usr/share/omarchy.
  - Deviation: `omarchy-provision-user --first-install` runs from the installed package (OMARCHY_PATH unset), because it symlinks agent skills into `$OMARCHY_PATH` (`bin/omarchy-provision-user:88-96`) and user steps need no patch.
  - Added (evidence: docs/file-layout.md "Seed"; provision-user copies no ~/.config): seed $HOME from /etc/skel with `cp --update=none`; existing ~/.config/hypr without hyprland.lua is moved to a backup first.
  - Added pre-checks: display-manager.service owned by non-SDDM unit (enable-services.sh would fail); btrfs warning.
  - /etc/sddm.conf moved to backup (not deleted); justification is SDDM config precedence (sddm.conf(5)), not Omarchy source.
  - Dropped 3.x patches: omarchy-update-restart seds (4.x uses `pacman -Qo` on the kernel), ai-skill ln, plymouth/limine-snapper/alt-bootloaders lines (gone from login/all.sh), iwd network patch (4.x NM uses wpa_supplicant; patch would break Wi-Fi), walker pin, uwsm/env mise sed.
- [x] T5 — nvidia.sh as a 4.x root step (chwd 580xx), user env moved to a user-context step; fish mise activation.
  - Part 1 done (root leaf `bin/nvidia.sh`): sourced by `run_logged` (v4.5.0 `install/helpers/logging.sh` run_logged: `bash -eE -c 'source "$1"'`, stdin `/dev/null`), so no sudo/prompts; logic in a function so it also runs standalone. Pins GPU ID in chwd 580 ID list, removes open-module packages and runs `chwd -a` only when 580xx is not active, then verifies 580xx and fails loudly otherwise (fixes old hole: after removing open modules, leftover `nvidia-utils` made the old script skip `chwd -a`). Only a separate `/etc/modprobe.d/omarchy-on-cachyos-nvidia.conf`; deviation: no mkinitcpio MODULES drop-in (initramfs rebuild path under limine-mkinitcpio-hook unverified; CachyOS keeps early-KMS). `bash -n` OK, `shellcheck` clean.
  - Part 2 done in installer: `~/.config/uwsm/env.d/90-omarchy-on-cachyos-nvidia` (location per v4.5.0 `default/uwsm/env.d/10-omarchy` comment), skipped on hybrid graphics via `omarchy-hw-nvidia-display` (v4.5.0 default/hypr/nvidia.lua rationale); fish `mise activate fish | source` guarded by `command -q mise`, idempotent marker.
- [x] T6 — README update for 4.x flow and risks.
  - Structural readback only (passive doc). Covers 4.x flow, Limine prerequisite, repo-order trade-off, NoExtract table with packaging evidence, accepted scriptlet overwrites, NVIDIA, risks, revert steps, fork clone URL.

## Route
Delegated direct: one bounded writer (2+ non-trivial files; research of omarchy-pkgs file lists prepares the write).

## Acceptance
- `bash -n` passes on every script; shellcheck clean or justified.
- Each conflict above is neutralised by a durable mechanism or explicitly documented as accepted.
- Every claim about Omarchy 4.5.0 paths is backed by the v4.5.0 source.

## Verification commands
- `bash -n bin/*.sh`
- `shellcheck bin/*.sh` (if available)

## Progress
- 2026-11-06: exploration done (map of 3.x→4.x changes). Branch created. No source writes yet.
- 2026-11-07: T1 `a000f84` (fetch), T5 root leaf `579600a` (nvidia.sh), T2+T3+T4+T5 user half `5db799b` (installer; one file rewritten as a whole, so not split), T6 README in the docs commit that records this line.
- Verification: `bash -n bin/*.sh` OK; `shellcheck bin/*.sh` (0.11 via brew) clean, one justified `SC2016` disable for the literal `$arch`.

## Unproven assumptions (check on the real machine)
- `chwd -a` with the patched `/var/lib/chwd/ids/nvidia-580.ids` selects/installs 580xx (logic inherited from the old script; chwd flags not verified here).
- CachyOS Limine installs use `limine-mkinitcpio-hook`/`limine-snapper-sync` names (or provides) that satisfy omarchy's deps.
- uwsm reads `~/.config/uwsm/env.d/*` (asserted by Omarchy's 10-omarchy comment, not by uwsm docs here).
- SDDM reads `/etc/sddm.conf` after `/etc/sddm.conf.d/` (sddm.conf(5), not Omarchy source).
- Omarchy's root steps (docker, firewall/ufw, PAM, enable-services) succeed on CachyOS; any failure aborts omarchy-apply-system.
- Effect of Omarchy's `/etc/os-release` on CachyOS tools (chwd, kernel manager) unknown.

## Next step
User runs the installer on a CachyOS (Limine) test machine/VM with a snapshot; report failures from `/var/log/omarchy-install.log`. Push/PR remain user decisions.
