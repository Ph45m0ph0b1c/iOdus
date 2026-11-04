import Darwin
import Foundation
import Security

/// Loopback TCP bridge from the Wine runtime to the xodus service socket.
///
/// Wine 7.7 (the GPTK Wine) has no AF_UNIX sockets for Windows programs, so
/// xgameruntime connects to 127.0.0.1:XODUS_BRIDGE_PORT and sends
/// XODUS_BRIDGE_KEY first. The bridge checks the key and then forwards all
/// bytes to the Unix socket. This is the same logic as startXodusBridge in
/// Xodus Nexus (src/main/xodus-service.ts).
final class XodusBridge: @unchecked Sendable {
    let port: UInt16
    let key: String
    private let keyBytes: [UInt8]
    private let socketPath: String
    private let listener: Int32
    private let lock = NSLock()
    private var open = Set<Int32>()
    private var stopped = false

    var environment: [String: String] {
        ["XODUS_BRIDGE_PORT": String(port), "XODUS_BRIDGE_KEY": key]
    }

    init(socketPath: String) throws {
        self.socketPath = socketPath
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw BackendError.failed("Could not make a key for the bridge.")
        }
        key = random.map { String(format: "%02x", $0) }.joined()
        keyBytes = Array(key.utf8)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BackendError.failed("Could not open the bridge socket.") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw BackendError.failed("Could not start the bridge on 127.0.0.1.")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: addr.sin_port)
        listener = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fds = open
        open.removeAll()
        lock.unlock()
        shutdown(listener, SHUT_RDWR)
        close(listener)
        for fd in fds { shutdown(fd, SHUT_RDWR) }
    }

    deinit { stop() }

    // MARK: - Connections

    private func track(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stopped { return false }
        open.insert(fd)
        return true
    }

    private func untrack(_ fd: Int32) {
        lock.lock()
        open.remove(fd)
        lock.unlock()
        close(fd)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // The listener is closed.
            }
            guard track(client) else { close(client); return }
            Thread.detachNewThread { [self] in handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // The key must come in 10 seconds.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var supplied = [UInt8](repeating: 0, count: keyBytes.count)
        guard Self.readExactly(client, &supplied), Self.constantTimeEqual(supplied, keyBytes) else {
            untrack(client)
            return
        }
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))

        let upstream = Self.connectUnix(socketPath)
        guard upstream >= 0 else { untrack(client); return }
        guard track(upstream) else { close(upstream); untrack(client); return }

        let group = DispatchGroup()
        for (from, to) in [(client, upstream), (upstream, client)] {
            group.enter()
            Thread.detachNewThread {
                Self.pump(from: from, to: to)
                group.leave()
            }
        }
        group.wait()
        untrack(upstream)
        untrack(client)
    }

    private static func pump(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            guard writeAll(to, buffer, count) else { break }
        }
        shutdown(to, SHUT_WR)
        shutdown(from, SHUT_RD)
    }

    private static func writeAll(_ fd: Int32, _ buffer: [UInt8], _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let sent = buffer.withUnsafeBytes { write(fd, $0.baseAddress! + offset, count - offset) }
            if sent < 0 && errno == EINTR { continue }
            if sent <= 0 { return false }
            offset += sent
        }
        return true
    }

    private static func readExactly(_ fd: Int32, _ buffer: inout [UInt8]) -> Bool {
        var offset = 0
        while offset < buffer.count {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return false }
            offset += count
        }
        return true
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }

    static func connectUnix(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { close(fd); return -1 }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return -1 }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}
