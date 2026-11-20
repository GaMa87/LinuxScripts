# appimage-install

Automatic AppImage integrator for **Linux** — tested on **Omarchy / Arch**, and designed to work out of the box on **Ubuntu / Debian**, **Fedora / Ultramarine**, **openSUSE**, and any XDG-compliant desktop environment (Hyprland, GNOME, KDE Plasma, XFCE, Sway, Cosmic, etc.).

Whenever you download an `.AppImage`, `appimage-install` automatically:

1. Moves it to `~/Applications/<AppName>.AppImage` **without the version or architecture suffix** (`chmod +x`)
2. Creates a CLI symlink in `~/.local/bin/<slug>` so you can launch it from the terminal
3. Extracts and installs its `.desktop` file, icons, and MIME definitions into `~/.local/share/`
4. Refreshes desktop, icon, and MIME caches so it appears immediately in your app launcher & dock like a natively installed app

Downloading a newer version of the same app later **updates it cleanly in-place**.

---

## Features

- **Version-free filenames** — Strips version numbers, architectures, OS tags, and build IDs (or uses the embedded `.desktop` `Name=` when available).
- **Zero Python dependencies** — Uses Python 3 standard library only (Python 3.8+).
- **Automatic Downloads watcher** — Lightweight `systemd --user` service using `inotifywait` that waits for browser downloads (`.part`, `.crdownload`, `.tmp`) to finish and stabilize, validates the ELF header, installs automatically, and sends a desktop notification (`notify-send`).
- **Smart `.desktop` integration** — Preserves `Name`, `Comment`, `Categories`, `MimeType`, `Keywords`, `StartupWMClass`, `[Desktop Action ...]` entries, and field codes (`%F`, `%U`), while updating `Exec=` and `TryExec=`.
- **Automatic FUSE2 fallback** — Detects older Type 2 AppImages that require `libfuse.so.2`. If `libfuse.so.2` is not installed on your system, it automatically wraps the `.desktop` `Exec=` line with `env APPIMAGE_EXTRACT_AND_RUN=1` so the app still launches without errors.
- **Multi-resolution icons & MIME types** — Installs all hicolor icon sizes (`32x32`, `128x128`, `256x256`, `scalable`, `.DirIcon`, etc.) and any bundled MIME XML files.
- **Clean uninstall & tracking** — Stores an install manifest in `~/.local/share/appimage-installer/registry.json` so `--remove` removes every associated file cleanly without leaving orphans.
- **Respects XDG localized Downloads folder** — Uses `xdg-user-dir DOWNLOAD` (falling back to `~/Downloads`).

---

## Requirements

- **Required:** `python3` (3.8+)
- **Required for auto-watching (`--watch` / systemd service):** `inotify-tools`
- **Optional (usually pre-installed on desktop distros):**
  - `desktop-file-utils` (`update-desktop-database`)
  - `gtk-update-icon-cache` (or `gtk4-update-icon-cache`)
  - `shared-mime-info` (`update-mime-database`)
  - `libnotify` / `libnotify-bin` (`notify-send` for desktop notifications)
  - FUSE2 (`fuse2` / `libfuse2t64` / `fuse-libs`) — *not strictly required* because of the automatic `APPIMAGE_EXTRACT_AND_RUN=1` fallback, but installing it gives faster startup on older Type 2 AppImages.

### Install Prerequisites by Distro

**Arch Linux / Omarchy:**
```bash
sudo pacman -S inotify-tools
# or on Omarchy:
omarchy pkg add inotify-tools
```

**Ubuntu / Debian / Pop!_OS / Linux Mint:**
```bash
sudo apt update
sudo apt install inotify-tools libnotify-bin

# Optional (for native FUSE2 mounting of older AppImages):
# Ubuntu 24.04+:
sudo apt install libfuse2t64
# Ubuntu 22.04 / Debian 12:
sudo apt install libfuse2
```

**Fedora / Ultramarine:**
```bash
sudo dnf install inotify-tools libnotify

# Optional (for native FUSE2 mounting of older AppImages):
sudo dnf install fuse-libs
```

**openSUSE:**
```bash
sudo zypper install inotify-tools libnotify-tools
```

---

## Installation

```bash
cd ~/Projects/LinuxScripts/appimage-install
chmod +x install.sh
./install.sh
```

What `install.sh` does:
1. Symlinks `appimage-install` into `~/.local/bin/appimage-install` (so edits in this repo apply immediately).
2. Installs `appimage-watch.service` into `~/.config/systemd/user/`.
3. Enables and starts `appimage-watch.service` under `default.target` (works on GNOME, KDE, Hyprland, Sway, XFCE, etc.).

### Ensure `~/.local/bin` is on `$PATH`

