#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Validate, ldid-entitle, and package a built Dynarium.app into an unsigned
# sideload/TrollStore-ready .ipa archive.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
APP_PATH=
OUTPUT_IPA=
EXPECTED_MINOS=16.0
ENTITLEMENTS="$ROOT_DIR/Dynarium/Config/Dynarium.entitlements"

fail()
{
	printf '%s\n' "Dynarium/scripts/package-ipa.sh: $*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--app)
		[ "$#" -ge 2 ] || fail "--app requires a path"
		APP_PATH=$2
		shift 2
		;;
	--output)
		[ "$#" -ge 2 ] || fail "--output requires a path"
		OUTPUT_IPA=$2
		shift 2
		;;
	--expected-minos)
		[ "$#" -ge 2 ] || fail "--expected-minos requires a version"
		EXPECTED_MINOS=$2
		shift 2
		;;
	--entitlements)
		[ "$#" -ge 2 ] || fail "--entitlements requires a path"
		ENTITLEMENTS=$2
		shift 2
		;;
	*)
		fail "unknown option: $1"
		;;
	esac
done

[ -n "$APP_PATH" ] && [ -d "$APP_PATH" ] || fail "missing --app bundle: $APP_PATH"
[ -n "$OUTPUT_IPA" ] || fail "--output path is required"
[ -f "$ENTITLEMENTS" ] || fail "missing entitlements plist: $ENTITLEMENTS"

LDID=$(command -v ldid)
OTOOL=$(command -v otool)
PYTHON=$(command -v python3)
ZIP=$(command -v zip)
SHASUM=$(command -v shasum)

OUT_DIR=$(dirname -- "$OUTPUT_IPA")
mkdir -p -- "$OUT_DIR"
OUT_DIR=$(CDPATH= cd -- "$OUT_DIR" && pwd -P)
ABS_OUTPUT="$OUT_DIR/$(basename -- "$OUTPUT_IPA")"

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/dynarium-ipa.XXXXXX")
cleanup()
{
	rm -rf -- "$STAGE"
}
trap cleanup EXIT HUP INT TERM

mkdir -p -- "$STAGE/Payload"
APP_NAME=$(basename -- "$APP_PATH")
DEST_APP="$STAGE/Payload/$APP_NAME"
cp -R -- "$APP_PATH" "$DEST_APP"

# Remove build metadata and stray headers not belonging inside an .ipa payload.
find "$DEST_APP" \( -name '.DS_Store' -o -name 'Headers' -o -name 'PrivateHeaders' \
	-o -name 'Modules' -o -name '*.dSYM' -o -name '*.bcsymbolmap' \) -exec rm -rf -- {} +

APP_EXEC_NAME=$(plutil -extract CFBundleExecutable raw -o - "$DEST_APP/Info.plist")
APP_BIN="$DEST_APP/$APP_EXEC_NAME"
[ -f "$APP_BIN" ] || fail "missing app executable: $APP_BIN"

PLIST_MINOS=$(plutil -extract MinimumOSVersion raw -o - "$DEST_APP/Info.plist")
[ "$PLIST_MINOS" = "$EXPECTED_MINOS" ] ||
	fail "Info.plist MinimumOSVersion=$PLIST_MINOS, expected $EXPECTED_MINOS"

APP_MINOS=$("$OTOOL" -l "$APP_BIN" | awk '
	/cmd LC_BUILD_VERSION/ { in_bv = 1; next }
	in_bv && /minos / { print $2; exit }
')
[ "$APP_MINOS" = "$EXPECTED_MINOS" ] ||
	fail "$APP_EXEC_NAME minos=$APP_MINOS, expected $EXPECTED_MINOS"

# Strip any existing Xcode ad-hoc/team signatures cleanly, re-apply ldid
# pseudo-signatures to embedded frameworks, and apply Dynarium's entitlements.
if [ -d "$DEST_APP/Frameworks" ]; then
	for item in "$DEST_APP/Frameworks"/*.framework; do
		[ -d "$item" ] || continue
		fw_name=$(basename -- "$item" .framework)
		if [ -f "$item/$fw_name" ]; then
			"$LDID" -S "$item/$fw_name"
		fi
		"$PYTHON" -B "$ROOT_DIR/scripts/check-privacy-manifests.py" "$item" ||
			fail "$fw_name failed privacy manifest verification"
	done
fi

"$LDID" "-S$ENTITLEMENTS" "$APP_BIN"

# Confirm critical memory/address-space entitlements are embedded in Mach-O.
ent_dump=$("$LDID" -e "$APP_BIN")
printf '%s' "$ent_dump" | grep -q 'com.apple.developer.kernel.increased-memory-limit' ||
	fail "increased-memory-limit entitlement missing after ldid"
printf '%s' "$ent_dump" | grep -q 'com.apple.developer.kernel.extended-virtual-addressing' ||
	fail "extended-virtual-addressing entitlement missing after ldid"

"$PYTHON" -B "$ROOT_DIR/scripts/check-privacy-manifests.py" "$DEST_APP" ||
	fail "Dynarium.app failed check-privacy-manifests.py"
"$PYTHON" -B "$ROOT_DIR/scripts/check-no-fexcore.py" "$DEST_APP" ||
	fail "Dynarium.app contains FEXCore symbols"
if [ "$EXPECTED_MINOS" = "16.0" ]; then
	"$PYTHON" -B "$ROOT_DIR/scripts/check-ios16-abi.py" "$DEST_APP" --expected-max-minos 16.0 ||
		fail "Dynarium.app failed iOS 16.0 ABI verification"
fi

for lang in en vi zh-Hans ja ko es; do
	[ -f "$DEST_APP/$lang.lproj/Localizable.strings" ] ||
		fail "missing localization bundle: $lang.lproj/Localizable.strings"
done

rm -f -- "$ABS_OUTPUT"
(
	CDPATH= cd -- "$STAGE"
	"$ZIP" -qr -y "$ABS_OUTPUT" Payload
)

size_bytes=$(wc -c <"$ABS_OUTPUT" | tr -d ' ')
size_mib=$(awk -v b="$size_bytes" 'BEGIN { printf "%.2f MiB", b / 1048576.0 }')
sha=$("$SHASUM" -a 256 "$ABS_OUTPUT" | awk '{ print $1 }')
printf 'Packaged %s (%s, sha256=%s)\n' "$ABS_OUTPUT" "$size_mib" "$sha"
