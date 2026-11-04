import Darwin
import Foundation

/// Finds `xodus-cli` processes that an earlier iOdus left behind, for example
/// after a force quit. Their parent is then launchd (PID 1). An orphan
/// download holds the lock of its folder, so a new download cannot start.
enum Orphans {
    struct Entry: Equatable {
        let pid: pid_t
        let parent: pid_t
        let command: String
    }

    /// All processes with their parent and command line, from `ps`.
    static func processes() -> [Entry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), let parent = pid_t(parts[1]) else { return nil }
            return Entry(pid: pid, parent: parent, command: String(parts[2]))
        }
    }

    /// Orphans of `cli` whose arguments start with `arguments`.
    static func find(cli: URL, arguments: [String], in list: [Entry] = processes()) -> [pid_t] {
        let prefix = ([cli.path] + arguments).joined(separator: " ")
        return list.filter { entry in
            entry.parent == 1 && (entry.command == prefix || entry.command.hasPrefix(prefix + " "))
        }.map(\.pid)
    }

    /// Sends SIGINT, so that the CLI stops in its normal way and keeps its
    /// files. Waits up to `timeout` seconds. Returns true when all stopped.
    static func stop(_ pids: [pid_t], timeout: TimeInterval = 15) async -> Bool {
        for pid in pids { kill(pid, SIGINT) }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if pids.allSatisfy({ kill($0, 0) != 0 }) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return pids.allSatisfy { kill($0, 0) != 0 }
    }
}
