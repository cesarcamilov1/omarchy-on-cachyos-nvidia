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
- [ ] T2 — pacman setup: correct `[omarchy]` stable repo, keyring, `NoExtract` for conflicting package files, keep CachyOS repos.
- [ ] T3 — package install: `omarchy-keyring omarchy-settings omarchy` + filtered base package list (no tldr, linux-omarchy, limine*, nvidia rows, iwd).
- [ ] T4 — step patches on the cloned tree + run `omarchy-apply-system` / `omarchy-provision-user` with `OMARCHY_PATH` pointing to it; drop obsolete 3.x patches.
- [ ] T5 — nvidia.sh as a 4.x root step (chwd 580xx), user env moved to a user-context step; fish mise activation.
- [ ] T6 — README update for 4.x flow and risks.

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

## Next step
T1–T6 via bounded writer.
