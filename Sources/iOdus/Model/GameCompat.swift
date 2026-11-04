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
    ]

    static func environment(for productId: String) -> [String: String] {
        environment[productId.uppercased()] ?? [:]
    }
}
