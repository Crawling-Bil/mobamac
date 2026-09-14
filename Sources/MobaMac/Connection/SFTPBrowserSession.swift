import Foundation
import NIO
import NIOFoundationCompat
import Citadel

/// Wraps Citadel's SFTPClient for the SFTP browser UI. Opened from an
/// already-connected SSHConnectionSession — see
/// SSHConnectionSession.openSFTPBrowser().
///
/// `listDirectory` returns one `SFTPMessage.Name` per readdir response page,
/// each carrying a batch of `SFTPPathComponent` entries — flatten those
/// before mapping. Directory-vs-file is read off `SFTPFileAttributes
/// .permissions` (raw POSIX mode bits) masked against S_IFMT/S_IFDIR, since
/// Citadel doesn't expose a convenience `.isDirectory` bool.
final class SFTPBrowserSession {
    private let sftp: SFTPClient

    /// POSIX file-type mask and directory bit (S_IFMT / S_IFDIR), applied to
    /// SFTPFileAttributes.permissions to tell a directory from a regular file.
    private static let posixFileTypeMask: UInt32 = 0o170000
    private static let posixDirectoryBit: UInt32 = 0o040000

    init(sftp: SFTPClient) {
        self.sftp = sftp
    }

    func listDirectory(atPath path: String) async throws -> [SFTPEntry] {
        let names = try await sftp.listDirectory(atPath: path)
        return names.flatMap(\.components).compactMap(mapEntry)
    }

    private func mapEntry(_ component: SFTPPathComponent) -> SFTPEntry? {
        let name = component.filename
        guard name != "." && name != ".." else { return nil }

        let attributes = component.attributes
        let isDir = attributes.permissions.map { ($0 & Self.posixFileTypeMask) == Self.posixDirectoryBit } ?? false
        let size = attributes.size.map { Int64($0) }
        let modified = attributes.accessModificationTime?.modificationTime

        return SFTPEntry(name: name, isDirectory: isDir, size: size, modifiedAt: modified)
    }

    func download(remotePath: String, to localURL: URL) async throws {
        let buffer = try await sftp.withFile(filePath: remotePath, flags: .read) { file in
            try await file.readAll()
        }
        try Data(buffer: buffer).write(to: localURL)
    }

    func upload(from localURL: URL, remotePath: String) async throws {
        let data = try Data(contentsOf: localURL)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await sftp.withFile(filePath: remotePath, flags: [.read, .write, .forceCreate]) { file in
            try await file.write(buffer)
        }
    }

    func createDirectory(atPath path: String) async throws {
        try await sftp.createDirectory(atPath: path)
    }

    func close() async throws {
        try await sftp.close()
    }
}
