import Foundation

/// Opens an outbound attachment without following symlinks and copies it
/// from the open descriptor, so nothing after the open depends on the path
/// string. Ported from openclaw/imsg.
enum AttachmentSource {
    enum Failure: Error {
        case notAbsolute
        case notFound          // ENOENT / ENOTDIR on a component
        case notPermitted      // EACCES / EPERM
        case symlink           // ELOOP from O_NOFOLLOW
        case notRegularFile
        case other(Int32)
    }

    static func openFile(at path: String) throws -> FileHandle {
        guard path.hasPrefix("/") else { throw Failure.notAbsolute }
        var dirFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dirFD >= 0 else { throw Failure.other(errno) }
        defer { close(dirFD) }

        let components = Array((path as NSString).pathComponents.dropFirst())
        guard let filename = components.last, !filename.isEmpty else { throw Failure.notFound }

        for component in components.dropLast() {
            let next = openat(dirFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw map(errno) }
            close(dirFD)
            dirFD = next
        }

        let fd = openat(dirFD, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw map(errno) }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw Failure.notRegularFile
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Creates `destination` exclusively with mode 0600 and copies data only
    /// (no xattrs/ACLs: quarantine flags and Finder tags stay behind).
    static func copy(_ source: FileHandle, to destination: URL) throws {
        let destFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard destFD >= 0 else { throw map(errno) }
        defer { close(destFD) }
        guard fcopyfile(source.fileDescriptor, destFD, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            throw map(errno)
        }
    }

    private static func map(_ code: Int32) -> Failure {
        switch code {
        case ENOENT, ENOTDIR: return .notFound
        case EACCES, EPERM: return .notPermitted
        case ELOOP: return .symlink
        default: return .other(code)
        }
    }
}
