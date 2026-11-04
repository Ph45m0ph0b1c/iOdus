#!/bin/sh
# Builds the Wine 11 runtime for iOdus from the CrossOver 26.3 source
# (docs/runtime-versions-plan.md, part 2).
#
# Stages (run all, or one with STAGE=<name>):
#   source  check and extract the pinned CrossOver source archive
#   deps    build GMP, Nettle, GnuTLS, FreeType, and SDL2 (x86_64, shared) into deps/
#   wine    configure and build Wine (x86_64 host; 64-bit and 32-bit Windows programs
#           through the new WoW64 mode, for example 32-bit installers)
#   wine-make  continue the Wine build without a new configure
#   assemble   make the runtime folder runtime/crossover-26.3 (Wine, the
#              libraries, the Xodus WinRT DLLs, runtime.json, licenses) without D3DMetal
#   d3dmetal   add D3DMetal from an installed GPTK 3.0-3 (local tests only)
#   package    make the release files in release/ (needs a folder without D3DMetal)
#
# GPTK: the GPTK wine folder for D3DMetal (default: the iOdus runtime).
# D3DMetal is Apple's binary; it is copied from the GPTK that the player installed.
#
# Usage: build-wine-runtime.sh [<work folder>]   (default ~/projects/iodus-runtimes)
# Everything is built as x86_64 through Rosetta, the same architecture as the
# GPTK Wine. Nothing outside the work folder changes.
set -eu
SCRIPT=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")   # absolute: the stages change folders

WORK=${1:-$HOME/projects/iodus-runtimes}
STAGE=${STAGE:-all}
JOBS=${JOBS:-8}
VERSION=26.3.0
ARCHIVE=crossover-sources-$VERSION.tar.gz
URL=https://media.codeweavers.com/pub/crossover/source/$ARCHIVE
SHA256=ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872

# CrossOver's copy of Nettle has no Makefile.in files. The GNU release has the
# same sources (all 859 .c/.h/.asm files are equal) plus the build files.
NETTLE_URL=https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz
NETTLE_SHA256=b4c518adb174e484cb4acea54118f02380c7133771e7e9beb98a0787194ee47c

# CrossOver's FreeType is a git checkout without the generated configure script
# (its wrapper wants a git submodule). The 2.13.3 release has the same src/ and
# include/ files (441 files in src, no difference).
FREETYPE_URL=https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz
FREETYPE_SHA256=0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289

# SDL2 for the controller driver (winebus). Without SDL2, winebus has only its
# IOHID backend, and SDL games (for example Hades II) find no controller.
# The GPTK Wine also ships SDL2. The CrossOver source archive has no SDL2.
SDL2_VERSION=2.32.10
SDL2_URL=https://github.com/libsdl-org/SDL/releases/download/release-$SDL2_VERSION/SDL2-$SDL2_VERSION.tar.gz
SDL2_SHA256=5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165

SRC=$WORK/src/sources
DEPS=$WORK/deps
BUILD=$WORK/build
LOGS=$WORK/logs
X86="arch -x86_64"
export PATH="/opt/homebrew/opt/bison/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=13.0
export CC="clang -arch x86_64" CXX="clang++ -arch x86_64"
export CFLAGS="-O2" CXXFLAGS="-O2"
mkdir -p "$WORK/src" "$DEPS" "$BUILD" "$LOGS"

run() { # step command...: run a step, log it, show the end of the log on failure
  step=$1; shift
  echo "== $step"
  if ! "$@" > "$LOGS/$step.log" 2>&1; then
    tail -30 "$LOGS/$step.log" >&2
    echo "Failed: $step (log: $LOGS/$step.log)" >&2
    exit 1
  fi
}

stage_source() {
  cd "$WORK/src"
  [ -f "$ARCHIVE" ] || curl -sSL -o "$ARCHIVE" "$URL"
  echo "$SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: $ARCHIVE" >&2; exit 1; }
  [ -d "$SRC/wine" ] && [ -d "$SRC/gnutls" ] && [ -d "$SRC/freetype" ] ||
    tar -xzf "$ARCHIVE" sources/wine sources/gnutls sources/freetype
  if [ ! -d nettle-3.10 ]; then
    [ -f nettle-3.10.tar.gz ] || curl -sSL -o nettle-3.10.tar.gz "$NETTLE_URL"
    echo "$NETTLE_SHA256  nettle-3.10.tar.gz" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: nettle" >&2; exit 1; }
    tar -xzf nettle-3.10.tar.gz
  fi
  if [ ! -d freetype-2.13.3 ]; then
    [ -f freetype-2.13.3.tar.xz ] || curl -sSL -o freetype-2.13.3.tar.xz "$FREETYPE_URL"
    echo "$FREETYPE_SHA256  freetype-2.13.3.tar.xz" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: freetype" >&2; exit 1; }
    tar -xJf freetype-2.13.3.tar.xz
  fi
  if [ ! -d "SDL2-$SDL2_VERSION" ]; then
    [ -f "SDL2-$SDL2_VERSION.tar.gz" ] || curl -sSL -o "SDL2-$SDL2_VERSION.tar.gz" "$SDL2_URL"
    echo "$SDL2_SHA256  SDL2-$SDL2_VERSION.tar.gz" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: SDL2" >&2; exit 1; }
    tar -xzf "SDL2-$SDL2_VERSION.tar.gz"
  fi
  echo "== Source $VERSION ready"
}

