![kanshi_gui banner](https://raw.githubusercontent.com/nurkert/kanshi_gui/main/assets/banner.png)

**kanshi_gui** is a graphical user interface based on Flutter for managing dynamic monitor setups under Wayland. It simplifies the creation and switching between different display profiles and thus extends/simplifies the functionality of the [kanshi](https://sr.ht/~emersion/kanshi/) tool.

![kanshi_gui banner](https://raw.githubusercontent.com/nurkert/kanshi_gui/main/assets/example.png)

Currently, _kanshi_gui does not claim to map all functionalities of kanshi_ in a graphical environment. It was originally only intended to be a helpful tool for configuring new monitor setups quickly, easily and precisely.

## Features

- **Live apply** — drag, scale or rotate a monitor and the change goes into the running compositor immediately. No more "save & restart" for every tweak.
- **Safety net** — mode changes and output-disables come with a 15-second countdown banner; "Keep" cements them, otherwise the layout reverts itself.
- **Hard block** against locking yourself out: the last enabled output cannot be disabled.
- **Smart snapping** — Figma-style cyan guide lines, corner alignment (top / bottom / center) when an edge snaps, and a learning alignment magnet that backs off after you escape it twice in one drag.
- **Hotplug aware** — connect or disconnect a monitor and the app refreshes itself instantly.
- **Identify displays** — a light-bulb button flashes pulsing numbers on each tile so you know which one is which.
- **First-run wizard** — picks up your detected layout and proposes a sensible profile name.
- **Profile management** — create, rename, delete; switch with one click.
- **kanshictl-aware reload** — uses `kanshictl reload` when available so re-applying a profile no longer flickers the screen.
- **Compositor-agnostic** — auto-selects between `swaymsg` (Sway, full feature set) and `wlr-randr` (Hyprland / Wayfire / niri / other wlroots-style compositors) at startup; falls back to an offline editor when neither is installed.

> **Heads-up:** the rich features (mirror onto another output, identify-banners on each screen, automatic workspace placement across monitors, sway-accent theming) are **Sway-specific** because they rely on `swaymsg` IPC, `swaynag`, and `wl-mirror`. On non-Sway compositors (Hyprland, niri, river, …) the GUI gracefully degrades to position / mode / scale / rotate / enable-disable, which is what most users actually need.

## Getting Started

### Prerequisites

- 	**Wayland session**: This application is designed specifically for Wayland compositors. The level of support depends on which output-control tool is available — see the matrix below.

	| Compositor | Backend | Live apply | Mirror / identify / workspace placement |
	|------------|---------|:---:|:---:|
	| Sway | `swaymsg` | ✅ | ✅ (default) |
	| Hyprland / Wayfire / niri / other wlroots-style | `wlr-randr` | ✅ | ❌ (basic layout only) |
	| GNOME on Wayland | _not yet supported_ | ❌ (offline editor only) | ❌ |

	The app auto-detects the backend at startup. Sway requires a *running* sway IPC socket (`SWAYSOCK` env var pointing at an existing path) — having `swaymsg` installed is not enough, so non-Sway sessions with the sway tooling around still land on the wlr-randr fallback. If neither `swaymsg` nor `wlr-randr` is installed, kanshi_gui still works as an offline profile editor (toggle/mode actions are disabled).

	Non-Sway compositor support is community-driven: open an issue with reproduction steps if something doesn't behave the way it should.
- [**kanshi**](https://sr.ht/~emersion/kanshi/): Ensure [kanshi](https://sr.ht/~emersion/kanshi/) is installed and configured (with a working `~/.config/kanshi/config` file) on your system. 
- **Flutter SDK**: Required to build the GUI yourself - [(Installation Guide)](https://flutter.dev/docs/get-started/install)

### Installation

1. **Install from the APT repository (recommended)**:
```bash
curl -fsSL https://apt.nurkert.de/install/kanshi-gui | sudo sh
```

2. **Build it yourself**:
```bash
git clone https://github.com/nurkert/kanshi_gui
cd kanshi_gui
flutter build linux
```
   The resulting binary will be located at:
```bash
build/linux/x64/release/bundle/kanshi_gui
```
   To make kanshi_gui globally accessible from your terminal (e.g., just by typing kanshi_gui), you can do one of the following:
   - **Option 1**: Create a symbolic link
```bash
sudo ln -s "$(pwd)/build/linux/x64/release/bundle/kanshi_gui" /usr/local/bin/kanshi_gui
```
   - **Option 2**: Copy the binary into a directory in your $PATH
```bash
sudo cp build/linux/x64/release/bundle/kanshi_gui /usr/local/bin/
```
   Now you can launch the application simply by typing:
```bash
kanshi_gui
```

3. **Create a Debian package**:
   The repository ships with a helper script that bundles the application
   into a `.deb` file. Run it from the project root and then install the
   resulting package with `dpkg`:
```bash
./scripts/build_deb.sh
sudo dpkg -i build/kanshi-gui_*_$(dpkg --print-architecture).deb
```
   After installation the `kanshi_gui` command is available globally. To
   remove the package again use:
```bash
sudo dpkg -r kanshi_gui
```

# License

Copyright (C) 2025 nurkert - This project is licensed under the terms of the [GNU General Public License v3.0](LICENSE).
