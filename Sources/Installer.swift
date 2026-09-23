import Foundation
import Darwin

struct FileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    static func read(_ url: URL) throws -> FileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileIdentity(device: info.st_dev, inode: info.st_ino,
                            modifiedSeconds: info.st_mtimespec.tv_sec,
                            modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }
}

struct ImageMember: Hashable, Sendable {
    let volumeIndex: Int
    let path: String
}

struct DeferredApplication: Sendable {
    let imageURL: URL
    let imageIdentity: FileIdentity
    let imageChain: [ImageMember]
    let application: ImageMember
}

struct PendingReplacement: Identifiable, Sendable {
    let id = UUID()
    let stagedApp: URL?
    let target: URL
    let originalIdentity: FileIdentity
    let stagedIdentity: FileIdentity?
    var source: DeferredApplication? = nil
    var name: String { target.lastPathComponent }
}

struct ReplacementResult: Sendable {
    var warning: String?
    var oldAppInTrash: URL?
}

struct InstallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CommandResult {
    let status: Int32
    let output: Data
    let diagnostic: String
}

/// Runs only fixed system executables, with separate arguments and no shell.
enum SystemCommand {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 180) throws -> CommandResult {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("DropInstall-command-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        let outURL = scratch.appendingPathComponent("stdout")
        let errURL = scratch.appendingPathComponent("stderr")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // Files avoid pipe-buffer deadlocks with large diagnostic output.
        process.standardOutput = out
        process.standardError = err
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        if completion.wait(timeout: .now() + timeout) == .timedOut && process.isRunning {
            process.terminate()
            _ = completion.wait(timeout: .now() + 2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw InstallFailure(message: "操作超时，请手动检查这个磁盘映像后重试。")
        }
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus,
                             output: try Data(contentsOf: outURL),
                             diagnostic: String(decoding: try Data(contentsOf: errURL), as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func checked(_ executable: String, _ arguments: [String], timeout: TimeInterval = 180) throws -> Data {
        let result = try run(executable, arguments, timeout: timeout)
        guard result.status == 0 else {
            let detail = result.diagnostic.split(separator: "\n")
                .filter { !$0.contains("WARNING:") }.last.map(String.init) ?? ""
            let message = detail.replacingOccurrences(of: "hdiutil: attach failed - ", with: "无法打开磁盘映像：")
            throw InstallFailure(message: message.isEmpty ? "系统操作失败（\(result.status)）。" : message)
        }
        return result.output
    }
}

struct InstallReport: Sendable {
    var installed: [String] = []
    var skipped: [String] = []
    var pending: [PendingReplacement] = []
    var problems: [String] = []
    var replacementProblems: [UUID: String] = [:]
    var backupsInTrash: [URL] = []
    var ejected = false
    var imageIdentity: FileIdentity?
    var imageInTrash: URL?
    var imageTrashError: String?
    var nestedImages: [String] = []
    var completedReplacements: [UUID] = []

    var readyToTrashImage: Bool {
        !installed.isEmpty && pending.isEmpty && skipped.isEmpty && problems.isEmpty
            && replacementProblems.isEmpty && ejected && imageInTrash == nil
    }

    var detail: String {
        var lines: [String] = []
        if !nestedImages.isEmpty { lines.append("已查找内层映像：" + nestedImages.joined(separator: "、")) }
        if !installed.isEmpty { lines.append("已安装：" + installed.joined(separator: "、")) }
        if !pending.isEmpty { lines.append("重名待确认：" + pending.map(\.name).joined(separator: "、")) }
        if !skipped.isEmpty { lines.append("已保留现有版本：" + skipped.joined(separator: "、")) }
        if !backupsInTrash.isEmpty { lines.append("覆盖前的旧版已移入废纸篓") }
        lines += problems
        lines += replacementProblems.values.sorted()
        if ejected { lines.append(imageInTrash == nil ? "磁盘已弹出 · 原 DMG 已保留" : "磁盘已弹出 · DMG 已移入废纸篓") }
        if let imageTrashError { lines.append(imageTrashError) }
        return lines.joined(separator: "\n")
    }
}

struct DiskInstaller: Sendable {
    let destination: URL
    let searchRules: [ImageSearchRule]
    static let maximumImageDepth = 2 // Root plus two nested image layers.
    static let maximumImageCount = 16
    private var fm: FileManager { FileManager.default }

    init(destination: URL = URL(fileURLWithPath: "/Applications", isDirectory: true), searchRules: [ImageSearchRule] = ImageSearchRule.defaults) {
        self.destination = destination
        self.searchRules = searchRules.filter { $0.enabled && $0.isValid }
    }

    private struct MountedImage {
        let device: String
        let volumes: [URL]
    }

    private func imageList() throws -> [[String: Any]] {
        let data = try SystemCommand.checked("/usr/bin/hdiutil", ["info", "-plist"], timeout: 30)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            throw InstallFailure(message: "无法读取已挂载磁盘列表。")
        }
        return images
    }

    private func ownedImages(in mountRoot: URL) throws -> [MountedImage] {
        Self.mounts(in: try imageList(), ownedBy: mountRoot)
    }

    private static func mounts(in images: [[String: Any]], ownedBy mountRoot: URL) -> [MountedImage] {
        images.compactMap { image in
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let volumes = entities.compactMap { ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0) } }
            guard !volumes.isEmpty,
                  volumes.allSatisfy({ isInside($0, root: mountRoot) }),
                  let device = entities.compactMap({ $0["dev-entry"] as? String }).first,
                  device.hasPrefix("/dev/disk") else { return nil }
            return MountedImage(device: device, volumes: volumes)
        }
    }

