#!/bin/bash
# Builds MAC Commander.app from the Swift package.
#   ./build.sh          release build
#   ./build.sh debug    debug build
#   ./build.sh run      build then launch
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
LAUNCH="no"
case "${1:-}" in
	debug) CONFIG="debug" ;;
	run) LAUNCH="yes" ;;
	"") ;;
	*) echo "usage: $0 [debug|run]" >&2; exit 1 ;;
esac

APP="MAC Commander.app"
BINARY=".build/${CONFIG}/MACCommander"

echo "==> swift build -c ${CONFIG}"
swift build -c "$CONFIG"

echo "==> assembling ${APP}"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
cp "$BINARY" "${APP}/Contents/MacOS/MACCommander"

# Regenerate the icon when the artwork is newer than the packed .icns.
if [ icons/logo.svg -nt Resources/AppIcon.icns ]; then
	echo "==> rebuilding icon from icons/logo.svg"
	swift Tools/make-icon.swift && iconutil -c icns icons/AppIcon.iconset -o Resources/AppIcon.icns
fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
# The icon library offered by Library... in a shortcut's properties. Drop an .ico or
# an .svg into Resources/buttons and rebuild; subfolders become groups in the picker.
[ -d Resources/buttons ] && cp -R Resources/buttons "${APP}/Contents/Resources/buttons"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# macOS re-asks for folder access whenever the app's signing identity changes.
# An ad-hoc signature is identified by the binary's hash, which changes on every
# build. So prefer the self-signed identity from ./make-signing-cert.sh, then the Mac's own
# Apple Development certificate (the same identity on every build, keyed on the
# team rather than the binary), and only then ad-hoc.
IDENTITY=""
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
for CANDIDATE in "MAC Commander Local" "Apple Development" "Developer ID Application"; do
	if echo "$IDENTITIES" | grep -q "\"$CANDIDATE"; then
		IDENTITY="$(echo "$IDENTITIES" | grep "\"$CANDIDATE" | head -1 | sed -E 's/.*"(.*)".*/\1/')"
		break
	fi
done
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
	echo "==> signed as \"$IDENTITY\""
else
	[ -n "$IDENTITY" ] && echo "   (signing with \"$IDENTITY\" failed - is the keychain locked?)"
	codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"
	echo "   note: ad-hoc signed, so macOS will re-ask for folder access after"
	echo "         each rebuild. Run ./make-signing-cert.sh once to stop that."
fi

echo "==> built ./${APP}"
[ "$LAUNCH" = "yes" ] && open "$APP"
exit 0
