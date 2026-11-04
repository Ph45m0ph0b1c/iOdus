# Patches from Xodus Nexus

The patches in this folder come from [Xodus Nexus](https://github.com/domsvoboda/xodus-nexus),
commit `6100e3a7ddb1acdbf0259c8c32fe66e7b17394f0` (folder `assets/`), under the
MIT License. The license text is in `LICENSE-nexus-MIT.txt`:

> Copyright (c) 2026 Xodus Nexus contributors

iOdus keeps a copy, so that the build does not need the Nexus repository. iOdus
maintains these patches from here on. The plan is to replace them, area by area,
with iOdus code (see `docs/compat-layer-plan.md`).

The patches change the Xodus Wine source (`xodus-gaming/wine`) and its
`xgameruntime` submodule (`xodus-gaming/xgameruntime`). Those changed files are
Wine code under the LGPL 2.1 or later.

## Changes to the Nexus set

`lock.json` lists the patches in the order of the build, with their SHA-256
values. The order and the content of each patch are the same as in Nexus.

iOdus removed 6 of the 42 Nexus runtime patches, because the macOS build does not
use the DLLs that they change:

| Patch | Reason |
|---|---|
| `wine-winhttp-http2.patch` | iOdus does not ship the Wine `winhttp.dll`. It has its own `winhttp` proxy (`scripts/runtime-compat`). |
| `wine-winhttp-private-diagnostics-disabled.patch` | The same: no Wine `winhttp.dll`. |
| `wine-winhttp-gdk-options.patch` | The same: no Wine `winhttp.dll`. |
| `wine-winhttp-response-options.patch` | The same: no Wine `winhttp.dll`. |
| `wine-mscoree-mono-path-bounds.patch` | iOdus does not ship `mscoree.dll`. |
| `wine-hlsl-state-keywords.patch` | A vkd3d patch. iOdus uses D3DMetal, not vkd3d. |

Without the HTTP/2 patch, the build no longer needs nghttp2.