    static func isInside(_ url: URL, root: URL) -> Bool {
        let rootParts = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return parts.count > rootParts.count && Array(parts.prefix(rootParts.count)) == rootParts
    }

    /// Serial callers only. Never executes the downloaded app or changes Gatekeeper settings.
    func install(_ imageURL: URL, progress: @Sendable (String) -> Void = { _ in }) -> InstallReport {
        var remainingImages = Self.maximumImageCount
        let report = processImage(imageURL, quarantineSource: imageURL, chain: [], approvals: nil, depth: 0, remainingImages: &remainingImages, progress: progress)
        return Self.finishImage(imageURL, report: report)
    }

    private func processImage(_ imageURL: URL, quarantineSource: URL, chain: [ImageMember],
                              approvals: [PendingReplacement]?, depth: Int,
                              remainingImages: inout Int, progress: @Sendable (String) -> Void,
                              replacementCheck: @Sendable (URL) -> String? = { _ in nil },
                              originalImageIdentity: FileIdentity? = nil) -> InstallReport {
        var report = InstallReport()
        let mountRoot = fm.temporaryDirectory.appendingPathComponent("DropInstall-mount-\(UUID().uuidString)", isDirectory: true)
        var createdMountRoot = false
        var attached = false
        var childrenEjected = true
        do {
            guard depth <= Self.maximumImageDepth, remainingImages > 0 else {
                throw InstallFailure(message: "嵌套映像达到处理上限（最多 3 层、16 个映像），请手动检查。")
            }
            remainingImages -= 1
            guard imageURL.isFileURL, imageURL.pathExtension.lowercased() == "dmg",
                  (try imageURL.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                throw InstallFailure(message: "请选择本机可读取的 .dmg 文件。")
            }
            report.imageIdentity = try FileIdentity.read(imageURL)
            if depth == 0, let originalImageIdentity, report.imageIdentity != originalImageIdentity {
                throw InstallFailure(message: "原 DMG 自待定后发生变化，请重新添加文件。")
            }
            let canonical = imageURL.resolvingSymlinksInPath().standardizedFileURL
            let alreadyMounted = try imageList().contains { image in
                guard let path = image["image-path"] as? String else { return false }
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL == canonical
            }
            guard !alreadyMounted else {
                throw InstallFailure(message: "这个 DMG 已经打开，请先在 Finder 弹出它再重试。")
            }
            var isDirectory: ObjCBool = false
            if !fm.fileExists(atPath: destination.path, isDirectory: &isDirectory),
               destination.standardizedFileURL == fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL {
                try fm.createDirectory(at: destination, withIntermediateDirectories: false)
                isDirectory = true
            }
            guard isDirectory.boolValue, fm.isWritableFile(atPath: destination.path) else {
                throw InstallFailure(message: "没有目标文件夹的写入权限。可切换到「仅我使用」，或联系管理员。")
            }
            try fm.createDirectory(at: mountRoot, withIntermediateDirectories: false)
            createdMountRoot = true
            progress(depth == 0 ? "正在打开磁盘映像…" : "正在打开内层映像：\(imageURL.lastPathComponent)…")
            // EOF on stdin ensures password/license prompts cannot hang unattended.
            let attachData = try SystemCommand.checked("/usr/bin/hdiutil", ["attach", imageURL.path, "-readonly", "-nobrowse", "-noautoopen", "-mountroot", mountRoot.path, "-plist"])
            guard let attachInfo = try PropertyListSerialization.propertyList(from: attachData, format: nil) as? [String: Any] else {
                throw InstallFailure(message: "无法读取挂载结果。")
            }
            // attach already returns the device and volume list; avoid another process.
            let mounts = Self.mounts(in: [attachInfo], ownedBy: mountRoot)
            attached = !mounts.isEmpty
            guard attached else { throw InstallFailure(message: "映像未挂载到安装临时目录，无法自动处理。") }
            let volumes = mounts.flatMap(\.volumes)
            let apps: [(URL, ImageMember)]
            let nested: [(URL, ImageMember)]
            if let approvals {
                let selectedApps = approvals.compactMap { item -> ImageMember? in
                    guard let source = item.source, source.imageChain == chain else { return nil }
                    return source.application
                }
                let selectedImages = Set(approvals.compactMap { item -> ImageMember? in
                    guard let source = item.source, source.imageChain.starts(with: chain), source.imageChain.count > chain.count else { return nil }
                    return source.imageChain[chain.count]
                })
                apps = try selectedApps.map { (try Self.resolve($0, in: volumes), $0) }
                nested = try selectedImages.sorted { $0.path < $1.path }.map { (try Self.resolve($0, in: volumes), $0) }
            } else {
                apps = try volumes.enumerated().flatMap { index, volume in
                    try Self.findApplications(in: volume).map { ($0, Self.member($0, in: volume, index: index)) }
                }
                nested = try volumes.enumerated().flatMap { index, volume in
                    try Self.findNestedImages(in: volume, rules: searchRules).map { ($0, Self.member($0, in: volume, index: index)) }
                }
            }
            guard !apps.isEmpty || !nested.isEmpty else {
                throw InstallFailure(message: "没有找到可拖拽安装的 .app。若内含 .pkg 或专用安装器，请手动运行安装程序。")
            }
            for (app, member) in apps {
                let approval = approvals?.first { $0.source?.imageChain == chain && $0.source?.application == member }
                progress(approval == nil ? "正在检查 \(app.lastPathComponent)…" : "正在复制并覆盖 \(app.lastPathComponent)…")
                do {
                    let source = DeferredApplication(imageURL: quarantineSource, imageIdentity: originalImageIdentity ?? report.imageIdentity!, imageChain: chain, application: member)
                    if let approval {
                        if let reason = replacementCheck(approval.target) { throw InstallFailure(message: reason) }
                        guard let prepared = try installApplication(app, imageURL: quarantineSource, source: source, approvedIdentity: approval.originalIdentity) else {
                            throw InstallFailure(message: "无法准备待覆盖应用。")
                        }
                        do {
                            guard try FileIdentity.read(quarantineSource) == source.imageIdentity else {
                                throw InstallFailure(message: "原 DMG 在复制期间发生变化，已保留现有应用。")
                            }
                            if let reason = replacementCheck(approval.target) { throw InstallFailure(message: reason) }
                            let result = try Self.replace(prepared)
                            report.completedReplacements.append(approval.id)
                            report.installed.append(app.lastPathComponent)
                            if let backup = result.oldAppInTrash { report.backupsInTrash.append(backup) }
                            if let warning = result.warning { report.problems.append(warning) }
                        } catch {
                            try? Self.discard(prepared)
                            throw error
                        }
                    } else if let conflict = try installApplication(app, imageURL: quarantineSource, source: source, progress: progress) {
                        report.pending.append(conflict)
                        progress("\(app.lastPathComponent) 重名，已待定（确认后才复制）")
                    } else {
                        report.installed.append(app.lastPathComponent)
                    }
                } catch {
                    if let approval { report.replacementProblems[approval.id] = error.localizedDescription }
                    else { report.problems.append("\(app.lastPathComponent)：\(error.localizedDescription)") }
                }
            }
            for (inner, member) in nested {
                let child = processImage(inner, quarantineSource: quarantineSource, chain: chain + [member], approvals: approvals, depth: depth + 1,
                                         remainingImages: &remainingImages, progress: progress, replacementCheck: replacementCheck,
                                         originalImageIdentity: originalImageIdentity ?? report.imageIdentity)
                report.nestedImages.append(inner.lastPathComponent)
                report.nestedImages += child.nestedImages
                report.installed += child.installed
                report.pending += child.pending
                report.completedReplacements += child.completedReplacements
                report.backupsInTrash += child.backupsInTrash
                report.replacementProblems.merge(child.replacementProblems) { _, new in new }
                report.problems += child.problems.map { "\(inner.lastPathComponent)：\($0)" }
                childrenEjected = childrenEjected && child.ejected
            }
        } catch { report.problems.append(error.localizedDescription) }

        // Query by our unique mount directory, including when attach failed or timed out.
        // Never detach a disk that was mounted before this job, and never force eject.
        if createdMountRoot {
            progress("正在弹出磁盘…")
            do {
                let mounts = try ownedImages(in: mountRoot)
                for mount in mounts {
                    var result = try SystemCommand.run("/usr/bin/hdiutil", ["detach", mount.device], timeout: 30)
                    if result.status != 0 {
                        Thread.sleep(forTimeInterval: 1)
                        result = try SystemCommand.run("/usr/bin/hdiutil", ["detach", mount.device], timeout: 30)
                    }
                    if result.status != 0 {
                        report.problems.append("自动弹出失败，请在 Finder 手动弹出：\(mount.volumes.map(\.path).joined(separator: "、"))")
                    }
                }
                let remaining = try ownedImages(in: mountRoot)
                report.ejected = (attached || !mounts.isEmpty) && remaining.isEmpty && childrenEjected
            } catch {
                report.problems.append("无法确认磁盘已弹出，请在 Finder 检查。\(error.localizedDescription)")
            }
            // rmdir removes only an empty directory: never recursively delete a mount.
            mountRoot.withUnsafeFileSystemRepresentation { path in if let path { _ = rmdir(path) } }
        }
        // Inner DMGs belong to a read-only parent volume. Only the top-level input
        // is eligible for Trash, after every child and parent has been detached.
        return report
    }

