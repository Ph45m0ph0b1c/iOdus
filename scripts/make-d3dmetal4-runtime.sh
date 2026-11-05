#!/bin/sh
# Makes the D3DMetal 4 variant of the Wine 11 runtime for local tests:
# the same Wine, with D3DMetal 4 from Game Porting Toolkit 4 (macOS 27 only)
# in place of D3DMetal 3, the Metal 4 backend off (D3DM_MTL4=0), and its own
# ID, so that it gets its own prefix. Forza Horizon 6 needs D3DMetal 4.
#
# The runtime also gets the d3d12.dll layer (scripts/runtime-compat/highball-d3d12-shim.c,
# from Highball) in front of D3DMetal: Apple's d3d12.dll becomes d3d12_d3dmetal.dll
# (renamed only; its content stays unchanged), and Wine finds it by its file name
# (wine11-patches/builtin-by-file-name.patch, WINE_BUILTIN_BY_FILE_NAME).
# SHIM: the built layer (default ~/projects/iodus-runtime-build/components/highball-d3d12-shim.dll).
#
# Usage: make-d3dmetal4-runtime.sh <runtime folder without D3DMetal> <GPTK 4 redist folder> <output folder>
#   runtime folder: build-wine-runtime.sh STAGE=assemble (runtime/crossover-26.3)
#   redist folder:  "redist" from "Evaluation environment for Windows games 4.0 beta N.dmg"
#                   in Apple's Game Porting Toolkit 4 download
#   output folder:  for example ~/Library/Application Support/iOdus/Runtimes/crossover-26.3-d3dm4
#
# D3DMetal is Apple's binary under Apple's license. Never package the output.
set -eu

[ $# -eq 3 ] || { sed -n '2,19p' "$0" >&2; exit 2; }
SRC=$1 REDIST=$2 OUT=$3
FRAMEWORK="$REDIST/lib/external/D3DMetal.framework"
SHIM=${SHIM:-$HOME/projects/iodus-runtime-build/components/highball-d3d12-shim.dll}

[ -f "$SRC/runtime.json" ] || { echo "No runtime.json in $SRC" >&2; exit 1; }
[ -e "$SRC/lib/external" ] && { echo "$SRC already has D3DMetal. Use the assembled folder." >&2; exit 1; }
[ -d "$FRAMEWORK" ] || { echo "No D3DMetal.framework in $REDIST" >&2; exit 1; }
[ -e "$OUT" ] && { echo "$OUT exists. Remove it first." >&2; exit 1; }
[ -f "$SHIM" ] || { echo "No d3d12 layer at $SHIM" >&2; exit 1; }

# Apple's signature, and version 4.
codesign --verify --strict -R='anchor apple' "$FRAMEWORK" || { echo "D3DMetal is not signed by Apple." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$FRAMEWORK/Versions/A/Resources/Info.plist")
case "$VERSION" in 4.*) ;; *) echo "D3DMetal $VERSION is not version 4." >&2; exit 1 ;; esac

# A clone shares the disk blocks of the runtime (APFS), so it costs almost no space.
cp -cR "$SRC" "$OUT"
ditto "$REDIST/lib/external" "$OUT/lib/external"
WINDOWS="" UNIX=""
for f in "$REDIST"/lib/wine/x86_64-windows/*.dll; do
  name=$(basename "$f"); cp "$f" "$OUT/lib/wine/x86_64-windows/$name"; WINDOWS="$WINDOWS $name"
done
for f in "$REDIST"/lib/wine/x86_64-unix/*.so; do
  name=$(basename "$f"); rm -f "$OUT/lib/wine/x86_64-unix/$name"; cp -P "$f" "$OUT/lib/wine/x86_64-unix/$name"; UNIX="$UNIX $name"
done

# The layer takes the name d3d12.dll; Apple's file keeps its content under a new name.
mv "$OUT/lib/wine/x86_64-windows/d3d12.dll" "$OUT/lib/wine/x86_64-windows/d3d12_d3dmetal.dll"
cp "$SHIM" "$OUT/lib/wine/x86_64-windows/d3d12.dll"
ln -s ../../external/libd3dshared.dylib "$OUT/lib/wine/x86_64-unix/d3d12_d3dmetal.so"
WINDOWS="$WINDOWS d3d12_d3dmetal.dll" UNIX="$UNIX d3d12_d3dmetal.so"

ID=$(basename "$OUT")
python3 -I - "$OUT/runtime.json" "$ID" "$VERSION" "$WINDOWS" "$UNIX" <<'PY'
import json, sys
path, rid, version, windows, unix = sys.argv[1:6]
m = json.load(open(path))
m["id"] = rid
m["name"] = f"{m['name']} + D3DMetal {version}"
env = m.setdefault("environment", {})
env["D3DM_MTL4"] = "0"
env["WINE_BUILTIN_BY_FILE_NAME"] = "d3d12_d3dmetal.dll"
m["d3dmetal"] = {"windows": windows.split(), "unix": unix.split()}
json.dump(m, open(path, "w"), indent=2)
PY
echo "== $OUT: D3DMetal $VERSION (local test only; never package this folder)"
