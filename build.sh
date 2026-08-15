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
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# macOS re-asks for folder access whenever the app's signing identity changes.
# An ad-hoc signature is identified by the binary's hash, which changes on every
# build — so prefer the stable self-signed identity from ./make-signing-cert.sh
# when it exists, and only fall back to ad-hoc.
IDENTITY="MAC Commander Local"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
	codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 \
		&& echo "==> signed as \"$IDENTITY\"" \
		|| echo "   (signing with \"$IDENTITY\" failed)"
else
	codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"
	echo "   note: ad-hoc signed, so macOS will re-ask for folder access after"
	echo "         each rebuild. Run ./make-signing-cert.sh once to stop that."
fi

echo "==> built ./${APP}"
[ "$LAUNCH" = "yes" ] && open "$APP"
exit 0
