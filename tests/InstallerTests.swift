import AppKit

@main
struct InstallerTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DropInstall-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let installer = DiskInstaller(destination: destination)

        func makeApp(_ name: String, in folder: URL) throws -> URL {
            let app = folder.appendingPathComponent(name + ".app")
            let executable = app.appendingPathComponent("Contents/MacOS/TestApp")
            try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Never launched: a valid fixture bundle for copy verification only.
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let plist: [String: String] = ["CFBundleIdentifier": "test.dropinstall.fixture", "CFBundlePackageType": "APPL", "CFBundleExecutable": "TestApp", "CFBundleName": name]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
        func makeImage(_ name: String, source: URL) throws -> URL {
            let image = root.appendingPathComponent(name + ".dmg")
            _ = try SystemCommand.checked("/usr/bin/hdiutil", ["create", "-srcfolder", source.path, "-volname", name, "-fs", "HFS+", "-format", "UDZO", image.path])
            return image
        }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            print("PASS: \(message)")
        }
        let quickCommand = try SystemCommand.run("/usr/bin/true", [])
        check(quickCommand.status == 0, "event-driven process completion handles immediate exit")
        var commandTimedOut = false
        let timeoutStart = ProcessInfo.processInfo.systemUptime
        do { _ = try SystemCommand.run("/bin/sleep", ["5"], timeout: 0.05) }
        catch { commandTimedOut = true }
        check(commandTimedOut && ProcessInfo.processInfo.systemUptime - timeoutStart < 3, "event-driven wait still terminates timed-out commands")

        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        let first = try makeApp("中文 空格 '$` app", in: source)
        let wrapped = source.appendingPathComponent("Wrapper")
        let second = try makeApp("Second", in: wrapped)
        _ = try makeApp("Helper", in: first.appendingPathComponent("Contents/Helpers"))
        try fm.createSymbolicLink(at: source.appendingPathComponent("Applications"), withDestinationURL: URL(fileURLWithPath: "/Applications"))
        try fm.createSymbolicLink(at: source.appendingPathComponent("External.app"), withDestinationURL: first)
        let apps = try DiskInstaller.findApplications(in: source)
        check(Set(apps.map(\.lastPathComponent)) == Set([first.lastPathComponent, second.lastPathComponent]), "find wrapper apps; ignore symlinks and nested helpers")
        check(!DiskInstaller.isInside(URL(fileURLWithPath: root.path + "-other/app"), root: root), "path prefix boundary")

        let image = try makeImage("测试 安装 '$`", source: source)
        let quarantine = "0081;00000000;DropInstallTests;"
        _ = try SystemCommand.checked("/usr/bin/xattr", ["-w", "com.apple.quarantine", quarantine, image.path])
        let report = installer.install(image)
        print(report.detail)
        check(report.problems.isEmpty && report.installed.count == 2 && report.ejected, "real DMG: mount, copy two apps, eject")
        check(!fm.fileExists(atPath: image.path) && report.imageInTrash != nil && fm.fileExists(atPath: report.imageInTrash!.path), "successful DMG moved to recoverable Trash")
        try fm.moveItem(at: report.imageInTrash!, to: image) // Restore our fixture for subsequent scenarios.
        let installed = destination.appendingPathComponent(first.lastPathComponent)
        let installedData = try Data(contentsOf: installed.appendingPathComponent("Contents/MacOS/TestApp"))
        check(installedData == Data("#!/bin/sh\nexit 0\n".utf8), "copied executable bytes match")
        let copiedQuarantine = try SystemCommand.checked("/usr/bin/xattr", ["-p", "com.apple.quarantine", installed.path])
        check(String(decoding: copiedQuarantine, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == quarantine, "DMG quarantine propagated")
        let sentinel = installed.appendingPathComponent("keep-me")
        try Data("original".utf8).write(to: sentinel)
        let again = installer.install(image)
        check(again.installed.isEmpty && again.pending.count == 2 && again.skipped.isEmpty && again.ejected && again.problems.isEmpty, "existing apps deferred, disk still ejected")
        check(again.imageInTrash == nil && fm.fileExists(atPath: image.path), "pending replacement keeps the DMG")
        check(fm.fileExists(atPath: sentinel.path), "existing installation untouched before confirmation")
        let replaceItem = again.pending.first { $0.name == first.lastPathComponent }!
        let keepItem = again.pending.first { $0.name == second.lastPathComponent }!
        let unapprovedIdentity = try FileIdentity.read(keepItem.target)
        let preflightChildren = try fm.contentsOfDirectory(atPath: destination.path)
        check(replaceItem.stagedApp == nil && replaceItem.source != nil && !preflightChildren.contains { $0.hasPrefix(".DropInstall-") }, "conflict detected without copying or staging app")
        let replacement = DiskInstaller.replaceDeferred([replaceItem])
        check(replacement.problems.isEmpty && replacement.completedReplacements == [replaceItem.id] && !fm.fileExists(atPath: sentinel.path), "confirmed replacement swaps entire bundle")
        check(replacement.backupsInTrash.count == 1 && fm.fileExists(atPath: replacement.backupsInTrash[0].appendingPathComponent("keep-me").path), "old application recoverable in Trash")
        // Remove only the test fixture this test just moved to Trash.
        for trash in replacement.backupsInTrash { try fm.removeItem(at: trash) }
        let keptIdentity = try FileIdentity.read(keepItem.target)
        check(keptIdentity == unapprovedIdentity, "confirming one app does not copy or replace an unapproved sibling")
        try DiskInstaller.discard(keepItem)
        let keptIdentityAfter = try FileIdentity.read(keepItem.target)
        check(keptIdentity == keptIdentityAfter && keepItem.stagedApp == nil, "decline avoids copying and preserves existing app")

        let changed = installer.install(image)
        let changedItem = changed.pending.first!
        let movedTarget = root.appendingPathComponent("changed-target-backup.app")
        try fm.moveItem(at: changedItem.target, to: movedTarget)
        _ = try makeApp(changedItem.target.deletingPathExtension().lastPathComponent, in: destination)
        let rejected = DiskInstaller.replaceDeferred([changedItem])
        check(rejected.completedReplacements.isEmpty && rejected.replacementProblems[changedItem.id] != nil && fm.fileExists(atPath: movedTarget.path), "replacement rejects a target changed since confirmation list")
        for item in changed.pending { try DiskInstaller.discard(item) }

        let deferredPlan = installer.install(image)
        let originalImageBackup = root.appendingPathComponent("saved-original.dmg")
        try fm.moveItem(at: image, to: originalImageBackup)
        try fm.copyItem(at: originalImageBackup, to: image)
        let staleSource = DiskInstaller.replaceDeferred(deferredPlan.pending)
        check(staleSource.completedReplacements.isEmpty && !staleSource.problems.isEmpty, "deferred replacement rejects changed source DMG")
        try fm.removeItem(at: image)
        try fm.moveItem(at: originalImageBackup, to: image)
        let blocked = DiskInstaller.replaceDeferred(deferredPlan.pending, replacementCheck: { _ in "Application is running" })
        check(blocked.completedReplacements.isEmpty && blocked.replacementProblems.count == 2 && blocked.ejected, "running-app check blocks replacement and still ejects")
        let blockedStages = try fm.contentsOfDirectory(atPath: destination.path)
        check(!blockedStages.contains { $0.hasPrefix(".DropInstall-") }, "blocked and deferred conflicts perform no staging copies")

        let pkgSource = root.appendingPathComponent("package-source")
        try fm.createDirectory(at: pkgSource, withIntermediateDirectories: false)
        try Data("fixture".utf8).write(to: pkgSource.appendingPathComponent("Setup.pkg"))
        let packageImage = try makeImage("Package Only", source: pkgSource)
        let packageReport = installer.install(packageImage)
        check(packageReport.installed.isEmpty && !packageReport.problems.isEmpty && packageReport.ejected, "package-only image reported and ejected")
        check(packageReport.imageInTrash == nil && fm.fileExists(atPath: packageImage.path), "unsupported DMG retained")

        let broken = root.appendingPathComponent("broken.dmg")
        try Data("invalid image".utf8).write(to: broken)
        let brokenReport = installer.install(broken)
        check(!brokenReport.problems.isEmpty && brokenReport.installed.isEmpty, "corrupt DMG produces failure")
        check(fm.fileExists(atPath: broken.path), "failed DMG retained")
        let badDestination = DiskInstaller(destination: broken).install(image)
        check(!badDestination.problems.isEmpty && !badDestination.ejected, "invalid destination rejected before mount")

        let userMount = root.appendingPathComponent("already-open")
        try fm.createDirectory(at: userMount, withIntermediateDirectories: false)
        _ = try SystemCommand.checked("/usr/bin/hdiutil", ["attach", image.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", userMount.path])
        defer { _ = try? SystemCommand.run("/usr/bin/hdiutil", ["detach", userMount.path]) }
        let mountedReport = installer.install(image)
        check(mountedReport.problems.contains { $0.contains("已经打开") }, "previously mounted DMG refused")
        check(fm.fileExists(atPath: userMount.appendingPathComponent(first.lastPathComponent).path), "user-mounted disk left attached")
        _ = try SystemCommand.checked("/usr/bin/hdiutil", ["detach", userMount.path])

        let invalidSource = root.appendingPathComponent("invalid-source")
        let invalidApp = try makeApp("Invalid", in: invalidSource)
        try fm.removeItem(at: invalidApp.appendingPathComponent("Contents/MacOS/TestApp"))
        let invalidImage = try makeImage("Invalid App", source: invalidSource)
        let invalidReport = installer.install(invalidImage)
        check(invalidReport.installed.isEmpty && !invalidReport.problems.isEmpty && invalidReport.ejected, "malformed app rejected and disk ejected")
        check(fm.fileExists(atPath: invalidImage.path), "failed app installation retains its DMG")
        let children = try fm.contentsOfDirectory(atPath: destination.path)
        check(!children.contains { $0.hasPrefix(".DropInstall-") }, "no staging directories remain")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var received: [URL] = []
        let service = ServicesProvider { received = $0 }
        check(service.responds(to: NSSelectorFromString("installDMG:userData:error:")), "Objective-C service selector")
        pasteboard.writeObjects([image, packageImage] as [NSURL])
        var error: NSString?
        service.installDMG(pasteboard, userData: nil, error: &error)
        check(error == nil && received == [image, packageImage], "service accepts multiple DMGs")
        pasteboard.clearContents()
        pasteboard.writeObjects([source] as [NSURL])
        service.installDMG(pasteboard, userData: nil, error: &error)
        check(error != nil && received == [image, packageImage], "service rejects non-DMG input")
        let model = AppModel()
        model.add([image, image, source])
        check(model.jobs.count == 1 && model.pendingCount == 1 && model.inputMessage != nil, "queue deduplicates and reports invalid inputs")

        // Run the real asynchronous queue against a temporary destination. A failure
        // later in the queue must finish before the single batch question appears.
        let queue = AppModel(destination: destination)
        var requests = 0
        queue.onRequestDecision = { requests += 1 }
        queue.add([image, broken], startImmediately: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        while queue.busy && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(50))
            if queue.busy { checkNoEarlyPrompt(queue) }
        }
        check(!queue.busy && queue.pendingCount == 0 && queue.conflicts.count == 2, "queue finishes non-conflicting and failing items before decision")
        check(queue.showConflictSheet && requests == 1 && queue.jobs[0].state == .pending, "one batch question after queue drains")
        let pendingIDs = queue.conflicts.map(\.id)
        queue.showConflictSheet = false
        check(queue.conflicts.map(\.id) == pendingIDs && queue.conflicts.allSatisfy { $0.conflict.stagedApp == nil }, "later retains deferred plans without copying apps")
        queue.requestDecision()
        check(queue.showConflictSheet && requests == 2, "pending decision can be reopened")
        queue.keepExisting()
        check(queue.conflicts.isEmpty && !queue.showConflictSheet, "batch keep existing resolves all pending plans")
        check(fm.fileExists(atPath: image.path), "declining replacements retains DMG")

        let batch = AppModel(destination: destination)
        batch.add([image], startImmediately: true)
        while batch.busy && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        check(batch.showConflictSheet && batch.conflicts.count == 2, "batch overwrite is offered for all conflicts")
        let oldIdentities = try batch.conflicts.map { try FileIdentity.read($0.conflict.target) }
        let replacementTargets = batch.conflicts.map { $0.conflict.target }
        batch.replaceAll()
        while batch.busy && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let newIdentities = try replacementTargets.map { try FileIdentity.read($0) }
        check(!batch.busy && batch.conflicts.isEmpty && batch.jobs[0].state == .installed && batch.jobs[0].report?.installed.count == 2, "one confirmation replaces the entire pending batch")
        check(zip(oldIdentities, newIdentities).allSatisfy { $0 != $1 }, "batch replacement publishes staged bundles")
        let backups = batch.jobs.flatMap { $0.report?.backupsInTrash ?? [] }
        check(backups.count == 2 && backups.allSatisfy { fm.fileExists(atPath: $0.path) }, "batch old versions are recoverable in Trash")
        for backup in backups { try fm.removeItem(at: backup) }
        let trashedImage = batch.jobs[0].report?.imageInTrash
        check(trashedImage != nil && !fm.fileExists(atPath: image.path) && fm.fileExists(atPath: trashedImage!.path), "DMG trashed only after all replacements succeed")
        try fm.moveItem(at: trashedImage!, to: image)
        let remainingStages = try fm.contentsOfDirectory(atPath: destination.path)
        check(!remainingStages.contains { $0.hasPrefix(".DropInstall-") }, "batch confirmation leaves no pending staging directories")

        var incomplete = InstallReport()
        incomplete.installed = ["First.app"]
        incomplete.imageIdentity = try FileIdentity.read(image)
        let notEjected = DiskInstaller.finishImage(image, report: incomplete)
        check(notEjected.imageInTrash == nil && fm.fileExists(atPath: image.path), "not-yet-ejected DMG cannot be trashed")
        incomplete.ejected = true
        incomplete.problems = ["Second app failed"]
        let partial = DiskInstaller.finishImage(image, report: incomplete)
        check(partial.imageInTrash == nil && fm.fileExists(atPath: image.path), "partially failed DMG retained")
        incomplete.problems = []
        incomplete.skipped = ["Second.app"]
        let declined = DiskInstaller.finishImage(image, report: incomplete)
        check(declined.imageInTrash == nil && fm.fileExists(atPath: image.path), "partially declined DMG retained")
        incomplete.skipped = []
        incomplete.imageIdentity = try FileIdentity.read(broken)
        let changedImage = DiskInstaller.finishImage(image, report: incomplete)
        check(changedImage.imageTrashError != nil && fm.fileExists(atPath: image.path), "changed source image protected from trash")

        let quitIdle = AppModel(destination: destination)
        var idleQuitReplies = 0
        quitIdle.onReadyToQuit = { idleQuitReplies += 1 }
        quitIdle.requestQuit()
        quitIdle.requestQuit()
        check(quitIdle.quitRequested && idleQuitReplies == 1, "idle quit completes once without confirmation")

        let quitBusy = AppModel(destination: destination)
        var quitReplies = 0
        var quitDecisionRequests = 0
        quitBusy.onReadyToQuit = { quitReplies += 1 }
        quitBusy.onRequestDecision = { quitDecisionRequests += 1 }
        quitBusy.add([image, broken], startImmediately: true)
        let quitDeadline = ProcessInfo.processInfo.systemUptime + 90
        while quitBusy.jobs.first?.state != .running && ProcessInfo.processInfo.systemUptime < quitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        quitBusy.requestQuit()
        quitBusy.add([packageImage], startImmediately: true)
        while quitBusy.busy && ProcessInfo.processInfo.systemUptime < quitDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        check(!quitBusy.busy && quitReplies == 1 && quitDecisionRequests == 0, "quit during install finishes automatically with no conflict prompt")
        check(quitBusy.jobs.count == 2 && quitBusy.jobs[1].state == .waiting, "quit stops remaining queue and refuses new work")
        check(quitBusy.conflicts.isEmpty && fm.fileExists(atPath: image.path), "quit clears staged replacements and retains unapproved DMG")
        let quitStages = try fm.contentsOfDirectory(atPath: destination.path)
        check(!quitStages.contains { $0.hasPrefix(".DropInstall-") }, "quit leaves no staged pending copies")
        let info = try SystemCommand.checked("/usr/bin/hdiutil", ["info", "-plist"])
        check(!String(decoding: info, as: UTF8.self).contains(root.path), "all fixture disks detached")
        try await NestedImageTests.run()
        try await ImageInputTests.run()
        print("All DropInstall integration tests passed. No apps were launched or installed into /Applications.")
    }

    @MainActor static func checkNoEarlyPrompt(_ model: AppModel) {
        precondition(!model.showConflictSheet, "Conflict question must not interrupt the queue")
    }
}
