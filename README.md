# omarchy-on-cachyos-nvidia

- UPDATE 7-November-2026: The installer now targets **Omarchy 4.x** (packaged releases from `omacom/omarchy`). Omarchy 3.x is no longer supported by this branch.
- UPDATE 20-May-2026: The install script now includes interactive version selection for choosing between Stable releases and Bleeding Edge.
- UPDATE 1-October-2025: The install script has been updated to support Omarchy 3.0+ out of the box.

> **Status: untested end-to-end on Omarchy 4.x.** The 4.x port was written against the Omarchy v4.5.0 sources and checked statically (`bash -n`, `shellcheck`). It has not yet been run on a real CachyOS machine. Back up your system first.

## 1. Introduction

This project installs DHH's Omarchy on top of an existing CachyOS system, with NVIDIA kept on the proprietary 580xx driver. Omarchy is an opinionated Hyprland desktop; CachyOS is a performance-optimized Arch Linux distribution.

Omarchy 4.x is no longer a set of scripts copied to `~/.local/share/omarchy`. It ships as pacman packages (`omarchy-keyring`, `omarchy-settings`, `omarchy`) from its own `[omarchy]` repository and lives in `/usr/share/omarchy`. This installer adds that repository, installs the packages, and runs Omarchy's own setup steps with the parts that would damage a CachyOS install switched off.

## 2. What the installer does

`bin/install-omarchy-on-cachyos.sh` runs as your normal user and uses `sudo` for the root parts:

1. Lets you pick a stable Omarchy 4.x release (newest by default; release candidates are hidden) and clones it next to this repository (`../omarchy`). An existing clone can be kept; it is checked to be a 4.x tree.
2. Checks preconditions: CachyOS repositories present, x86_64, the Limine boot stack installed, and no non-SDDM display manager in the way.
3. Backs up `/etc/pacman.conf` and the files Omarchy overwrites (see section 5).
4. Adds `NoExtract` entries to `/etc/pacman.conf` so the conflicting Omarchy files below are never installed, then adds the `[omarchy]` stable repository **after** the CachyOS and Arch repositories.
5. Installs `omarchy-keyring`, `omarchy-settings` and `omarchy` (with a full `pacman -Syu`), then Omarchy's default package list minus the packages that conflict with CachyOS.
6. Runs Omarchy's system setup (`omarchy-apply-system`) from the cloned tree, with three changes: no pacman.conf/mirrorlist rewrite, no snapper reconfiguration, and NVIDIA handled by CachyOS's `chwd`.
7. Copies missing files from `/etc/skel` into your home (existing files are never overwritten) and runs Omarchy's user setup (`omarchy-provision-user`).
8. Writes NVIDIA session variables and adds `mise` activation to fish.

It does not install CachyOS, partition or encrypt disks, install a boot loader, or install a display manager.

## 3. Choices made where CachyOS and Omarchy differ

1. **Repository order:** `[omarchy]` is appended after the CachyOS and Arch repositories. pacman takes a package from the first repository that has it, so CachyOS/Arch builds win. Trade-off: Omarchy's own builds of packages that also exist upstream (for example `quickshell`, `walker`, `yay`, `limine-*`, `ghostty`, the NVIDIA 580xx packages) are not used. Omarchy itself puts `[omarchy]` first. If the Omarchy shell misbehaves, install its build explicitly, e.g. `sudo pacman -S omarchy/quickshell` (pacman will then keep it until the CachyOS/Arch version is newer).
2. **Updates:** Omarchy's pacman hook that blocks `pacman -Syu` is not installed (NoExtract). Both `omarchy update` and `sudo pacman -Syu` / `yay -Syu` work.
3. **Boot:** CachyOS keeps its kernel, boot loader configuration and initramfs `HOOKS`. Omarchy's mkinitcpio and limine-entry-tool drop-ins are never installed (no UKI switch, no Omarchy boot entries, no Plymouth hook). The `plymouth` package is still installed because `omarchy-settings` depends on it, but it stays inactive.
4. **Snapper:** CachyOS's snapper configuration is kept; Omarchy's `config/snapper.sh` step is skipped.
5. **Shell:** Fish stays the interactive shell. Omarchy configures bash and the Hyprland session; this installer adds `mise activate fish | source` (guarded by `command -q mise`) to `~/.config/fish/config.fish`.
6. **TLDR:** CachyOS's tealdeer is kept; `tldr` is removed from the package list.
7. **Power profiles:** CachyOS's stock `power-profiles-daemon` is kept; Omarchy's ARM-oriented fork is removed from the package list.
8. **Login:** Omarchy 4.x logs in through SDDM. `/etc/sddm.conf` (CachyOS) is moved to the backup directory because it is read after `/etc/sddm.conf.d/` and would override Omarchy's SDDM theme and Wayland settings. Pick **Omarchy (Hyprland uwsm)** at the login screen.
9. **Networking:** Omarchy 4.x uses NetworkManager with its default wpa_supplicant backend, like CachyOS. The old 3.x "switch to iwd" patch is gone (it would now break Wi-Fi).
10. **NVIDIA:** see section 6.

