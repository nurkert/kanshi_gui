#!/usr/bin/env bash
set -e

APP_NAME="kanshi_gui"
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
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d'+' -f1)
DEB_PACKAGE_NAME="${APP_NAME//_/-}"

# Build Flutter bundle
flutter build linux --target-platform="$TARGET_PLATFORM"

PKG_DIR="build/debian/${DEB_PACKAGE_NAME}_${VERSION}"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/lib/$APP_NAME"
mkdir -p "$PKG_DIR/usr/bin"
mkdir -p "$PKG_DIR/usr/share/applications"
mkdir -p "$PKG_DIR/usr/share/pixmaps"

# Copy build output
BUILD_BUNDLE_DIR="build/linux/$FLUTTER_ARCH/release/bundle"
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

# Desktop file and icon
cp debian/gui/kanshi_gui.desktop "$PKG_DIR/usr/share/applications/"
cp assets/kanshi_gui.png "$PKG_DIR/usr/share/pixmaps/"

# Control file
cat > "$PKG_DIR/DEBIAN/control" <<EOS
Package: $DEB_PACKAGE_NAME
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: nurkert
Depends: libc6, libstdc++6, libgcc-s1, libgtk-3-0, libglib2.0-0, libgdk-pixbuf-2.0-0, libpango-1.0-0, libpangocairo-1.0-0, libatk1.0-0, libatk-bridge2.0-0, libharfbuzz0b, libcairo2, libepoxy0, libdbus-1-3, zlib1g
Priority: optional
Description: A simple GUI for kanshi.
EOS

DEB_FILE="build/${DEB_PACKAGE_NAME}_${VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build "$PKG_DIR" "$DEB_FILE"

echo "Package built: $DEB_FILE"
