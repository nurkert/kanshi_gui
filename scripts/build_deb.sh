#!/usr/bin/env bash
set -e

APP_NAME="kanshi_gui"
ARCH="amd64"
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d'+' -f1)

# Build Flutter bundle
flutter build linux

PKG_DIR="build/debian/${APP_NAME}_${VERSION}"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/lib/$APP_NAME"
mkdir -p "$PKG_DIR/usr/bin"
mkdir -p "$PKG_DIR/usr/share/applications"
mkdir -p "$PKG_DIR/usr/share/pixmaps"

# Copy build output
cp -r build/linux/x64/release/bundle/* "$PKG_DIR/usr/lib/$APP_NAME/"

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
Package: $APP_NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: nurkert
Priority: optional
Description: A simple GUI for kanshi.
EOS

DEB_FILE="build/${APP_NAME}_${VERSION}_${ARCH}.deb"
dpkg-deb --build "$PKG_DIR" "$DEB_FILE"

echo "Package built: $DEB_FILE"
