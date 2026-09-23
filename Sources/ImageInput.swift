import Foundation
import Darwin

enum ImageInput {
    static func accepts(_ url: URL) -> Bool {
        url.isFileURL && ["dmg", "iso"].contains(url.pathExtension.lowercased())
    }

    /// Normalize only the selected filename. Atomic rename preserves bytes and
    /// attributes and never overwrites an existing destination or runs a converter.
    static func prepare(_ url: URL) throws -> URL {
        guard accepts(url) else { throw InstallFailure(message: "请选择 DMG 或 ISO 文件。") }
        let source = url.standardizedFileURL
        guard source.pathExtension.lowercased() == "iso" else {
            return source.resolvingSymlinksInPath()
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw InstallFailure(message: "ISO 必须是普通文件，无法重命名文件夹或符号链接。")
        }
        // Renaming a mounted image would leave hdiutil tracking its old path.
        // Keep the existing protection against touching a user's mounted disks.
        let mountedData = try SystemCommand.checked("/usr/bin/hdiutil", ["info", "-plist"], timeout: 30)
        guard let mountedInfo = try PropertyListSerialization.propertyList(from: mountedData, format: nil) as? [String: Any],
              let images = mountedInfo["images"] as? [[String: Any]] else {
            throw InstallFailure(message: "无法读取已挂载映像列表，请稍后重试。")
        }
        let canonical = source.resolvingSymlinksInPath().standardizedFileURL
        guard !images.contains(where: { image in
            guard let path = image["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL == canonical
        }) else { throw InstallFailure(message: "这个 ISO 已经打开，请先在 Finder 弹出它再重试。") }
        let stem = source.deletingPathExtension().lastPathComponent
        let parent = source.deletingLastPathComponent()
        for index in 1...1000 {
            let name = index == 1 ? "\(stem).dmg" : "\(stem) (\(index)).dmg"
            let destination = parent.appendingPathComponent(name)
            let status = source.withUnsafeFileSystemRepresentation { from in
                destination.withUnsafeFileSystemRepresentation { to in
                    renamex_np(from!, to!, UInt32(RENAME_EXCL))
                }
            }
            if status == 0 { return destination.resolvingSymlinksInPath().standardizedFileURL }
            let code = errno
            if code != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        throw InstallFailure(message: "同名文件过多，无法生成新的 DMG 文件名。")
    }
}