## 4. Pre-requisites

Install CachyOS first (https://cachyos.org) with:

1. **Boot loader: Limine.** Required. On x86_64 the `omarchy` package depends on `limine`, `limine-mkinitcpio-hook`, `limine-snapper-sync` and `snapper`. The installer refuses to run if Limine is not installed, because `limine-mkinitcpio-hook` takes over kernel/initramfs installation and must not land on a systemd-boot, GRUB or rEFInd system. If `limine-mkinitcpio-hook` or `limine-snapper-sync` are missing, it asks before letting pacman add them.
2. **File system: BTRFS with Snapper** (CachyOS default).
3. **Shell: Fish** (CachyOS default).
4. **Desktop:** a minimal install or CachyOS's Hyprland edition (which installs SDDM). Do not install GNOME or KDE. If another display manager is enabled, the installer offers to disable it so SDDM can be enabled.
5. A user account with `sudo` rights and internet access.

## 5. What is neutralised, and how

**Never installed** (pacman `NoExtract` in `/etc/pacman.conf` `[options]`, inside a `# BEGIN/END omarchy-on-cachyos NoExtract` block; survives package updates):

| File | Why |
| --- | --- |
| `/etc/mkinitcpio.conf.d/00-omarchy-hooks.conf` | Replaces the whole `HOOKS` array (plymouth, encrypt, btrfs-overlayfs). |
| `/etc/mkinitcpio.conf.d/omarchy_hooks.conf` | Rewrites `HOOKS` (drops `kms` on NVIDIA-only machines) and `FILES`. |
| `/etc/limine-entry-tool.d/omarchy-defaults.conf` | Omarchy kernel command line, boot order and entry names. |
| `/etc/limine-entry-tool.d/omarchy-uki.conf` | Switches Limine to unified kernel images. |
| `/usr/share/libalpm/hooks/00-omarchy-update-guard.hook` | Aborts every direct `pacman -Syu` / `yay -Syu`. |

The install paths come from Omarchy's packaging (`omarchy-settings` copies the repository `etc/` tree to `/etc`; `omarchy` installs the hook into `/usr/share/libalpm/hooks/`).

**Skipped setup steps** (removed from the cloned tree only, never from `/usr/share/omarchy`):

- `install/post-install/pacman.sh` — would overwrite `/etc/pacman.conf` and the mirrorlist, dropping the CachyOS repositories.
- `install/config/snapper.sh` — would overwrite the snapper root configuration.
- `install/hardware/nvidia.sh` — replaced by this repository's `bin/nvidia.sh`.

**Overwritten anyway (accepted):** `omarchy-settings` copies its own versions of `/etc/os-release`, `/etc/nsswitch.conf`, `/etc/security/faillock.conf`, `/etc/plymouth/plymouthd.conf`, `/etc/skel/.bashrc` and some CUPS files on every install and upgrade, from a package script that `NoExtract` cannot stop. Your system will report itself as Omarchy in `/etc/os-release`. The CachyOS versions are saved in the backup directory. Whether CachyOS tools that read `/etc/os-release` behave differently afterwards has not been verified.

## 6. NVIDIA

CachyOS and Omarchy would otherwise install the newer open-kernel-module drivers. This setup pins the **proprietary 580xx** series through CachyOS's `chwd`, to avoid known problems with hardware video decoding, Electron apps and browser flickering.

During system setup, `bin/nvidia.sh`:

1. Adds your GPU's PCI ID to `/var/lib/chwd/ids/nvidia-580.ids` so chwd selects the 580 profile.
2. If the 580xx driver is not already active, removes the open-module packages and runs `chwd -a`, then checks that 580xx is active. If not, setup stops with an error: **do not reboot** until the driver is fixed.
3. Installs `libva-nvidia-driver` and `libva-utils`, and writes `/etc/modprobe.d/omarchy-on-cachyos-nvidia.conf` (`nvidia_drm modeset=1`). No CachyOS file is overwritten and the initramfs module list is left to CachyOS.

After setup, when NVIDIA drives the display, `~/.config/uwsm/env.d/90-omarchy-on-cachyos-nvidia` sets `LIBVA_DRIVER_NAME`, `GBM_BACKEND`, `__GLX_VENDOR_LIBRARY_NAME`, `MOZ_DISABLE_RDD_SANDBOX` and `CUDA_DISABLE_PERF_BOOST` for the Hyprland session. On hybrid graphics (display on the integrated GPU) this file is not written.

To enable hardware video decode via NVDEC in Chromium:

1. Add `--enable-features=VaapiOnNvidiaGPUs` to `~/.config/chromium-flags.conf`.
2. Install the [enhanced-h264ify extension](https://chromewebstore.google.com/detail/enhanced-h264ify/omkfmpieigblcllmkgbflkikinpkodlk) and disable **VP8** and **AV1**.

To fully enable hardware acceleration in Firefox, install the [enhanced-h264ify add-on](https://addons.mozilla.org/en-US/firefox/addon/enhanced-h264ify/), disable **VP8** and **AV1**, and add to your `user.js`:

```js
// FORCE NVIDIA HARDWARE ACCELERATION
user_pref("media.hardware-video-decoding.force-enabled", true);
user_pref("media.hardware-video-encoding.force-enabled", true);
user_pref("layers.acceleration.force-enabled", true);
user_pref("webgl.force-enabled", true);
user_pref("media.ffmpeg.vaapi.enabled", true);
user_pref("media.rdd-ffmpeg.enabled", true);
user_pref("media.av1.enabled", true);
user_pref("widget.dmabuf.force-enabled", true);
user_pref("gfx.x11-egl.force-enabled", true);
```

## 7. Installation

```bash
# Clone the repository
git clone https://github.com/cesarcamilov1/omarchy-on-cachyos-nvidia.git

# Navigate to the scripts
cd omarchy-on-cachyos-nvidia/bin

# Run the installer as your normal user (not root)
bash install-omarchy-on-cachyos.sh
```

The Omarchy source is cloned to `../omarchy` next to this repository. pacman runs interactively, so read and answer its prompts (package conflicts, for example `ttf-jetbrains-mono-nerd` vs `ttf-jetbrains-mono-nerd-basic`). Setup steps log to `/var/log/omarchy-install.log`.

When it finishes, review the output for errors, reboot, and choose **Omarchy (Hyprland uwsm)** in SDDM.

**Note:** review the scripts before running them so you know what will change on your system.

## 8. Known risks

- Untested end-to-end on Omarchy 4.x (see the status note at the top).
- Running the setup steps of an Omarchy release other than the one the repository currently serves is not supported; the installer warns when the cloned tag and the `omarchy` package version differ.
- Because `[omarchy]` comes last, some Omarchy features may expect newer builds than CachyOS/Arch ship (see section 3, item 1).
- `pacman` may stop on file conflicts with files CachyOS already has in `/etc`. Resolve them by hand and re-run the installer (pacman, NoExtract, repository and patch steps are idempotent; Omarchy's own setup steps run again).
- If you use `mise` to install Python, the stock `powerprofilesctl` (`#!/usr/bin/env python3`) may pick up that Python. Omarchy patches the shebang in its own upgrade tool; this installer does not.
- An existing `~/.config/hypr` without `hyprland.lua` (CachyOS Hyprland edition) is moved to `~/.local/state/omarchy-on-cachyos/backup-<timestamp>/hypr`.

## 9. How to revert

Backups live in `/var/backups/omarchy-on-cachyos/<timestamp>/`, and `/etc/pacman.conf` is also saved as `/etc/pacman.conf.omarchy-on-cachyos-<timestamp>.bak`.

1. Restore pacman's configuration:
   ```bash
   sudo cp /etc/pacman.conf.omarchy-on-cachyos-<timestamp>.bak /etc/pacman.conf
   ```
   (or remove the `[omarchy]` section and the `# BEGIN/END omarchy-on-cachyos NoExtract` block by hand).
2. Remove the Omarchy packages: `sudo pacman -Rns omarchy omarchy-settings omarchy-keyring` (review what else pacman offers to remove).
3. Restore `/etc/os-release` — on CachyOS it is normally a symlink: `sudo ln -sf ../usr/lib/os-release /etc/os-release` (the original target is recorded in `etc_os-release.symlink-target` in the backup directory). Restore `/etc/nsswitch.conf`, `/etc/security/faillock.conf`, `/etc/plymouth/plymouthd.conf` and `/etc/sddm.conf` from the backup directory if needed.
4. Remove `/etc/modprobe.d/omarchy-on-cachyos-nvidia.conf` and `~/.config/uwsm/env.d/90-omarchy-on-cachyos-nvidia` if you no longer want them.

## 10. Statement of Lack of Warranty

THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Use this script at your own risk. Always backup your system and important data before running installation scripts.

## 11. How to Contribute

We welcome contributions to improve this project! Here's how you can help:

1. **Fork the Repository**: Click the "Fork" button on GitHub to create your own copy
2. **Create a Feature Branch**: `git checkout -b feature/your-feature-name`
3. **Make Your Changes**: Implement your improvements or fixes
4. **Commit Your Changes**: `git commit -m "Add descriptive commit message"`
5. **Push to Your Fork**: `git push origin feature/your-feature-name`
6. **Open a Pull Request**: Submit a PR with a clear description of your changes

### Contribution Guidelines
- Test your changes thoroughly on CachyOS before submitting
- Follow existing code style and conventions
- Update documentation if adding new features
- Report bugs using GitHub Issues
