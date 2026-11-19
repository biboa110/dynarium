#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Package Dynarium's verified Android iOS XCFrameworks into
# .build/kernarium-xcframeworks (or KERNARIUM_XCFRAMEWORK_OUTPUT) for either:
#   --tier ios16-universal : iOS 16.0+ device runtime + Mesa softpipe/llvmpipe
#   --tier ios26-metal4    : iOS 26.0+ device runtime + KosmicKrisp + Zink
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUTPUT=${KERNARIUM_XCFRAMEWORK_OUTPUT:-"$ROOT_DIR/.build/kernarium-xcframeworks"}
TIER=ios16-universal
RUNTIME_TREE=
GPU_PREFIX=
CHECK_SIMULATOR=0

fail()
{
	printf '%s\n' "Dynarium/scripts/package-dynarium-frameworks.sh: $*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--tier)
		[ "$#" -ge 2 ] || fail "--tier requires a value"
		TIER=$2
		shift 2
		;;
	--runtime-tree)
		[ "$#" -ge 2 ] || fail "--runtime-tree requires a path"
		RUNTIME_TREE=$2
		shift 2
		;;
	--gpu-prefix)
		[ "$#" -ge 2 ] || fail "--gpu-prefix requires a path"
		GPU_PREFIX=$2
		shift 2
		;;
	--with-simulator-zstd)
		CHECK_SIMULATOR=1
		shift
		;;
	*)
		fail "unknown option: $1"
		;;
	esac
done

case "$TIER" in
ios16-universal)
	EXPECTED_MINOS=16.0
	GPU_RENDERER=software
	DEFAULT_RUNTIME_TREE="$ROOT_DIR/.build/kernarium-runtime-ios-device-android-4k"
	DEFAULT_GPU_PREFIX="$ROOT_DIR/.build/dependencies/apple-gpu-vulkan-experiment/ios-device-arm64"
	GPU_FRAMEWORKS="MesaEGL MesaGallium"
	;;
ios26-metal4)
	EXPECTED_MINOS=26.0
	GPU_RENDERER=vulkan
	DEFAULT_RUNTIME_TREE="$ROOT_DIR/.build/kernarium-runtime-ios26-android-4k"
	DEFAULT_GPU_PREFIX="$ROOT_DIR/.build/dependencies/apple-gpu-vulkan-experiment-26/ios-device-arm64"
	GPU_FRAMEWORKS="MesaEGL MesaGallium KosmicKrisp"
	;;
*)
	fail "--tier must be ios16-universal or ios26-metal4"
	;;
esac

RUNTIME_TREE=${RUNTIME_TREE:-"$DEFAULT_RUNTIME_TREE"}
GPU_PREFIX=${GPU_PREFIX:-"$DEFAULT_GPU_PREFIX"}
GPU_FRAMEWORKS_DIR="$GPU_PREFIX/Frameworks"
RUNTIME_NAME=KRuntime_Android_6_18_4K
DEVICE_RUNTIME="$RUNTIME_TREE/Kernarium/Runtime/$RUNTIME_NAME.framework"
ZSTD="$ROOT_DIR/.build/dependencies/ios-zstd/LibZstd.xcframework"

for required in \
	"$DEVICE_RUNTIME" \
	"$DEVICE_RUNTIME.dSYM" \
	"$ZSTD"; do
	[ -d "$required" ] || fail "missing required input: $required"
done

for fw in $GPU_FRAMEWORKS; do
	[ -d "$GPU_FRAMEWORKS_DIR/$fw.framework" ] ||
		fail "missing GPU framework: $GPU_FRAMEWORKS_DIR/$fw.framework"
	[ -d "$GPU_PREFIX/dSYMs/$fw.framework.dSYM" ] ||
		fail "missing GPU dSYM: $GPU_PREFIX/dSYMs/$fw.framework.dSYM"
done

UML_IOS_DEPLOYMENT_TARGET="$EXPECTED_MINOS" \
	"$ROOT_DIR/dependencies/build-apple-gpu.sh" --platform ios \
	--renderer "$GPU_RENDERER" --prefix "$GPU_PREFIX" --verify-only

XCODEBUILD=$(command -v xcodebuild)
OTOOL=$(command -v otool)
NM=$(command -v nm)
STRIP=$(command -v strip)
CMAKE=$(command -v cmake)
PYTHON=$(command -v python3)

OUTPUT_PARENT=$(dirname -- "$OUTPUT")
mkdir -p -- "$OUTPUT_PARENT"
OUTPUT_PARENT=$(CDPATH= cd -- "$OUTPUT_PARENT" && pwd -P)
OUTPUT="$OUTPUT_PARENT/$(basename -- "$OUTPUT")"
STAGE=$(mktemp -d "$OUTPUT_PARENT/.dynarium-xcframeworks.XXXXXX")
cleanup()
{
	if [ -n "${STAGE:-}" ] && [ -d "$STAGE" ]; then
		"$CMAKE" -E remove_directory "$STAGE"
	fi
}
trap cleanup EXIT HUP INT TERM

create_device_xcframework()
{
	name=$1
	framework_dir=$2
	dsym_dir=$3
	"$XCODEBUILD" -create-xcframework \
		-framework "$framework_dir" \
		-debug-symbols "$dsym_dir" \
		-output "$STAGE/$name.xcframework"
	[ -f "$STAGE/$name.xcframework/Info.plist" ] ||
		fail "$name.xcframework was not created"
}

