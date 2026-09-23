import AppKit

enum ImageInputTests {
    @MainActor static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DropInstall-iso-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            print("PASS: \(message)")
        }
        let iso = root.appendingPathComponent("中文 空格 '$` [demo].ISO")
        let bytes = Data("unchanged image bytes\u{0}\u{1}".utf8)
        try bytes.write(to: iso)
        let identity = try FileIdentity.read(iso)
        _ = try SystemCommand.checked("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;00000000;DropInstallISOTests;", iso.path])
        let renamed = try ImageInput.prepare(iso)
        let renamedBytes = try Data(contentsOf: renamed)
        let renamedIdentity = try FileIdentity.read(renamed)
        check(renamed.lastPathComponent == "中文 空格 '$` [demo].dmg" && !fm.fileExists(atPath: iso.path), "ISO automatically renames in place, including uppercase and Unicode")
        check(renamedBytes == bytes && renamedIdentity == identity, "ISO rename preserves bytes and inode without conversion or copying")
        let quarantine = try SystemCommand.checked("/usr/bin/xattr", ["-p", "com.apple.quarantine", renamed.path])
        check(String(decoding: quarantine, as: UTF8.self).contains("DropInstallISOTests"), "ISO rename preserves download quarantine")

        let collisionISO = root.appendingPathComponent("Collision.iso")
        let occupied = root.appendingPathComponent("Collision.dmg")
        try bytes.write(to: collisionISO)
        try Data("keep existing file".utf8).write(to: occupied)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Collision (2).dmg"), withDestinationURL: occupied)
        let collisionResult = try ImageInput.prepare(collisionISO)
        let occupiedBytes = try Data(contentsOf: occupied)
        check(collisionResult.lastPathComponent == "Collision (3).dmg" && occupiedBytes == Data("keep existing file".utf8), "ISO rename never overwrites existing files or symlinks")
        let sameDMG = try ImageInput.prepare(renamed)
        check(sameDMG == renamed, "DMG input is not renamed again")

        let fakeDirectory = root.appendingPathComponent("Folder.iso")
        try fm.createDirectory(at: fakeDirectory, withIntermediateDirectories: false)
        var rejectedDirectory = false
        do { _ = try ImageInput.prepare(fakeDirectory) } catch { rejectedDirectory = true }
        let alias = root.appendingPathComponent("Alias.iso")
        try fm.createSymbolicLink(at: alias, withDestinationURL: renamed)
        var rejectedAlias = false
        do { _ = try ImageInput.prepare(alias) } catch { rejectedAlias = true }
        check(rejectedDirectory && rejectedAlias && fm.fileExists(atPath: renamed.path), "ISO directories and symlinks are not renamed")

        let repeated = root.appendingPathComponent("Repeat.iso")
        try bytes.write(to: repeated)
        let model = AppModel()
        model.add([repeated, repeated, repeated.deletingPathExtension().appendingPathExtension("dmg")])
        check(model.jobs.count == 1 && model.jobs[0].url.pathExtension == "dmg" && model.jobs[0].originalURL == repeated, "duplicate ISO input normalizes once and shares the DMG queue entry")
        model.add([repeated])
        check(model.jobs.count == 1, "repeated original ISO URL does not create a failed duplicate")
        let missing = root.appendingPathComponent("Missing.iso")
        model.add([missing])
        check(model.jobs.last?.state == .attention && model.pendingCount == 1, "rename failure stays visible without attempting installation")
        try bytes.write(to: missing)
        model.retry(model.jobs.last!.id)
        check(model.jobs.last?.state == .waiting && model.jobs.last?.url.pathExtension == "dmg", "rename failure can be retried after source becomes available")

        let serviceISO = root.appendingPathComponent("Service.iso")
        try bytes.write(to: serviceISO)
        let serviceModel = AppModel()
        let provider = ServicesProvider { serviceModel.add($0) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([serviceISO, renamed] as [NSURL])
        var serviceError: NSString?
        provider.installDMG(pasteboard, userData: nil, error: &serviceError)
        check(serviceError == nil && serviceModel.jobs.count == 2 && serviceModel.jobs.allSatisfy { $0.url.pathExtension == "dmg" }, "service accepts mixed ISO and DMG and renames ISO automatically")

        let app = root.appendingPathComponent("payload/ISO Demo.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Demo")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info = ["CFBundleIdentifier": "test.dropinstall.iso", "CFBundlePackageType": "APPL", "CFBundleExecutable": "Demo"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let disk = root.appendingPathComponent("Installable.dmg")
        _ = try SystemCommand.checked("/usr/bin/hdiutil", ["create", "-srcfolder", root.appendingPathComponent("payload").path, "-volname", "ISO Demo", "-fs", "HFS+", "-format", "UDZO", disk.path])
        let installable = root.appendingPathComponent("Installable.iso")
        try fm.moveItem(at: disk, to: installable)

        let mount = root.appendingPathComponent("mounted")
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        _ = try SystemCommand.checked("/usr/bin/hdiutil", ["attach", installable.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path])
        var rejectedMounted = false
        do { _ = try ImageInput.prepare(installable) } catch { rejectedMounted = true }
        check(rejectedMounted && fm.fileExists(atPath: installable.path) && fm.fileExists(atPath: mount.appendingPathComponent("ISO Demo.app").path), "already-mounted ISO keeps its filename and mount")
        _ = try SystemCommand.checked("/usr/bin/hdiutil", ["detach", mount.path])

        let destination = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let queue = AppModel(destination: destination)
        queue.add([installable], startImmediately: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        while queue.busy && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let report = queue.jobs[0].report!
        defer { if let trash = report.imageInTrash { try? fm.removeItem(at: trash) } }
        check(!queue.busy && queue.jobs[0].state == .installed && report.installed == ["ISO Demo.app"], "ISO rename feeds directly into normal application installation")
        check(report.ejected && report.imageInTrash != nil && !fm.fileExists(atPath: installable.path) && !fm.fileExists(atPath: disk.path), "successful ISO input follows renamed DMG eject and Trash lifecycle")
        check(queue.jobs[0].originalURL == installable && queue.jobs[0].url == disk, "queue keeps the original ISO name and current DMG path")
    }
}
