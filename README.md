![kanshi_gui banner](https://raw.githubusercontent.com/nurkert/kanshi_gui/main/assets/banner.png)

**kanshi_gui** is a graphical user interface based on Flutter for managing dynamic monitor setups under Wayland. It simplifies the creation and switching between different display profiles and thus extends/simplifies the functionality of the [kanshi](https://sr.ht/~emersion/kanshi/) tool.

![kanshi_gui banner](https://raw.githubusercontent.com/nurkert/kanshi_gui/main/assets/example.png)

Currently, _kanshi_gui does not claim to map all functionalities of kanshi_ in a graphical environment. It was originally only intended to be a helpful tool for configuring new monitor setups quickly, easily and precisely.

## Features

- **Display management**: Move, rotate and arrange displays as desired with simple drag and drop
- **Profile Management**: Create, edit, and delete display profiles with ease.
- **Automatic Detection**: Recognizes connected displays and adjusts configurations accordingly.
- **User-Friendly Interface**: Intuitive design for seamless navigation and configuration.
- **Save automatically**: After each graphical change, this is immediately and automatically stored in the config. (_A restart of kanshi is still required to actually apply the new config_)

## Getting Started

### Prerequisites

- 	**Wayland session**: This application is designed specifically for Wayland compositors. Make sure you are running a Wayland session (e.g., with Sway, Hyprland, Wayfire, GNOME on Wayland, etc.).
- [**kanshi**](https://sr.ht/~emersion/kanshi/): Ensure [kanshi](https://sr.ht/~emersion/kanshi/) is installed and configured (with a working `~/.config/kanshi/config` file) on your system. 
- **Flutter SDK**: Required to build the GUI yourself - [(Installation Guide)](https://flutter.dev/docs/get-started/install)

### Installation

1. **Install from the APT repository (recommended)**:
   ```bash
   # Add Nurkert APT key
   sudo mkdir -p /usr/share/keyrings
   curl -fsSL https://apt.nurkert.de/KEY.gpg \
     | sudo gpg --dearmor -o /usr/share/keyrings/nurkert-archive-keyring.gpg

   # Add repository
   echo "deb [signed-by=/usr/share/keyrings/nurkert-archive-keyring.gpg] https://apt.nurkert.de stable main" \
     | sudo tee /etc/apt/sources.list.d/nurkert.list

   # Install kanshi-gui (pulls kanshi automatically)
   sudo apt update
   sudo apt install kanshi-gui
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
   ```
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
