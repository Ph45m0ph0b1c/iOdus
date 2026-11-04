# Plan: selectable game runtimes

Status: parts 1, 2, and 3 done (2026-11-03), except the publication of the release.

## Results

- Part 1 (the selector) is in iOdus: Settings > Game runtime, and Runtime on a game page.
- Part 2: `scripts/build-wine-runtime.sh` builds "CrossOver 26.3 Wine" (Wine 11.0,
  new WoW64 for 32-bit programs) with D3DMetal 3.0 from GPTK 3.0-3. DREDGE runs on it
  (sign-in, saves). The VC++ installer (a 32-bit program) runs on it.
- Forza Horizon 6 gets past its code protection on Wine 11, then stops with
  "Video Card Crash (FHG11)" in D3DMetal. CrossOver 26 users report the same.
  It needs a newer D3DMetal.
- Lessons from the build (all in the script):
  - `pipe2` is in the new SDK but not in the x86_64 libSystem under Rosetta:
    configure with `ac_cv_func_pipe2=no`.
  - CrossOver's Nettle and FreeType copies have no generated build files: the
    script uses the GNU and Savannah releases with the same sources (pinned SHA-256).
  - GnuTLS configure drops Nettle without a message when `NETTLE_LIBS` has a space.
  - The D3DMetal `.so` files are links to `lib/external/libd3dshared.dylib`; copies fail.
  - CrossOver's `windows.web`, `twinapi.appcore`, and `wintypes` are stubs. The Xodus
    versions replace them as built-in DLLs (a copy in system32 has the Wine builtin
    mark, so Wine loads its own DLL instead).
  - Release 2 adds SDL2 2.32.10 for the controller driver (winebus). Release 1
    had no SDL2, and SDL games such as Hades II found no controller.
  - `wineboot` needs `WINEDLLOVERRIDES=mscoree=;mshtml=` (no Mono or Gecko dialog),
    and `regsvr32` needs `/s`.

## The goal

The player can choose the Wine runtime for each game, as Proton lets Steam
players choose a Proton version. iOdus ships the current runtime (GPTK 3.0,
Wine 7.7) and adds a second runtime on Wine 11.

## Why

- Forza Horizon 6 runs on Linux with the Wine 11 runtime of Xodus Nexus. On
  iOdus (GPTK Wine 7.7), the code protection of the game declines to decrypt
  its code, and the game stops with "illegal instruction" (see the commit
  history from 2026-11-03). The install, AVX, and the VC++ runtime are not the
  cause.
- `docs/encrypted-dlls-plan.md`: games with encrypted DLLs need the file maps
  of the Xodus Wine (`WINE_DLL_FILE_MAP`). GPTK Wine 7.7 does not read them.
- The iOdus Xbox DLLs (`xgameruntime.dll` and others) are already built from a
  Wine 11 tree. On Wine 11, they run on the Wine version that they come from.

## The facts

- iOdus does not change Wine now. It uses the GPTK 3.0-3 Wine 7.7 build of
  Gcenx as it is, and puts Windows DLLs and proxies into the prefix.
- CrossOver 26 (February 2026) is based on Wine 11.0 and uses D3DMetal 3.0.
- CodeWeavers publishes the source under the LGPL:
  `crossover-sources-26.3.0.tar.gz` (SHA-256
  `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872`).
  Its `sources/wine` is Wine 11.0 with the CrossOver changes.
- The CrossOver Wine has the D3DMetal connection: `dlls/winemac.drv/d3dmetal.c`,
  the export `__wine_unix_call_exported` in `ntdll` ("CW HACK 22435"), and fake
  DLL entries in `loader/wine.inf.in`.
- D3DMetal is Apple's binary. GPTK 3.0-3 has D3DMetal 3.0:
  `lib/external/D3DMetal.framework`, `lib/external/libd3dshared.dylib`, and
  the PE DLLs `d3d11.dll`, `d3d12.dll`, `dxgi.dll`, `nvapi64.dll`, `nvngx.dll`,
  `nvngx-on-metalfx.dll`, and `atiadlxx.dll`. CrossOver 26 ships the same
  D3DMetal version, so these files fit the CrossOver 26 Wine.

## Part 1: the runtime selector in iOdus

1. A runtime is a folder in `~/Library/Application Support/iOdus/Runtimes/<id>`
   with a `runtime.json` (ID, name, Wine version, path of `wine64` or `wine`,
   graphics: D3DMetal, and the iOdus DLL set it needs).
