#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="kanshi_gui"
DEB_PACKAGE_NAME="${APP_NAME//_/-}"

command -v dpkg-deb >/dev/null 2>&1 || { echo "dpkg-deb not found (install dpkg-dev)." >&2; exit 1; }

# Determine architectures
BUNDLE_DIR_OVERRIDE=""
ARCH_OVERRIDE=""
DAEMON_BIN_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --daemon-bin)
      if [[ -z ${2:-} ]]; then
        echo "Missing value for --daemon-bin" >&2
        exit 1
      fi
      DAEMON_BIN_OVERRIDE="$2"
      shift 2
      ;;
    --bundle-dir)
      if [[ -z ${2:-} ]]; then
        echo "Missing value for --bundle-dir" >&2
        exit 1
      fi
      BUNDLE_DIR_OVERRIDE="$2"
      shift 2
      ;;
    --arch)
      if [[ -z ${2:-} ]]; then
        echo "Missing value for --arch" >&2
        exit 1
      fi
      ARCH_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

DEB_ARCH=${ARCH_OVERRIDE:-$(dpkg --print-architecture 2>/dev/null || uname -m)}
case "$DEB_ARCH" in
  amd64|x86_64)
    FLUTTER_ARCH="x64"
    TARGET_PLATFORM="linux-x64"
    DEB_ARCH="amd64"
    ;;
  arm64|aarch64)
    FLUTTER_ARCH="arm64"
    TARGET_PLATFORM="linux-arm64"
    DEB_ARCH="arm64"
    ;;
  armhf|armv7l)
    FLUTTER_ARCH="arm"
    TARGET_PLATFORM="linux-arm32"
    DEB_ARCH="armhf"
    ;;
  *)
    echo "Unsupported architecture: $DEB_ARCH" >&2
    exit 1
    ;;
esac

# Flutter cannot cross-compile Linux desktop binaries, so ensure the host
# architecture matches the requested target. This check keeps the script from
# failing deep in the Flutter tool with a less actionable error message.
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  x86_64|amd64)
    HOST_ARCH_NORM="amd64"
    ;;
  aarch64|arm64)
    HOST_ARCH_NORM="arm64"
    ;;
  armv7l|armhf)
    HOST_ARCH_NORM="armhf"
    ;;
  *)
    HOST_ARCH_NORM="$HOST_ARCH"
    ;;
esac

if [[ "$HOST_ARCH_NORM" != "$DEB_ARCH" ]]; then
  if [[ -z "$BUNDLE_DIR_OVERRIDE" ]]; then
    cat <<EOF >&2
Requested architecture ($DEB_ARCH) does not match host architecture ($HOST_ARCH).
Flutter does not support cross-building Linux desktop binaries. Please run the
build on a $DEB_ARCH host (or an emulated container/VM for that architecture)
before packaging the .deb file, or supply --bundle-dir with a prebuilt
Flutter bundle for the target architecture.
EOF
    exit 1
  else
    echo "Using prebuilt Flutter bundle from $BUNDLE_DIR_OVERRIDE for cross-architecture packaging." >&2
  fi
fi

VERSION="$(awk -F': ' '/^version:/{print $2}' "$ROOT_DIR/pubspec.yaml")"
PKG_DIR="$ROOT_DIR/build/debian/${DEB_PACKAGE_NAME}_${VERSION}"

if [[ -n "$BUNDLE_DIR_OVERRIDE" ]]; then
  if [[ ! -d "$BUNDLE_DIR_OVERRIDE" ]]; then
    echo "Provided bundle directory does not exist: $BUNDLE_DIR_OVERRIDE" >&2
    exit 1
  fi
  echo "Skipping Flutter build and using bundle from $BUNDLE_DIR_OVERRIDE"
  BUILD_BUNDLE_DIR="$BUNDLE_DIR_OVERRIDE"
else
  command -v flutter >/dev/null 2>&1 || { echo "flutter not found in PATH." >&2; exit 1; }
  echo "Building Flutter bundle for ${TARGET_PLATFORM}…"
  flutter build linux --target-platform="$TARGET_PLATFORM"
  BUILD_BUNDLE_DIR="$ROOT_DIR/build/linux/$FLUTTER_ARCH/release/bundle"
fi

echo "Assembling Debian package payload…"
rm -rf "$PKG_DIR"
mkdir -p \
  "$PKG_DIR/DEBIAN" \
  "$PKG_DIR/usr/lib/$APP_NAME" \
  "$PKG_DIR/usr/lib/systemd/user" \
  "$PKG_DIR/usr/bin" \
  "$PKG_DIR/usr/share/applications" \
  "$PKG_DIR/usr/share/pixmaps" \
  "$PKG_DIR/usr/share/icons/hicolor/512x512/apps"

if [ ! -d "$BUILD_BUNDLE_DIR" ]; then
  echo "Flutter build output not found for architecture $FLUTTER_ARCH at $BUILD_BUNDLE_DIR" >&2
  exit 1
