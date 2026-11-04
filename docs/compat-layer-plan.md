# The iOdus compatibility layer

Agreed on 2026-11-03. This plan sets where a fix for a game goes, so that new
games do not need new DLLs.

## The model

The iOdus runtime is one compatibility layer, in the same way as Valve's
Proton: a patched Wine, a small number of extra parts, and a per-game settings
list, in one versioned package.

1. **Wine 11 is the main runtime.** GPTK 3.0-3 (Wine 7.7) stays as a frozen
   fallback. Do not add new GPTK-only work unless a game needs it and Wine 11
   cannot run that game.
2. **Fixes for Windows APIs go into Wine 11 as patches** in
   `scripts/wine11-patches`, not as extra DLLs. A patch helps all games.
3. **Separate DLLs only for two cases:**
   - A difference in D3DMetal, which iOdus cannot change (for example the
     `d3d11.dll` proxy).
   - A gap in the GPTK Wine, while GPTK is still in use.
4. **Per-game fixes are data**, never DLLs: environment variables and registry
   values in `Sources/iOdus/Model/GameCompat.swift`, each with its reason.
5. **One package, one list.** The runtime release and `runtime.json` list all
   parts that iOdus changes. The diagram "iOdus Runtime Stack" shows them.

## Where a fix goes

| The problem | The fix | Example |
|---|---|---|
| Wine has no API set entry | One line in `apisetschema.spec` (Wine 11 patch); a forwarder DLL for GPTK | DIRT 5: `api-ms-win-core-debug-minidump-l1-1-0` |
| A Windows function is missing or wrong in Wine | Wine 11 patch | `winebus` input gate |
| The Xbox GDK runtime | Patch to `xgameruntime` | Title presence, save conflicts |
| D3DMetal answers differently from Windows | First a D3DMetal setting (`D3DM_*`); a proxy DLL only when no setting exists | DIRT 5 depth bounds: `D3DM_EXE_OVERRIDE=GoWR.exe` |
| One game needs a setting | Entry in `GameCompat.swift` | DIRT 5 |

## The current parts

| Part | Kind | Runtime |
|---|---|---|
| `xgameruntime.dll` with 6 patches | Wine code | both |
| `windows.web`, `twinapi.appcore`, `wintypes` (Xodus versions) | Wine code; built in for Wine 11, files for GPTK | both |
| `winebus-input-gate.patch` | Wine 11 patch | Wine 11 |
| `apisetschema-debug-minidump.patch` | Wine 11 patch | Wine 11 |
| `api-ms-win-core-debug-minidump-l1-1-0.dll` | Forwarder | GPTK |
| `api-ms-win-core-psm-appnotify-l1-1-0.dll` | Forwarder | both (the GPTK Wine has stubs) |
| `winhttp.dll` proxy | Proxy for a Wine 7.7 gap | GPTK |
| `d3d11.dll` proxy | Proxy for a D3DMetal difference | GPTK |

## Licenses

The Wine-derived DLLs and the Wine patches are under the GNU LGPL. A shared
build must offer their source and the patches. The forwarders, the proxies, and
`GameCompat.swift` are iOdus code.

## Own the code

The build depends only on Wine (CrossOver), the Xodus repositories, and this
repository. The Nexus runtime patches are copied into
`scripts/nexus-runtime-patches` (MIT, with `NOTICE.md`). iOdus removed the 6
patches for DLLs that it does not ship. The backend fork has each Nexus patch as
one commit, without changes, so that a diff against Nexus shows only the iOdus
changes. Each copied area is replaced with iOdus code over time, with tests and
with real games before the switch. A replaced area can then drop its Linux-only
code.

## Next steps

- Check which GPTK-only parts Wine 11 makes unnecessary, and stop adding new
  ones.
- Move the `xgameruntime` patches into the Wine 11 build, so that the runtime
  package has them built in.
- Decide whether new installs use Wine 11 as the default without the setup
  step (needs a public download location for the runtime).
