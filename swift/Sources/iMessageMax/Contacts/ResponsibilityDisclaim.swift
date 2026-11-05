import Darwin
import Foundation

/// Spawns a process that macOS treats as responsible for itself.
///
/// TCC records a grant against the *responsible* process. Run from Terminal,
/// imessage-max's Contacts request is attributed to Terminal, so the grant
/// lands there; Claude desktop then launches the server through its
/// `disclaimer` helper, the server is its own responsible process, and it
/// finds no grant (`not_determined`). Re-spawning disclaimed makes the
/// request, the prompt, and the grant all belong to imessage-max.
///
/// The two responsibility calls are private libsystem API (the same ones
/// Claude's disclaimer helper and Chromium use), looked up at runtime so a
/// missing symbol is an error rather than a link failure.
enum ResponsibilityDisclaim {
    enum Failure: Error, CustomStringConvertible {
        case symbolMissing(String)
        case spawnFailed(path: String, errno: Int32)

        var description: String {
            switch self {
            case .symbolMissing(let name):
                return "\(name) is not available on this macOS, so the Contacts request cannot be attributed to imessage-max"
            case .spawnFailed(let path, let code):
                return "posix_spawn \(path) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    /// Spawn `path` with inherited stdio and environment (plus `extraEnvironment`).
    static func spawn(
        path: String,
        arguments: [String],
        disclaim: Bool,
        extraEnvironment: [String: String] = [:]
    ) throws -> pid_t {
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }

        if disclaim {
            guard let setDisclaim = symbol("responsibility_spawnattrs_setdisclaim", as: SetDisclaim.self) else {
                throw Failure.symbolMissing("responsibility_spawnattrs_setdisclaim")
            }
            let rc = setDisclaim(&attrs, 1)
            guard rc == 0 else { throw Failure.spawnFailed(path: path, errno: rc) }
        }

        var environment = ProcessInfo.processInfo.environment
        environment.merge(extraEnvironment) { _, new in new }
        let envStrings = environment.map { "\($0.key)=\($0.value)" }
        let argStrings = [path] + arguments

        let argv = argStrings.map { strdup($0) } + [nil]
        let envp = envStrings.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, nil, &attrs, argv, envp)
        guard rc == 0 else { throw Failure.spawnFailed(path: path, errno: rc) }
        return pid
    }

    /// Wait for `pid` and return its exit status (128 + signal if it was killed).
    static func wait(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// The process macOS holds responsible for `pid`, or nil if unknown.
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let responsibleFor = symbol("responsibility_get_pid_responsible_for_pid", as: ResponsibleFor.self) else {
            return nil
        }
        let responsible = responsibleFor(pid)
        return responsible > 0 ? responsible : nil
    }
}
