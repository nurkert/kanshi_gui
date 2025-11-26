#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="kanshi_gui"
DEB_PACKAGE_NAME="${APP_NAME//_/-}"

command -v flutter >/dev/null 2>&1 || { echo "flutter not found in PATH." >&2; exit 1; }
command -v dpkg-deb >/dev/null 2>&1 || { echo "dpkg-deb not found (install dpkg-dev)." >&2; exit 1; }

# Determine architectures
DEB_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
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

VERSION="$(awk -F': ' '/^version:/{print $2}' "$ROOT_DIR/pubspec.yaml")"
PKG_DIR="$ROOT_DIR/build/debian/${DEB_PACKAGE_NAME}_${VERSION}"

echo "Building Flutter bundle for ${TARGET_PLATFORM}…"
flutter build linux --target-platform="$TARGET_PLATFORM"

echo "Assembling Debian package payload…"
rm -rf "$PKG_DIR"
mkdir -p \
  "$PKG_DIR/DEBIAN" \
  "$PKG_DIR/usr/lib/$APP_NAME" \
  "$PKG_DIR/usr/bin" \
  "$PKG_DIR/usr/share/applications" \
  "$PKG_DIR/usr/share/pixmaps" \
  "$PKG_DIR/usr/share/icons/hicolor/512x512/apps"

BUILD_BUNDLE_DIR="$ROOT_DIR/build/linux/$FLUTTER_ARCH/release/bundle"
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
Depends: libc6, libstdc++6, libgcc-s1, libgtk-3-0, libglib2.0-0, libgdk-pixbuf-2.0-0, libpango-1.0-0, libpangocairo-1.0-0, libatk1.0-0, libatk-bridge2.0-0, libharfbuzz0b, libcairo2, libepoxy0, libdbus-1-3, zlib1g
Recommends: kanshi
Description: A simple GUI for kanshi.
 A Flutter-based GUI to create, edit and switch kanshi monitor profiles.
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
dpkg-deb --build "$PKG_DIR" "$DEB_FILE"

echo "Package built: $DEB_FILE"