create_device_xcframework "$RUNTIME_NAME" "$DEVICE_RUNTIME" "$DEVICE_RUNTIME.dSYM"
for fw in $GPU_FRAMEWORKS; do
	create_device_xcframework "$fw" \
		"$GPU_FRAMEWORKS_DIR/$fw.framework" \
		"$GPU_PREFIX/dSYMs/$fw.framework.dSYM"
done
"$CMAKE" -E copy_directory "$ZSTD" "$STAGE/LibZstd.xcframework"

# Strip stabs from framework binaries while keeping UUID-matched dSYMs in the XCFramework.
for fw in $RUNTIME_NAME $GPU_FRAMEWORKS; do
	slice_fw="$STAGE/$fw.xcframework/ios-arm64/$fw.framework"
	"$STRIP" -S "$slice_fw/$fw" || fail "could not strip debug map of $fw"
done

# Verify kernel symbols reside in the dSYM and not in the stripped runtime binary.
runtime_bin="$STAGE/$RUNTIME_NAME.xcframework/ios-arm64/$RUNTIME_NAME.framework/$RUNTIME_NAME"
runtime_dwarf="$STAGE/$RUNTIME_NAME.xcframework/ios-arm64/dSYMs/$RUNTIME_NAME.framework.dSYM/Contents/Resources/DWARF/$RUNTIME_NAME"
[ -f "$runtime_dwarf" ] || fail "missing runtime DWARF symbols: $runtime_dwarf"
"$NM" -a "$runtime_dwarf" | LC_ALL=C grep -q ' ___uml_kernel_symbols$' ||
	fail "runtime dSYM missing ___uml_kernel_symbols"
if "$NM" -a "$runtime_bin" | LC_ALL=C grep -q ' ___uml_kernel_symbols$'; then
	fail "stripped runtime binary unexpectedly retains ___uml_kernel_symbols"
fi

# Check runtime rpath & deployment floor.
rpaths=$("$OTOOL" -l "$runtime_bin" | awk '
	$1 == "cmd" { command = $2; next }
	command == "LC_RPATH" && $1 == "path" { print $2; command = "" }
')
[ "$rpaths" = '@loader_path/..' ] || fail "invalid runtime LC_RPATH: $rpaths"

minos=$("$OTOOL" -l "$runtime_bin" | awk '
	/cmd LC_BUILD_VERSION/ { in_bv = 1; next }
	in_bv && /minos / { print $2; exit }
')
[ "$minos" = "$EXPECTED_MINOS" ] ||
	fail "$RUNTIME_NAME minos=$minos, expected $EXPECTED_MINOS"

# Install privacy manifests.
PRIVACY_DIR="$ROOT_DIR/Kernarium/PrivacyManifests"
cp -- "$PRIVACY_DIR/KRuntime.xcprivacy" \
	"$STAGE/$RUNTIME_NAME.xcframework/ios-arm64/$RUNTIME_NAME.framework/PrivacyInfo.xcprivacy"
for fw in $GPU_FRAMEWORKS; do
	cp -- "$PRIVACY_DIR/$fw.xcprivacy" \
		"$STAGE/$fw.xcframework/ios-arm64/$fw.framework/PrivacyInfo.xcprivacy"
done

# Tier-specific GPU verification.
if [ "$TIER" = ios16-universal ]; then
	"$PYTHON" -B "$ROOT_DIR/scripts/check-software-renderer.py" --present \
		"$STAGE/MesaGallium.xcframework/ios-arm64" ||
		fail "ios16-universal MesaGallium must include software renderer symbols"
else
	for fw in $RUNTIME_NAME $GPU_FRAMEWORKS; do
		"$PYTHON" -B "$ROOT_DIR/scripts/check-software-renderer.py" --absent \
			"$STAGE/$fw.xcframework/ios-arm64" ||
			fail "ios26-metal4 slice $fw must not carry software renderer symbols"
	done
fi

for fw in $RUNTIME_NAME $GPU_FRAMEWORKS; do
	"$PYTHON" -B "$ROOT_DIR/scripts/check-privacy-manifests.py" \
		"$STAGE/$fw.xcframework/ios-arm64/$fw.framework" ||
		fail "$fw failed check-privacy-manifests.py"
done

"$PYTHON" -B "$ROOT_DIR/scripts/check-no-fexcore.py" "$STAGE" ||
	fail "packaged frameworks carry FEXCore"

publish=0
"$PYTHON" "$ROOT_DIR/dependencies/publish-prefix.py" "$STAGE" "$OUTPUT" || publish=$?
case $publish in
0) STAGE= ;;
1)
	publish=0
	"$PYTHON" "$ROOT_DIR/dependencies/publish-prefix.py" --swap "$STAGE" "$OUTPUT" || publish=$?
	[ "$publish" -eq 0 ] || fail "could not swap published XCFrameworks: $OUTPUT"
	if [ -L "$STAGE" ]; then
		rm -f -- "$STAGE"
		STAGE=
	fi
	;;
*) fail "could not publish XCFrameworks: $OUTPUT" ;;
esac

printf '%s\n' "published Dynarium [$TIER] XCFrameworks at $OUTPUT"
