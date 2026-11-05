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

    static func environment(for productId: String) -> [String: String] {
        environment[productId.uppercased()] ?? [:]
    }
}
