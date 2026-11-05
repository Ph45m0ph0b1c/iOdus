# Code from other projects in this folder

| Files | Source | License |
|---|---|---|
| `nexus-playfab-save-folder.c`, `nexus-playfab-save-folder.def`, `nexus-playfab-session.c`, `nexus-playfab-session.h` | [Xodus Nexus](https://github.com/domsvoboda/xodus-nexus), `scripts/runtime-compat` (`playfab-save-folder.*`, `playfab-session.*`). Unchanged, except the name of the included header. | MIT, see `scripts/nexus-runtime-patches/LICENSE-nexus-MIT.txt` |
| `highball-d3d12-shim.c`, `highball-d3d12-shim.def` | [Highball](https://github.com/gauthierpiarrette/highball), `spike/tsshim`. Unchanged, except the export name in the `.def` file (`d3d12_iodus.dll`). | GPL-3.0, the same as iOdus |

The Gaming Services version that iOdus writes at a game start
(`GameRuntime.applyGamingServicesVersion`) follows Xodus Nexus,
`scripts/runtime-compat/gaming-services-version.c` (MIT).

`iodus-wine-launch` does on macOS what the Xodus Nexus `wine-launcher.c` does
on Linux for the PlayFab save proxy. It is written for iOdus.

Thanks to the Xodus Nexus and Highball projects, and to MACxus, whose notes on
Forza Horizon 6 on Apple Silicon showed the order of the problems.
