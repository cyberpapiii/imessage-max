import Foundation

struct OutgoingFileStager: Sendable {
    static let directoryName = "imessage-max-staging"

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    struct Source {
        let path: String
        let handle: FileHandle

        var trackingName: String { (path as NSString).lastPathComponent }

        func close() { try? handle.close() }
    }

    struct StagedFile: Sendable {
        let fileURL: URL
        let trackingName: String
    }

    let root: URL

    init(root: URL = OutgoingFileStager.defaultRoot) {
        self.root = root
    }

    func openSource(_ filePath: String) throws -> Source {
        let basename = (filePath as NSString).lastPathComponent
        guard let lexical = SecurePath.absoluteLexicalPath(filePath) else {
            throw SendError.invalidParams("The attachment path for '\(basename)' must be absolute or start with ~/.")
        }
        if SecurePath.hasSymlinkComponent(lexical) {
            throw SendError.invalidParams("Attachment '\(basename)' is a symbolic link, or a folder in its path is one. Pass the real path.")
        }
        do {
            return Source(path: lexical, handle: try AttachmentSource.openFile(at: lexical))
        } catch AttachmentSource.Failure.symlink {
            throw SendError.invalidParams("Attachment '\(basename)' is a symbolic link, or a folder in its path is one. Pass the real path.")
        } catch AttachmentSource.Failure.notRegularFile {
            throw SendError.invalidParams("Attachment '\(basename)' must be a regular file.")
        } catch AttachmentSource.Failure.notAbsolute {
            throw SendError.invalidParams("The attachment path for '\(basename)' must be absolute or start with ~/.")
        } catch {
            throw SendError.fileNotFound(basename)
        }
    }

    func stage(_ source: Source) throws -> StagedFile {
        let trackingName = source.trackingName
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        // Check this before creating or chmodding anything. Both operations follow
        // links, so a symlinked root would otherwise change its target's permissions.
        guard !SecurePath.hasSymlinkComponent(root.path) else {
            throw SendError.invalidParams("The attachment staging directory, or a folder in its path, is a symbolic link.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: ownerOnly)
        try FileManager.default.setAttributes(ownerOnly, ofItemAtPath: root.path)   // fixes a root that already exists with 0755

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

    func remove(_ staged: StagedFile) {
        let directory = staged.fileURL.deletingLastPathComponent()
        let rootPath = root.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath.hasPrefix(rootPath + "/"), directoryPath != rootPath else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func scheduleRemoval(_ staged: StagedFile, after delay: Duration) {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + AsyncTimeout.dispatchInterval(for: delay)
        ) {
            remove(staged)
        }
    }

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
