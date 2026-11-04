import AppKit
import Foundation

extension AppModel {
    /// Settings: make the zip file for a bug report on the Desktop, then show it in Finder.
    func exportLogs() {
        guard !exportingLogs else { return }
        guard !demo else {
            showToast("Demo mode has no logs to export.")
            return
        }
        exportingLogs = true
        let sources = logExportSources()
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try LogExport.export(sources, to: desktop) }
            }.value
            exportingLogs = false
            switch result {
            case .success(let zip):
                showToast("The logs are in \(zip.lastPathComponent) on the Desktop.", seconds: 5)
                NSWorkspace.shared.activateFileViewerSelecting([zip])
            case .failure(let error):
                showToast("iOdus could not export the logs. \(error.localizedDescription)", seconds: 6)
            }
        }
    }

    func logExportSources() -> LogExport.Sources {
        let entries = downloads.installs.values.map { install in
            LogExport.GameEntry(title: install.title, productId: install.productId,
                                titleId: self.games.first { $0.id == install.productId }?.titleId, path: install.path)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return LogExport.Sources(
            logFolder: GameLauncher.logFolder,
            prefix: defaultRuntime.prefix,
            runtimeRoot: defaultRuntime.root,
            lockFile: backendCLI.map(BackendInfo.lockFile(for:)),
            games: entries,
            accountName: accountName,
            appVersion: version.map { "\($0) (build \(build ?? "?"))" } ?? "development build",
            backendVersion: backendInfo?.version,
            runtimeStatus: runtimeStatus)
    }
}