    private static func member(_ url: URL, in volume: URL, index: Int) -> ImageMember {
        let relative = url.standardizedFileURL.pathComponents.dropFirst(volume.standardizedFileURL.pathComponents.count).joined(separator: "/")
        return ImageMember(volumeIndex: index, path: relative)
    }

    private static func resolve(_ member: ImageMember, in volumes: [URL]) throws -> URL {
        guard volumes.indices.contains(member.volumeIndex), !member.path.hasPrefix("/"),
              !member.path.split(separator: "/").contains("..") else {
            throw InstallFailure(message: "映像内容发生变化，请重新添加 DMG。")
        }
        let volume = volumes[member.volumeIndex]
        let url = volume.appendingPathComponent(member.path)
        guard isInside(url, root: volume), FileManager.default.fileExists(atPath: url.path) else {
            throw InstallFailure(message: "待覆盖应用已不在原位置，请重新添加 DMG。")
        }
        return url
    }

    /// Remount one original DMG once for all approved conflicts from that job.
    /// Use the captured paths, not today's search rules or newly discovered apps.
    static func replaceDeferred(_ approvals: [PendingReplacement], progress: @Sendable (String) -> Void = { _ in },
                                replacementCheck: @Sendable (URL) -> String? = { _ in nil }) -> InstallReport {
        var result = InstallReport()
        guard !approvals.isEmpty else { return result }
        do {
            for approval in approvals where approval.stagedApp != nil {
                do {
                    if let reason = replacementCheck(approval.target) { throw InstallFailure(message: reason) }
                    let replacement = try replace(approval)
                    result.completedReplacements.append(approval.id)
                    result.installed.append(approval.name)
                    if let backup = replacement.oldAppInTrash { result.backupsInTrash.append(backup) }
                    if let warning = replacement.warning { result.problems.append(warning) }
                } catch { result.replacementProblems[approval.id] = error.localizedDescription }
            }
            let deferred = approvals.filter { $0.stagedApp == nil }
            guard let first = deferred.first, let source = first.source else { result.ejected = true; return result }
            guard deferred.allSatisfy({ $0.source?.imageURL == source.imageURL && $0.source?.imageIdentity == source.imageIdentity && $0.target.deletingLastPathComponent() == first.target.deletingLastPathComponent() }),
                  try FileIdentity.read(source.imageURL) == source.imageIdentity else {
                throw InstallFailure(message: "原 DMG 自待定后发生变化，请重新添加文件。")
            }
            let installer = DiskInstaller(destination: first.target.deletingLastPathComponent())
            var remaining = maximumImageCount
            let prepared = installer.processImage(source.imageURL, quarantineSource: source.imageURL, chain: [], approvals: deferred,
                                                 depth: 0, remainingImages: &remaining, progress: progress,
                                                 replacementCheck: replacementCheck, originalImageIdentity: source.imageIdentity)
            result.installed += prepared.installed
            result.completedReplacements += prepared.completedReplacements
            result.backupsInTrash += prepared.backupsInTrash
            result.problems += prepared.problems
            result.replacementProblems.merge(prepared.replacementProblems) { _, new in new }
            result.ejected = prepared.ejected
        } catch { result.problems.append(error.localizedDescription) }
        return result
    }