fi
cp -r "$BUILD_BUNDLE_DIR"/* "$PKG_DIR/usr/lib/$APP_NAME/"

# Launcher script
cat > "$PKG_DIR/usr/bin/$APP_NAME" <<'EOS'
#!/bin/sh
exec /usr/lib/kanshi_gui/kanshi_gui "$@"
EOS
chmod 755 "$PKG_DIR/usr/bin/$APP_NAME"

# ── Workspace helper ───────────────────────────────────────────────────────
# A standalone Dart executable, not a mode of the GUI: the Flutter binary
# drags a GTK window and a rendering engine behind it, and this thing has to
# run for the whole session without one. It shares the app's domain code, so
# the two cannot disagree about where a workspace belongs.
#
# The unit file ships DISABLED. A package that starts rearranging a stranger's
# workspaces the moment it is installed is exactly what got this app deleted
# off a colleague's laptop once; the switch lives in the app, per user.
DAEMON_DEST="$PKG_DIR/usr/lib/$APP_NAME/kanshi-gui-workspaced"
if [[ -n "$DAEMON_BIN_OVERRIDE" ]]; then
  if [[ ! -x "$DAEMON_BIN_OVERRIDE" ]]; then
    echo "Provided daemon binary is not executable: $DAEMON_BIN_OVERRIDE" >&2
    exit 1
  fi
  echo "Using prebuilt workspace helper from $DAEMON_BIN_OVERRIDE"
  cp "$DAEMON_BIN_OVERRIDE" "$DAEMON_DEST"
else
  # `dart compile exe` produces a binary for the HOST, so cross-packaging has
  # to be handed one that was built on the target — the same constraint the
  # Flutter bundle above lives under.
  if [[ "$HOST_ARCH_NORM" != "$DEB_ARCH" ]]; then
    echo "Cross-packaging for $DEB_ARCH needs --daemon-bin with a helper built on that architecture." >&2
    exit 1
  fi
  command -v dart >/dev/null 2>&1 || { echo "dart not found in PATH (needed for the workspace helper)." >&2; exit 1; }
  echo "Compiling the workspace helper…"
  dart compile exe "$ROOT_DIR/bin/kanshi_gui_workspaced.dart" -o "$DAEMON_DEST"
fi
chmod 755 "$DAEMON_DEST"

cat > "$PKG_DIR/usr/bin/kanshi-gui-workspaced" <<'EOS'
#!/bin/sh
exec /usr/lib/kanshi_gui/kanshi-gui-workspaced "$@"
EOS
chmod 755 "$PKG_DIR/usr/bin/kanshi-gui-workspaced"

# ── Mirror launcher ────────────────────────────────────────────────────────
# The `exec` line the app writes into a kanshi profile for a mirrored screen
# goes through this instead of calling wl-mirror directly: kanshi re-runs
# every exec line on reload, and a second wl-mirror on the same output
# breaks the first. The script is the guard the config line cannot carry.
cp "$ROOT_DIR/bin/kanshi-gui-mirror" "$PKG_DIR/usr/bin/kanshi-gui-mirror"
chmod 755 "$PKG_DIR/usr/bin/kanshi-gui-mirror"

cp "$ROOT_DIR/debian/systemd/kanshi-gui-workspaces.service" \
  "$PKG_DIR/usr/lib/systemd/user/"

# Desktop file and icons
cp "$ROOT_DIR/debian/gui/kanshi_gui.desktop" "$PKG_DIR/usr/share/applications/"
cp "$ROOT_DIR/assets/kanshi_gui.png" "$PKG_DIR/usr/share/pixmaps/"
cp "$ROOT_DIR/assets/kanshi_gui.png" "$PKG_DIR/usr/share/icons/hicolor/512x512/apps/${APP_NAME}.png"

# Control file
cat > "$PKG_DIR/DEBIAN/control" <<EOS
Package: $DEB_PACKAGE_NAME
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: nurkert
Priority: optional
Section: utils
Homepage: https://github.com/nurkert/kanshi_gui
Depends: kanshi, libc6, libstdc++6, libgcc-s1, libgtk-3-0, libglib2.0-0, libgdk-pixbuf-2.0-0, libpango-1.0-0, libpangocairo-1.0-0, libatk1.0-0, libatk-bridge2.0-0, libharfbuzz0b, libcairo2, libepoxy0, libdbus-1-3, zlib1g
Recommends: sway, wl-mirror, wlr-randr
Description: A simple GUI for kanshi.
 A Flutter-based GUI to create, edit and switch kanshi monitor profiles.
 .
 Includes an optional per-user helper service that keeps sway workspaces on
 the screens you assigned them to, at login and on every hotplug. It is
 installed switched off; turn it on under Workspaces in the app.
EOS

cat > "$PKG_DIR/DEBIAN/postinst" <<'EOS'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor
fi
exit 0
EOS
chmod 755 "$PKG_DIR/DEBIAN/postinst"

cat > "$PKG_DIR/DEBIAN/postrm" <<'EOS'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor
fi
exit 0
EOS
chmod 755 "$PKG_DIR/DEBIAN/postrm"

DEB_FILE="$ROOT_DIR/build/${DEB_PACKAGE_NAME}_${VERSION}_${DEB_ARCH}.deb"
dpkg-deb --root-owner-group --build "$PKG_DIR" "$DEB_FILE"

echo "Package built: $DEB_FILE"
