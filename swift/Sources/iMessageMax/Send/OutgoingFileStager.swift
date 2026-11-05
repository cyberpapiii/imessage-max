import Foundation

/// Private per-send copies of outbound attachments.
///
/// Messages.app is handed a copy under `root`, never the caller's path, so
/// the transfer cannot be redirected by changing the source after
/// validation, and so it can be tracked by name. Each send gets its own
/// UUID directory, holding the file under its original name.
struct OutgoingFileStager: Sendable {
    static let directoryName = "imessage-max-staging"

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// A validated, open source file. Close it once staged.
    struct Source {
        let path: String
        let handle: FileHandle

        var trackingName: String { (path as NSString).lastPathComponent }

        func close() { try? handle.close() }
    }

    struct StagedFile: Sendable {
        let fileURL: URL
        /// The original filename. Messages names the outgoing transfer after it.
        let trackingName: String
    }

    let root: URL

    init(root: URL = OutgoingFileStager.defaultRoot) {
        self.root = root
    }

    /// Lexically absolutize, refuse symlinks anywhere in the path, then open
    /// the file without following links and confirm it is a regular file.
    /// Error text never contains the caller's path, only the basename.
    func openSource(_ filePath: String) throws -> Source {
        let basename = (filePath as NSString).lastPathComponent
        guard let lexical = SecurePath.absoluteLexicalPath(filePath) else {
            throw SendError.invalidParams("Attachment path for '\(basename)' must be absolute (or start with ~/).")
        }
        if SecurePath.hasSymlinkComponent(lexical) {
            throw SendError.invalidParams("Attachment '\(basename)' is or is behind a symbolic link; pass the real path.")
        }
        do {
            return Source(path: lexical, handle: try AttachmentSource.openFile(at: lexical))
        } catch AttachmentSource.Failure.symlink {
            throw SendError.invalidParams("Attachment '\(basename)' is or is behind a symbolic link; pass the real path.")
        } catch AttachmentSource.Failure.notRegularFile {
            throw SendError.invalidParams("Attachment '\(basename)' must be a regular file.")
        } catch AttachmentSource.Failure.notAbsolute {
            throw SendError.invalidParams("Attachment path for '\(basename)' must be absolute (or start with ~/).")
        } catch {
            // notFound, notPermitted, other: one client-facing wording.
            throw SendError.fileNotFound(basename)
        }
    }

    /// Copies `source` into a fresh owner-only directory under `root`.
    func stage(_ source: Source) throws -> StagedFile {
        let trackingName = source.trackingName
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        // Checked before anything is created or chmodded: both follow links,
        // so a symlinked root would otherwise re-permission its target.
        guard !SecurePath.hasSymlinkComponent(root.path) else {
            throw SendError.invalidParams("Attachment staging directory is behind a symbolic link.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: ownerOnly)
        try FileManager.default.setAttributes(ownerOnly, ofItemAtPath: root.path)   // pre-existing 0755 roots

        let stagedDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedURL = stagedDirectory.appendingPathComponent(trackingName, isDirectory: false)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: false, attributes: ownerOnly)

        let staged = StagedFile(fileURL: stagedURL, trackingName: trackingName)
        do {
            try AttachmentSource.copy(source.handle, to: stagedURL)
        } catch {
            remove(staged)
            throw SendError.fileNotFound(trackingName)
        }
        return staged
    }

    /// Removes one per-send staging directory. Safe only at terminal
    /// transfer states (finished/failed) or before Messages was handed the
    /// file, never while a transfer may still be reading the copy.
    /// Guarded to the staging root so a bug can never delete anything else.
    func remove(_ staged: StagedFile) {
        let directory = staged.fileURL.deletingLastPathComponent()
        let rootPath = root.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath.hasPrefix(rootPath + "/"), directoryPath != rootPath else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Messages may still be reading the staged copy for a few seconds after
    /// a timed-out poll. Delete after a grace delay, not 48 hours later.
    func scheduleRemoval(_ staged: StagedFile, after delay: Duration) {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + AsyncTimeout.dispatchInterval(for: delay)
        ) {
            remove(staged)
        }
    }

    /// Deletes staging entries older than an hour, left behind by sends whose
    /// deferred removal never ran (the process exited first).
    func sweepExpired() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-1 * 60 * 60)
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