    /// Only dispose of the same input file after every app was successfully installed.
    /// Deferred replacements call this again after the last approved replacement.
    static func finishImage(_ imageURL: URL, report: InstallReport) -> InstallReport {
        guard report.readyToTrashImage else { return report }
        var result = report
        do {
            guard let original = report.imageIdentity, try FileIdentity.read(imageURL) == original else {
                throw InstallFailure(message: "原文件已发生变化，已保留。")
            }
            let canonical = imageURL.resolvingSymlinksInPath().standardizedFileURL
            let mounted = try DiskInstaller().imageList().contains { image in
                guard let path = image["image-path"] as? String else { return false }
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL == canonical
            }
            guard !mounted else { throw InstallFailure(message: "DMG 当前仍被挂载，已保留。") }
            var trashURL: NSURL?
            try FileManager.default.trashItem(at: imageURL, resultingItemURL: &trashURL)
            result.imageInTrash = trashURL as URL?
            result.imageTrashError = nil
        } catch {
            result.imageTrashError = "安装已完成，但 DMG 未能移入废纸篓，请手动处理：\(error.localizedDescription)"
        }
        return result
    }

    /// Find root apps or apps in up to two wrapper folders; never follow symlinks,
    /// descend into app bundles, or treat embedded helper apps as separate products.
    static func findApplications(in volume: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var apps: [URL] = []
        func scan(_ directory: URL, depth: Int) throws {
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
                let values = try child.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true, values.isDirectory == true, isInside(child, root: volume) else { continue }
                if child.pathExtension.lowercased() == "app" { apps.append(child) }
                else if depth < 2 && child.pathExtension.isEmpty { try scan(child, depth: depth + 1) }
            }
        }
        try scan(volume, depth: 0)
        return apps.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Rules match folder basenames and DMG filenames case-insensitively. Search
    /// only bounded ordinary folders, never symlinks, app bundles or package contents.
    static func findNestedImages(in volume: URL, rules: [ImageSearchRule]) throws -> [URL] {
        let active = rules.filter { $0.enabled && $0.isValid }
        guard !active.isEmpty else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var found: Set<URL> = []
        func scan(_ directory: URL, depth: Int, patterns: [String], insideDepth: Int) throws {
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
                let values = try child.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true, isInside(child, root: volume) else { continue }
                if values.isRegularFile == true, child.pathExtension.lowercased() == "dmg",
                   patterns.contains(where: { ImageSearchRule.matches(child.lastPathComponent, pattern: $0) }) {
                    found.insert(child.standardizedFileURL)
                } else if values.isDirectory == true,
                          !["app", "pkg", "mpkg", "bundle", "framework", "plugin", "appex"].contains(child.pathExtension.lowercased()) {
                    let matching = depth <= 2 ? active.filter { ImageSearchRule.matches(child.lastPathComponent, pattern: $0.folderPattern) }.map(\.imagePattern) : []
                    if !matching.isEmpty {
                        try scan(child, depth: depth + 1, patterns: Array(Set(patterns + matching)), insideDepth: 0)
                    } else if child.pathExtension.isEmpty && ((!patterns.isEmpty && insideDepth < 2) || depth < 2) {
                        try scan(child, depth: depth + 1, patterns: patterns, insideDepth: insideDepth + 1)
                    }
                }
            }
        }
        try scan(volume, depth: 0, patterns: [], insideDepth: 0)
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Stage on the destination filesystem, preserve attributes, then publish with
    /// an exclusive atomic rename, or retain the staged copy for batch confirmation.
    func installApplication(_ source: URL, imageURL: URL, source deferred: DeferredApplication? = nil,
                            approvedIdentity: FileIdentity? = nil, progress: @Sendable (String) -> Void = { _ in }) throws -> PendingReplacement? {
        let target = destination.appendingPathComponent(source.lastPathComponent)
        if let approvedIdentity {
            guard try FileIdentity.read(target) == approvedIdentity else {
                throw InstallFailure(message: "目标应用自待定后发生变化，请重新添加 DMG。")
            }
        } else if let deferred, let existing = try? FileIdentity.read(target) {
            return PendingReplacement(stagedApp: nil, target: target, originalIdentity: existing, stagedIdentity: nil, source: deferred)
        }
        let infoURL = source.appendingPathComponent("Contents/Info.plist")
        guard Self.isInside(infoURL, root: source),
              let data = try? Data(contentsOf: infoURL),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundlePackageType"] as? String == "APPL",
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/") else {
            throw InstallFailure(message: "应用包不完整，无法安装。")
        }
        let binary = source.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        guard Self.isInside(binary, root: source), fm.isExecutableFile(atPath: binary.path),
              (try binary.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw InstallFailure(message: "应用缺少有效的可执行文件。")
        }
        let stage = destination.appendingPathComponent(".DropInstall-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var retainStage = false
        defer { if !retainStage { try? fm.removeItem(at: stage) } }
        let stagedApp = stage.appendingPathComponent(source.lastPathComponent)
        progress("正在复制 \(source.lastPathComponent)…")
        _ = try SystemCommand.checked("/usr/bin/ditto", ["--rsrc", "--extattr", "--acl", "--qtn", source.path, stagedApp.path], timeout: 1800)
        // A download's quarantine may be on the DMG rather than its contents.
        let quarantine = try SystemCommand.run("/usr/bin/xattr", ["-px", "com.apple.quarantine", imageURL.path], timeout: 30)
        if quarantine.status == 0 {
            let value = String(decoding: quarantine.output, as: UTF8.self).filter { !$0.isWhitespace }
            if !value.isEmpty {
                _ = try SystemCommand.checked("/usr/bin/xattr", ["-wx", "com.apple.quarantine", value, stagedApp.path], timeout: 30)
            }
        }
        if let approvedIdentity {
            guard try FileIdentity.read(target) == approvedIdentity else {
                throw InstallFailure(message: "复制期间目标应用发生变化，已保留现有版本。")
            }
            let preparedIdentity = try FileIdentity.read(stagedApp)
            retainStage = true
            return PendingReplacement(stagedApp: stagedApp, target: target, originalIdentity: approvedIdentity, stagedIdentity: preparedIdentity)
        }
        let status = stagedApp.withUnsafeFileSystemRepresentation { from in
            target.withUnsafeFileSystemRepresentation { to in
                renamex_np(from!, to!, UInt32(RENAME_EXCL))
            }
        }
        if status != 0 {
            let code = errno
            if code == EEXIST {
                let conflict = PendingReplacement(stagedApp: stagedApp, target: target,
                    originalIdentity: try FileIdentity.read(target), stagedIdentity: try FileIdentity.read(stagedApp))
                retainStage = true
                return conflict
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return nil
    }

    /// Swap whole bundles atomically: copy failures cannot damage the existing app.
    /// After a successful swap the stage contains the OLD app, which must never be
    /// deleted by the normal staging cleanup if moving it to Trash fails.
    static func replace(_ conflict: PendingReplacement) throws -> ReplacementResult {
        guard let stagedApp = conflict.stagedApp, let stagedIdentity = conflict.stagedIdentity else {
            throw InstallFailure(message: "此项目尚未复制，请先确认批量覆盖。")
        }
        guard try FileIdentity.read(conflict.target) == conflict.originalIdentity,
              try FileIdentity.read(stagedApp) == stagedIdentity else {
            throw InstallFailure(message: "文件自待定后发生了变化。请保留现有版本，再重新添加 DMG。")
        }
        let values = try conflict.target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw InstallFailure(message: "同名目标不是普通应用文件夹，请在 Finder 中手动处理。")
        }
        let status = stagedApp.withUnsafeFileSystemRepresentation { from in
            conflict.target.withUnsafeFileSystemRepresentation { to in
                renamex_np(from!, to!, UInt32(RENAME_SWAP))
            }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: stagedApp, resultingItemURL: &trashedURL)
            try? FileManager.default.removeItem(at: stagedApp.deletingLastPathComponent())
            return ReplacementResult(oldAppInTrash: trashedURL as URL?)
        } catch {
            return ReplacementResult(warning: "新版已安装；旧版未能移入废纸篓，保留在：\(stagedApp.path)")
        }
    }

    static func discard(_ conflict: PendingReplacement) throws {
        guard let stagedApp = conflict.stagedApp else { return }
        // Never accidentally delete an old backup after an already-completed swap.
        guard try FileIdentity.read(stagedApp) == conflict.stagedIdentity else {
            throw InstallFailure(message: "暂存文件已变化，已保留供手动检查：\(stagedApp.path)")
        }
        try FileManager.default.removeItem(at: stagedApp.deletingLastPathComponent())
    }
}