2. Each runtime has its own prefix: `Prefixes/<runtime id>`. Two Wine versions
   must not share a prefix. The current `Prefix` folder becomes the prefix of
   `gptk-3.0-3`, with no move.
3. Settings has a "Default runtime" row. A game page has a "Runtime" action
   that overrides the default for that game. The choice is saved per product ID.
4. All code that uses `GameRuntime.standard` asks for the runtime of the game:
   the start, the save status, save backups, the save sync step, the VC++
   install, the log export, and "Prepare again".
5. Saves: each prefix has its own `XodusGameSave` folder. The cloud is the
   common copy. Before the first start of a game on a new runtime, iOdus tells
   the player that the save comes from the cloud. A local save that is not
   uploaded (dirty) blocks the switch until it is uploaded or backed up.
6. Tests: runtime discovery, the per-game choice, prefix paths, and the block
   for dirty saves. No Wine in the tests.

## Part 2: the Wine 11 runtime ("CrossOver 26.3 Wine")

1. Build Wine from `sources/wine` of the CrossOver 26.3 source as x86_64
   (through Rosetta, as `build-runtime.sh` does), 64-bit only
   (`--enable-win64`). GDK games are 64-bit.
2. The Mac side of Wine needs x86_64 libraries: GnuTLS (TLS for WinHTTP and
   bcrypt), FreeType (fonts), and their dependencies. Options:
   - A: an x86_64 Homebrew in `/usr/local` (fast, bottles; changes the system).
   - B: build the libraries from source into a private folder
     (`~/projects/iodus-runtimes/deps`); slower, no system change. The
     CrossOver source has GnuTLS and FreeType in `sources/`.
3. Copy D3DMetal 3.0 from the installed GPTK 3.0-3 into the new runtime
   (`lib/external` and the PE DLLs). iOdus does not ship D3DMetal; it takes
   it from the GPTK that the player installs, as now.
4. Apply the Xodus Wine patches that the Nexus runtime needs and that the
   CrossOver tree does not have, first `wine-memfd-filename.patch` and the
   file map support (`WINE_DLL_FILE_MAP`, `WINE_EXE_FILE_MAP`).
5. Prefix setup on Wine 11: the iOdus Xbox DLLs, without the proxies that
   exist only for Wine 7.7 problems (the winhttp proxy for
   WINHTTP_OPTION_URL; Wine 11 has the option). Keep the d3d11 proxy only if
   D3DMetal still answers E_INVALIDARG for multisample counts.
6. Test order: DREDGE (known good), then Shelldiver and Well Dweller, then
   Forza Horizon 6. Normal game starts by the player only.

## Part 3: shipping (published in v0.1.0)

- `STAGE=package` makes `release/crossover-26.3-3.tar.xz` (277 MB, SHA-256
  `fde679e5dba0e1c07dc8db31a70b4467808df8dcd6e3f2bcf6c2fab4bb950173`) without
  D3DMetal, plus the three source archives and SOURCES.md. The package has
  LICENSES/ (Wine, GnuTLS, Nettle, GMP, FreeType) and SOURCES.md with the
  source offer.
- `RuntimeDownload.crossover` pins that URL and SHA-256. Settings > Game runtimes
  lists it with Download (or Update for a newer release). `RuntimeInstaller`
  checks runtime.json and adds D3DMetal from the installed GPTK (runtime.json
  "d3dmetal" has the file list).
- Tested with the real package: the installer, then D3D12 and TLS in a scratch prefix.
- The release v0.1.0 has the files of `release/` next to the app.
- Before a package is published, scan every file for Apple code: a file
  made from the folder of an installed runtime contains the D3DMetal DLLs.

### The original plan of part 3

- A script `scripts/build-wine-runtime.sh` makes the runtime folder from the
  pinned source archive and its SHA-256.
- iOdus offers the runtime as a download (a GitHub release of burghr/iOdus)
  after the LGPL notes and the source offer are in place.
- The setup page lists the runtimes; GPTK 3.0 stays the default until the
  Wine 11 runtime passes the test games.

## Open questions

- Dependencies for part 2: option A or B.
- Does D3DMetal 3.0 from GPTK 3.0-3 need a newer `libd3dshared.dylib` on
  Wine 11? The first DREDGE start answers that.
