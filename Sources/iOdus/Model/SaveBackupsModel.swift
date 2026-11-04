import Foundation

/// The Save backups page of a game: restore or delete the copies that iOdus
/// made of the Mac saves.
extension AppModel {
    /// The buttons of the game page. "Save backups" shows only when the title has backups.
    func hasSaveBackups(_ game: Game) -> Bool {
        if demo { return game.id == games.dropFirst().first?.id }
        guard let titleId = game.titleId else { return false }
        return SaveBackups.hasBackups(titleId: titleId, root: saveBackupRoot)
    }

    func openSaveBackups(_ game: Game) {
        loadSaveBackups(game)
        backupIndex = 0
        stack.append(.saveBackups(game.id))
    }

    func loadSaveBackups(_ game: Game) {
        if demo {
            saveBackupList = MockLibrary.saveBackups(titleId: game.titleId ?? "0")
        } else if let titleId = game.titleId {
            saveBackupList = SaveBackups.list(titleId: titleId, root: saveBackupRoot)
        } else {
            saveBackupList = []
        }
        backupIndex = min(backupIndex, max(0, saveBackupList.count - 1))
    }

    func moveBackups(_ d: Direction) {
        switch d {
        case .up: backupIndex = max(0, backupIndex - 1)
        case .down: backupIndex = min(max(0, saveBackupList.count - 1), backupIndex + 1)
        default: break
        }
    }

    func tapBackup(_ index: Int) {
        backupIndex = index
        confirm()
    }

    /// A: ask before a restore. The focus starts on Cancel, because a restore replaces the Mac save.
    func requestRestore(gameID: Game.ID) {
        guard let game = game(gameID), backupIndex < saveBackupList.count else { return }
        var prompt = InstallPrompt(game: game)
        prompt.stage = .restoreBackup(saveBackupList[backupIndex])
        prompt.focus = 1
        installPrompt = prompt
    }

    /// X: ask before a delete. The focus starts on Cancel.
    func requestDelete(gameID: Game.ID) {
        guard let game = game(gameID), backupIndex < saveBackupList.count else { return }
        var prompt = InstallPrompt(game: game)
        prompt.stage = .deleteBackup(saveBackupList[backupIndex])
        prompt.focus = 1
        installPrompt = prompt
    }

    func restoreBackup(_ backup: SaveBackup, game: Game) {
        guard !demo else {
            showToast("Demo mode cannot change saves.")
            return
        }
        guard playState.gameID != game.id else {
            showToast("Stop \(game.title) before you restore a save.")
            return
        }
        do {
            let result = try SaveBackups.restore(backup, prefix: savePrefix(for: game), root: saveBackupRoot)
            switch result {
            case .willUpload:
                showToast("The save is restored. It uploads at the next start of \(game.title).", seconds: 5)
            case .willAsk:
                showToast("The save is restored. The cloud save is newer, so Play asks which save to keep.", seconds: 6)
            }
        } catch {
            showToast("The restore failed: \(error.localizedDescription)", seconds: 6)
        }
        loadSaveBackups(game)
    }

    func deleteBackup(_ backup: SaveBackup) {
        guard !demo else {
            showToast("Demo mode cannot change saves.")
            return
        }
        do {
            try SaveBackups.delete(backup, root: saveBackupRoot)
            showToast("The backup is deleted.")
        } catch {
            showToast("The delete failed: \(error.localizedDescription)", seconds: 6)
        }
        if case .saveBackups(let id) = screen, let game = game(id) {
            loadSaveBackups(game)
            if saveBackupList.isEmpty { back() }
        }
    }
}