Most distros (Omarchy, Fedora, modern Ubuntu once `~/.local/bin` exists) include `~/.local/bin` in `$PATH` automatically. If `appimage-install` or your installed CLI symlinks are not found after installation, log out and back in, or add this to `~/.bashrc` / `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Uninstalling `appimage-install`

```bash
./install.sh --uninstall
```

This disables/removes the systemd watcher and removes the `~/.local/bin/appimage-install` symlink. Your already-installed AppImages in `~/Applications` are preserved (remove individual apps first with `appimage-install --remove <slug>` if desired).

---

## Usage

```bash
# Install a specific AppImage (moves it into ~/Applications)
appimage-install ~/Downloads/Obsidian-1.7.7.AppImage

# Copy instead of moving (keeps the original file)
appimage-install --copy ~/Downloads/Obsidian-1.7.7.AppImage

# Override the clean app name
appimage-install --name "MyApp" ~/Downloads/something-v2.3-x86_64.AppImage

# Scan ~/Downloads (or a custom folder) and install all .AppImage files found
appimage-install --scan
appimage-install --scan ~/SomeFolder

# List all managed AppImages
appimage-install --list

# Completely uninstall an AppImage (binary, CLI symlink, .desktop, icons, MIME)
appimage-install --remove gall

# Run the directory watcher in the foreground
appimage-install --watch
appimage-install --watch ~/CustomDownloads

# Disable desktop notifications for a run
appimage-install --no-notify ~/Downloads/App.AppImage
```

---

## How Naming & Updates Work

1. If `--name` is provided, that name is used.
2. Otherwise, `appimage-install` reads `Name=` from the AppImage's embedded `.desktop` file (ignoring generic placeholders like `AppRun` or `Application`).
3. If no embedded `.desktop` exists, it cleans the filename by stripping version numbers, architectures, and build tags:

| Downloaded Filename | Installed Binary | CLI Command | Desktop File |
| --- | --- | --- | --- |
| `Gall_0.2.2_amd64.AppImage` | `~/Applications/Gall.AppImage` | `gall` | `gall.desktop` |
| `Obsidian-1.7.7.AppImage` | `~/Applications/Obsidian.AppImage` | `obsidian` | `obsidian.desktop` |
| `pdfcraft-0.21.1-linux-x86_64.AppImage` | `~/Applications/PdfCraft.AppImage` | `pdfcraft` | `pdfcraft.desktop` |
| `Cursor-0.45.14-build-250219-x86_64.AppImage` | `~/Applications/Cursor.AppImage` | `cursor` | `cursor.desktop` |
| `LM-Studio-0.3.9-6-x64.AppImage` | `~/Applications/LM-Studio.AppImage` | `lm-studio` | `lm-studio.desktop` |

**Updating an app:** Simply download the new `.AppImage` into `~/Downloads` (or run `appimage-install <new-file>`). Because the target path has no version, the binary, icons, `.desktop` file, and registry entry are atomically updated in-place.

---

## Managing the Background Watcher

```bash
# Check service status
systemctl --user status appimage-watch.service

# Follow live logs
journalctl --user -u appimage-watch.service -f

# Stop and disable auto-watching
systemctl --user disable --now appimage-watch.service

# Re-enable auto-watching
systemctl --user enable --now appimage-watch.service
```

---

## File Layout

| Artifact | Location |
| --- | --- |
| AppImage binary | `~/Applications/<AppName>.AppImage` |
| CLI symlink | `~/.local/bin/<slug>` |
| Desktop launcher | `~/.local/share/applications/<slug>.desktop` |
| Icons | `~/.local/share/icons/hicolor/<size>/apps/<slug>.{png,svg}` |
| MIME packages | `~/.local/share/mime/packages/<slug>-*.xml` |
| Managed app registry | `~/.local/share/appimage-installer/registry.json` |
| Watcher service unit | `~/.config/systemd/user/appimage-watch.service` |

---

## Troubleshooting

- **App doesn't appear in launcher immediately:** Most launchers (Omarchy/Quickshell, GNOME, KDE) pick up new `.desktop` files within a second. If your launcher caches entries, reopen it or run `update-desktop-database ~/.local/share/applications`.
- **Older AppImage fails when run from terminal (`libfuse.so.2: cannot open shared object file`):** The `.desktop` entry automatically applies `APPIMAGE_EXTRACT_AND_RUN=1` when `libfuse.so.2` is missing, but calling the raw CLI symlink directly from a terminal invokes the AppImage binary directly. Either install FUSE2 (`fuse2` / `libfuse2t64` / `fuse-libs`) or run `APPIMAGE_EXTRACT_AND_RUN=1 <slug>`.
- **Browser download wasn't picked up:** Check `journalctl --user -u appimage-watch.service -n 30` and verify your browser saves into the same directory returned by `xdg-user-dir DOWNLOAD`. If you use a different download directory, edit `ExecStart` in `~/.config/systemd/user/appimage-watch.service` to pass `--watch /path/to/dir`, then run `systemctl --user daemon-reload && systemctl --user restart appimage-watch.service`.
- **Conflict in `~/.local/bin`:** If `~/.local/bin/<slug>` already exists as a regular file or symlink pointing outside `~/Applications`, `appimage-install` will not overwrite it — it logs a warning and still installs the AppImage and `.desktop` entry.
