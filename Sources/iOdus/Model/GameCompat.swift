import Foundation

/// Environment variables that single games need to start, by product ID.
/// Each entry says why. iOdus adds them at the game start, for all runtimes.
enum GameCompat {
    static let environment: [String: [String: String]] = [
        // DIRT 5 stops with "The chosen D3D device doesn't support depth bounds
        // testing". D3DMetal has depth bounds support, but turns it on only for
        // God of War Ragnarök. With the executable name of that game, D3DMetal
        // reports the feature (tested: D3D12_FEATURE_D3D12_OPTIONS2).
        "9PJGM0T0827V": ["D3DM_EXE_OVERRIDE": "GoWR.exe"],
        // Forza Horizon 6: the game package (9NR1R1XWLCNB, the ID of an install),
        // and the Standard and Premium Edition bundles. D3DMetal reports an
        // AMD GPU, and the game then takes an AMD-only path and crashes. With an
        // Intel GPU it starts (found by Highball). The game also needs D3DMetal 4
        // (the crossover-26.3-d3dm4 runtime): with D3DMetal 3 it stops with FH205.
        // Grim Fandango Remastered asks for an OpenGL 3.3 core context without
        // the forward-compatible flag. macOS has only forward-compatible core
        // contexts, so the Mac driver refuses it; CrossOver's switch adds the
        // flag (issue #4; the Wine 11 runtime also needs winemac-wgl-no-error.patch).
        "9PC288TN7R8K": ["CX_FWD_COMPAT_GL_CTX": "1"],
        "9NR1R1XWLCNB": forzaHorizon6,
        "9N431PX143P8": forzaHorizon6,
        "9N4XW3N02MNJ": forzaHorizon6,
    ]

    private static let forzaHorizon6 = [
        // The game's PlayFab save library stops with E:0-17-4 without the save
        // proxy from Xodus Nexus (iodus-wine-launch puts it in front).
        "IODUS_PLAYFAB_ADAPTER": "1",
        "D3DM_VENDOR_ID": "0x8086",
        "D3DM_DEVICE_ID": "0x56a1",
        "D3DM_DEVICE_DESCRIPTION": "Intel(R) Arc(TM) A750 Graphics",
    ]

    /// Games that run only with one runtime. Such a game uses that runtime when it
    /// is installed and the player did not choose a runtime for the game.
    static let requiredRuntime: [String: String] = [
        // Forza Horizon 6 needs DirectX 12 enhanced barriers: D3DMetal 4 only.
        "9NR1R1XWLCNB": d3dmetal4Runtime,
        "9N431PX143P8": d3dmetal4Runtime,
        "9N4XW3N02MNJ": d3dmetal4Runtime,
        // Minecraft Legends: D3D12 GDK title requires D3DMetal 4 runtime.
        "9N98Z825TNFW": d3dmetal4Runtime,
        "9MV69L4JSD31": d3dmetal4Runtime,
    ]

    static let d3dmetal4Runtime = RuntimeDownload.crossoverD3DMetal4.id

    static func requiredRuntime(for productId: String) -> String? {
        requiredRuntime[productId.uppercased()]
    }

    static func environment(for productId: String) -> [String: String] {
        environment[productId.uppercased()] ?? [:]
    }
}