# configure + make + make install for one autotools project, in a copy of its source.
autotools() { # name source-dir configure-args...
  name=$1; dir=$2; shift 2
  if ls "$DEPS/lib/lib$name".*dylib >/dev/null 2>&1; then echo "== $name: already built"; return; fi
  # -p keeps the file times. Without it, make sees new Makefile.am files and
  # wants to run the exact automake version of the release again.
  rm -rf "$BUILD/$name"; cp -Rp "$dir" "$BUILD/$name"
  cd "$BUILD/$name"
  if [ ! -x configure ]; then run "$name-autoreconf" $X86 autoreconf -fi; fi
  run "$name-configure" $X86 ./configure --prefix="$DEPS" --enable-shared --disable-static "$@"
  run "$name-make" $X86 make -j"$JOBS"
  run "$name-install" $X86 make install
}

stage_deps() {
  export CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib"
  export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"
  autotools gmp "$SRC/gnutls/gmp" --disable-assembly
  autotools nettle "$WORK/src/nettle-3.10" --disable-documentation --disable-openssl
  # One word per *_LIBS value: GnuTLS's configure tests "x$NETTLE_LIBS != x"
  # without quotes, and a value with a space silently disables Nettle.
  # The -I and -L paths come from CPPFLAGS and LDFLAGS.
  autotools gnutls "$SRC/gnutls/gnutls" \
    NETTLE_CFLAGS= NETTLE_LIBS=-lnettle HOGWEED_CFLAGS= HOGWEED_LIBS=-lhogweed GMP_CFLAGS= GMP_LIBS=-lgmp \
    --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn \
    --without-brotli --without-zstd --without-tpm --without-tpm2 --disable-doc --disable-tests \
    --disable-tools --disable-cxx --disable-nls --disable-guile
  autotools freetype "$WORK/src/freetype-2.13.3" --without-harfbuzz --without-brotli --without-png --without-bzip2
  sdl2
  echo "== Dependencies:"
  ls "$DEPS/lib"/*.dylib
}

# SDL2 uses CMake (arm64 Homebrew cmake; CMAKE_OSX_ARCHITECTURES gives x86_64).
# Only the shared library; no tests, no static library.
sdl2() {
  if ls "$DEPS/lib/libSDL2"*.dylib >/dev/null 2>&1; then echo "== sdl2: already built"; return; fi
  rm -rf "$BUILD/sdl2"; mkdir -p "$BUILD/sdl2"; cd "$BUILD/sdl2"
  run sdl2-configure cmake "$WORK/src/SDL2-$SDL2_VERSION" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF -DSDL2_DISABLE_SDL2MAIN=ON
  run sdl2-make cmake --build . -j "$JOBS"
  run sdl2-install cmake --install .
}

# The iOdus patches for the CrossOver Wine source (scripts/wine11-patches, in
# name order). A patch that is already in the tree is skipped.
PATCHES=$(cd "$(dirname "$SCRIPT")/wine11-patches" && pwd)
apply_patches() {
  for p in "$PATCHES"/*.patch; do
    [ -f "$p" ] || continue
    # -N -t: never ask (BSD patch takes "yes" to its questions without -t).
    if patch -d "$SRC/wine" -p1 -N -t --dry-run < "$p" >/dev/null 2>&1; then
      patch -d "$SRC/wine" -p1 -N -t -s < "$p" || { echo "Patch failed: $p" >&2; exit 1; }
      echo "== patch $(basename "$p"): applied"
    elif patch -d "$SRC/wine" -p1 -R -t --dry-run < "$p" >/dev/null 2>&1; then
      echo "== patch $(basename "$p"): already applied"
    else
      echo "Patch does not apply: $p" >&2; exit 1
    fi
  done
}

stage_wine() {
  apply_patches
  rm -rf "$BUILD/wine"; mkdir -p "$BUILD/wine"; cd "$BUILD/wine"
  # pipe2 is in the new SDK, but not in the x86_64 libSystem that Rosetta
  # runs; Wine calls it without a run-time check and crashes at the start.
  run wine-configure $X86 env ac_cv_func_pipe2=no \
    GNUTLS_CFLAGS="-I$DEPS/include" GNUTLS_LIBS="-L$DEPS/lib -lgnutls" \
    FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
    SDL2_CFLAGS="-I$DEPS/include/SDL2" SDL2_LIBS="-L$DEPS/lib -lSDL2" \
    "$SRC/wine/configure" --prefix="$WORK/install" --enable-archs=i386,x86_64 --disable-tests \
    --without-x --without-wayland --without-gstreamer --without-vulkan \
    --without-oss --without-alsa --without-pulse --without-capi --without-cups --without-gphoto \
    --without-sane --without-krb5 --without-netapi --without-pcap --without-usb --without-v4l2 --without-udev
  grep -E "gnutls|freetype|sdl" "$LOGS/wine-configure.log" | grep -i "configure: " || true
  grep -q "^#define SONAME_LIBSDL2" include/config.h || { echo "Wine configure did not find SDL2." >&2; exit 1; }
  # CrossOver's win32u/vulkan.c needs SONAME_LIBVULKAN also without Vulkan
  # ("CW HACK 25909"). It loads the library with dlopen and works without it.
  # D3DMetal does not use Vulkan.
  grep -q "^#define SONAME_LIBVULKAN" include/config.h ||
    echo '#define SONAME_LIBVULKAN "libMoltenVK.dylib"' >> include/config.h
  stage_wine_make
}

stage_wine_make() {
  apply_patches
  cd "$BUILD/wine"
  run wine-make $X86 make -j"$JOBS"
  run wine-install $X86 make install
  echo "== Wine installed in $WORK/install"
}

# The iOdus DLLs from scripts/build-runtime.sh (Xodus Wine 11 tree with the Nexus patches).
XODUS_COMPONENTS=${XODUS_COMPONENTS:-$HOME/projects/iodus-runtime-build/components}
GPTK=${GPTK:-$HOME/Library/Application Support/iOdus/Runtime/gptk-3.0-3/Game Porting Toolkit.app/Contents/Resources/wine}
RUNTIME_ID=crossover-26.3

# D3DMetal is Apple's binary. The runtime package does not contain it; iOdus
# copies these files from the GPTK that the player installed (runtime.json
# "d3dmetal"). The .so files are links to ../../external/libd3dshared.dylib.
D3DMETAL_WINDOWS="d3d10.dll d3d11.dll d3d12.dll dxgi.dll nvapi64.dll nvngx.dll nvngx-on-metalfx.dll atiadlxx.dll"
D3DMETAL_UNIX="d3d10.so d3d11.so d3d12.so dxgi.so nvngx.so nvngx-on-metalfx.so"
RUNTIME_RELEASE=${RUNTIME_RELEASE:-3}

json_list() { printf '"%s", ' $1 | sed 's/, $//'; }

stage_assemble() {
  OUT="$WORK/runtime/$RUNTIME_ID"
  [ -x "$WORK/install/bin/wine" ] || { echo "Build Wine first (STAGE=wine)." >&2; exit 1; }
  echo "== Assemble $OUT (without D3DMetal)"
  rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/lib"
  cp "$WORK/install/bin/wine" "$WORK/install/bin/wineserver" "$OUT/bin/"
  ditto "$WORK/install/lib/wine" "$OUT/lib/wine"
  ditto "$WORK/install/share/wine" "$OUT/share/wine"

  # GnuTLS, FreeType, and their dependencies. Wine loads them with dlopen
  # (DYLD_FALLBACK_LIBRARY_PATH=lib). Their links to each other use @loader_path.
  for f in "$DEPS"/lib/*.dylib; do cp -P "$f" "$OUT/lib/"; done
  for f in "$OUT"/lib/*.dylib; do
    [ -L "$f" ] && continue
    install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null
    for dep in $(otool -L "$f" | awk 'NR>1 {print $1}' | grep "^$DEPS/lib/"); do
      install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f"
    done
    codesign --force -s - "$f" 2>/dev/null
  done

  # CrossOver's Wine 11.0 has stub versions of windows.web (Windows.Data.Json),
  # twinapi.appcore, and wintypes; the Xbox sign-in then fails with E_NOTIMPL.
  # The Xodus versions replace them as built-in DLLs. (A copy in system32 does
  # not work: these files carry the "Wine builtin DLL" mark, so Wine loads its
  # own built-in DLL of the same name instead.)
  for pair in windows.web.dll:windows.web.dll twinapi.appcore.dll:twinapi.appcore.dll iodus_wintypes.dll:wintypes.dll; do
    src=${pair%%:*}; dst=${pair##*:}
    [ -f "$XODUS_COMPONENTS/$src" ] || { echo "Missing $XODUS_COMPONENTS/$src (run build-runtime.sh)" >&2; exit 1; }
    cp "$XODUS_COMPONENTS/$src" "$OUT/lib/wine/x86_64-windows/$dst"
  done

  # The GPTK ntdll finds libd3dshared through these rpaths; give them to the Wine 11 ntdll too.
  NTDLL="$OUT/lib/wine/x86_64-unix/ntdll.so"
  for rp in "@loader_path/../../" "@loader_path/../../external"; do
    install_name_tool -add_rpath "$rp" "$NTDLL" 2>/dev/null || true
  done
  codesign --force -s - "$NTDLL"

  cat > "$OUT/runtime.json" <<JSON
{
  "id": "$RUNTIME_ID",
  "name": "CrossOver 26.3 Wine",
  "wineVersion": "11.0",
  "release": $RUNTIME_RELEASE,
  "wine": "bin/wine",
  "wineserver": "bin/wineserver",
  "libraries": "lib",
  "components": ["xgameruntime.dll", "api-ms-win-core-psm-appnotify-l1-1-0.dll"],
  "overrides": {"api-ms-win-core-psm-appnotify-l1-1-0": "native"},
  "register": ["windows.web.dll"],
  "propertySet": "wintypes.dll",
  "inputGate": true,
  "environment": {"CX_APPLEGPTK_LIBD3DSHARED_PATH": "{root}/lib/external/libd3dshared.dylib"},
  "d3dmetal": {"windows": [$(json_list "$D3DMETAL_WINDOWS")], "unix": [$(json_list "$D3DMETAL_UNIX")]}
}
JSON
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUT/runtime.json" || { echo "Bad runtime.json" >&2; exit 1; }
  licenses "$OUT"
  du -sh "$OUT"
  echo "== Runtime folder ready (without D3DMetal): $OUT"
}

# The license texts and the source offer go into the runtime folder.
licenses() { # runtime folder
  L="$1/LICENSES"; mkdir -p "$L"
  cp "$SRC/wine/COPYING.LIB" "$L/wine-COPYING.LIB"
  cp "$SRC/wine/LICENSE" "$L/wine-LICENSE" 2>/dev/null || true
  cp "$SRC/wine/AUTHORS" "$L/wine-AUTHORS"
  cp "$SRC/gnutls/gnutls/LICENSE" "$L/gnutls-LICENSE"
  cp "$SRC/gnutls/gnutls/COPYING.LESSERv2" "$L/gnutls-COPYING.LESSERv2" 2>/dev/null || true
  cp "$WORK/src/nettle-3.10/COPYING.LESSERv3" "$L/nettle-COPYING.LESSERv3"
  cp "$WORK/src/nettle-3.10/COPYINGv2" "$L/nettle-COPYINGv2"
  cp "$SRC/gnutls/gmp/COPYING.LESSERv3" "$L/gmp-COPYING.LESSERv3"
  cp "$SRC/gnutls/gmp/COPYINGv2" "$L/gmp-COPYINGv2"
  cp "$WORK/src/freetype-2.13.3/docs/FTL.TXT" "$L/freetype-FTL.TXT"
  cp "$WORK/src/freetype-2.13.3/LICENSE.TXT" "$L/freetype-LICENSE.TXT"
  cp "$WORK/src/SDL2-$SDL2_VERSION/LICENSE.txt" "$L/sdl2-LICENSE.txt"
  SCRIPT_SHA=$(shasum -a 256 "$SCRIPT" | cut -d' ' -f1)
  cat > "$1/SOURCES.md" <<EOF
# Sources of this runtime

This runtime is free software. It contains Wine (LGPL 2.1 or later), GnuTLS
(LGPL 2.1 or later), Nettle and GMP (LGPL 3 or GPL 2), FreeType (FreeType
License or GPL 2), and SDL2 (zlib License). The license texts are in LICENSES/.

It was built with scripts/build-wine-runtime.sh of iOdus (release $RUNTIME_RELEASE,
script SHA-256 $SCRIPT_SHA) from these exact source archives:

| Archive | SHA-256 | From |
|---|---|---|
| $ARCHIVE | $SHA256 | $URL |
| nettle-3.10.tar.gz | $NETTLE_SHA256 | $NETTLE_URL |
| freetype-2.13.3.tar.xz | $FREETYPE_SHA256 | $FREETYPE_URL |
| SDL2-$SDL2_VERSION.tar.gz | $SDL2_SHA256 | $SDL2_URL |

The Wine source is sources/wine in the CrossOver archive (Wine 11.0 with the
CodeWeavers changes), plus the iOdus patches in wine11-patches/ of the release
(scripts/wine11-patches in iOdus). GnuTLS and GMP are sources/gnutls in the same archive.
The iOdus files lib/wine/x86_64-windows/windows.web.dll, twinapi.appcore.dll,
and wintypes.dll are built from the Xodus Wine 11 tree by scripts/build-runtime.sh
(the Wine source pinned in its lock file, plus the Nexus and iOdus patches).

Source offer: the release that has this runtime also has the source archives
above. If a link stops working, ask for the source through the iOdus issue
tracker; the offer is valid for three years after the release.

D3DMetal is not part of this runtime. iOdus copies it from the Game Porting
Toolkit that you installed, under Apple's license.
EOF
}

# For a local test: add D3DMetal from GPTK, as iOdus does at the install.
stage_d3dmetal() {
  OUT="$WORK/runtime/$RUNTIME_ID"
  [ -d "$GPTK/lib/external/D3DMetal.framework" ] || { echo "No D3DMetal in $GPTK" >&2; exit 1; }
  ditto "$GPTK/lib/external" "$OUT/lib/external"
  for dll in $D3DMETAL_WINDOWS; do cp "$GPTK/lib/wine/x86_64-windows/$dll" "$OUT/lib/wine/x86_64-windows/"; done
  for so in $D3DMETAL_UNIX; do rm -f "$OUT/lib/wine/x86_64-unix/$so"; cp -P "$GPTK/lib/wine/x86_64-unix/$so" "$OUT/lib/wine/x86_64-unix/"; done
  echo "== D3DMetal added to $OUT (local test only; never package this folder)"
}

# The release files: the runtime archive (without D3DMetal), its SHA-256, and the sources.
stage_package() {
  OUT="$WORK/runtime/$RUNTIME_ID"
  REL="$WORK/release"
  NAME="$RUNTIME_ID-$RUNTIME_RELEASE"
  [ -f "$OUT/runtime.json" ] || { echo "Assemble first." >&2; exit 1; }
  if [ -e "$OUT/lib/external" ]; then
    echo "The runtime folder has D3DMetal (STAGE=d3dmetal). Run STAGE=assemble again first." >&2; exit 1
  fi
  # Wine builds its own DLLs with the D3DMetal names. Apple's copies contain
  # "D3DMetal"; the Wine ones do not. Never package Apple's files.
  for name in $D3DMETAL_WINDOWS $D3DMETAL_UNIX; do
    for f in "$OUT"/lib/wine/*/"$name"; do
      [ -f "$f" ] || continue
      if LC_ALL=C grep -q -a -i 'd3dmetal' "$f"; then
        echo "Apple D3DMetal file in the runtime folder: $f. Run STAGE=assemble again first." >&2; exit 1
      fi
    done
  done
  rm -rf "$REL"; mkdir -p "$REL"
  echo "== Package $NAME"
  (cd "$WORK/runtime" && tar -cJf "$REL/$NAME.tar.xz" "$RUNTIME_ID")
  (cd "$REL" && shasum -a 256 "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
  cp "$WORK/src/$ARCHIVE" "$WORK/src/nettle-3.10.tar.gz" "$WORK/src/freetype-2.13.3.tar.xz" \
    "$WORK/src/SDL2-$SDL2_VERSION.tar.gz" "$REL/"
  cp "$OUT/SOURCES.md" "$REL/SOURCES.md"
  mkdir -p "$REL/wine11-patches" && cp "$PATCHES"/*.patch "$REL/wine11-patches/"
  ls -l "$REL"
  cat "$REL/$NAME.tar.xz.sha256"
  echo "size $(stat -f %z "$REL/$NAME.tar.xz")"
}

case "$STAGE" in
  all) stage_source; stage_deps; stage_wine; stage_assemble ;;
  source) stage_source ;;
  deps) stage_deps ;;
  wine) stage_wine ;;
  wine-make) stage_wine_make ;;
  assemble) stage_assemble ;;
  d3dmetal) stage_d3dmetal ;;
  package) stage_package ;;
  *) echo "Unknown STAGE: $STAGE" >&2; exit 1 ;;
esac
