import AppKit

enum NestedImageTests {
    @MainActor static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DropInstall-nested-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var trashToClean: [URL] = []
        defer { for url in trashToClean { try? fm.removeItem(at: url) } }
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            precondition(value(), name)
            print("PASS: \(name)")
        }
        func folder(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func image(_ name: String, source: URL) throws -> URL {
            let url = root.appendingPathComponent(name + ".dmg")
            _ = try SystemCommand.checked("/usr/bin/hdiutil", ["create", "-srcfolder", source.path, "-volname", name, "-fs", "HFS+", "-format", "UDZO", url.path])
            return url
        }
        func wait(_ model: AppModel) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            while model.busy && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(50)) }
            precondition(!model.busy, "Nested queue timed out")
        }

        check(ImageSearchRule.matches("Manual install", pattern: "Manual Install"), "folder rule ignores case")
        check(ImageSearchRule.matches("Manual install v2", pattern: "Manual* v?"), "folder wildcard star and question mark")
        check(ImageSearchRule.matches("中文 [test].DMG", pattern: "中文 [test].dmg"), "rule treats punctuation literally and DMG case-insensitively")
        check(!ImageSearchRule.matches("Almost Manual Install", pattern: "Manual Install"), "folder pattern matches the whole name")
        let suiteName = "DropInstall-rule-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        var rules = ImageSearchRule.defaults
        rules.append(ImageSearchRule(folderPattern: "Install*", imagePattern: "Payload?.dmg"))
        ImageSearchRuleStore.save(rules, to: preferences)
        check(ImageSearchRuleStore.load(from: preferences) == rules, "multiple rules persist in isolated preferences")
        ImageSearchRuleStore.save([], to: preferences)
        check(ImageSearchRuleStore.load(from: preferences).isEmpty, "empty rule list remains disabled after reload")

        let payload = try folder("payload/Nested Demo.app/Contents/MacOS")
        let binary = payload.appendingPathComponent("NestedDemo")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let info: [String: String] = ["CFBundleIdentifier": "test.dropinstall.nested", "CFBundlePackageType": "APPL", "CFBundleExecutable": "NestedDemo"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: payload.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let inner = try image("Inner 中文 [test]", source: root.appendingPathComponent("payload"))
        let manual = try folder("outer-source/Manual install")
        let innerCopy = manual.appendingPathComponent("Inner 中文 [test].DMG")
        try fm.copyItem(at: inner, to: innerCopy)
        let unrelated = try folder("outer-source/Unrelated")
        try Data("not a disk image".utf8).write(to: unrelated.appendingPathComponent("Ignore.dmg"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("outer-source/Manual install alias"), withDestinationURL: unrelated)
        let script = root.appendingPathComponent("outer-source/Open Gatekeeper friendly")
        let marker = root.appendingPathComponent("script-executed")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let duplicateRules = [ImageSearchRule(folderPattern: "Manual*", imagePattern: "*.dmg"), ImageSearchRule(folderPattern: "manual install", imagePattern: "Inner*.DMG")]
        let candidates = try DiskInstaller.findNestedImages(in: root.appendingPathComponent("outer-source"), rules: duplicateRules)
        check(candidates.count == 1 && candidates[0] == innerCopy, "overlapping rules deduplicate and ignore symlinks/unmatched folders")
        var disabled = duplicateRules
        for i in disabled.indices { disabled[i].enabled = false }
        let none = try DiskInstaller.findNestedImages(in: root.appendingPathComponent("outer-source"), rules: disabled)
        check(none.isEmpty, "disabled rules find no nested images")

        let outer = try image("Outer Manual Install", source: root.appendingPathComponent("outer-source"))
        let quarantine = "0081;00000000;DropInstallNestedTests;"
        _ = try SystemCommand.checked("/usr/bin/xattr", ["-w", "com.apple.quarantine", quarantine, outer.path])
        let destination = try folder("Applications")
        let report = DiskInstaller(destination: destination).install(outer)
        if !report.problems.isEmpty { print(report.detail) }
        check(report.installed == ["Nested Demo.app"] && report.problems.isEmpty && report.ejected, "nested DMG installs app and ejects both layers")
        check(report.nestedImages == [innerCopy.lastPathComponent] && report.imageInTrash != nil && report.imageTrashError == nil, "only the outer DMG is moved to Trash after nested success")
        try fm.moveItem(at: report.imageInTrash!, to: outer)
        let xattr = try SystemCommand.checked("/usr/bin/xattr", ["-p", "com.apple.quarantine", destination.appendingPathComponent("Nested Demo.app").path])
        check(String(decoding: xattr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == quarantine, "outer download quarantine preserved on nested app")
        check(!fm.fileExists(atPath: marker.path), "embedded helper scripts are never executed")

        let model = AppModel(destination: destination)
        model.searchRules = ImageSearchRule.defaults
        model.add([outer], startImmediately: true)
        try await wait(model)
        check(model.conflicts.count == 1 && model.showConflictSheet && fm.fileExists(atPath: outer.path), "nested conflict keeps outer DMG pending after both layers eject")
        model.replaceAll()
        try await wait(model)
        let replaced = model.jobs[0].report!
        check(model.conflicts.isEmpty && replaced.installed.count == 1 && replaced.imageInTrash != nil, "batch overwrite of nested app trashes the outer DMG")
        trashToClean += replaced.backupsInTrash
        try fm.moveItem(at: replaced.imageInTrash!, to: outer)

        let mixedSource = try folder("mixed-source/Manual Install")
        try fm.copyItem(at: inner, to: mixedSource.appendingPathComponent("A valid.dmg"))
        try Data("corrupt inner".utf8).write(to: mixedSource.appendingPathComponent("Z broken.dmg"))
        let mixed = try image("Mixed Nested", source: mixedSource.deletingLastPathComponent())
        let mixedDestination = try folder("Mixed Applications")
        let partial = DiskInstaller(destination: mixedDestination).install(mixed)
        check(partial.installed.count == 1 && !partial.problems.isEmpty && partial.imageInTrash == nil && fm.fileExists(atPath: mixed.path), "failed sibling nested DMG retains outer despite partial install")

        let disabledDestination = try folder("Disabled Applications")
        let ignored = DiskInstaller(destination: disabledDestination, searchRules: []).install(outer)
        check(ignored.installed.isEmpty && !ignored.problems.isEmpty && ignored.ejected && fm.fileExists(atPath: outer.path), "disabling nested rules preserves unsupported outer image")

        let thirdFolder = try folder("third-source/Manual Install")
        try fm.copyItem(at: outer, to: thirdFolder.appendingPathComponent("Middle.dmg"))
        let third = try image("Three Layers", source: thirdFolder.deletingLastPathComponent())
        let thirdDestination = try folder("Three Layer Applications")
        let thirdReport = DiskInstaller(destination: thirdDestination).install(third)
        check(thirdReport.installed.count == 1 && thirdReport.problems.isEmpty && thirdReport.ejected && thirdReport.imageInTrash != nil, "three image layers clean up from innermost outward")
        try fm.moveItem(at: thirdReport.imageInTrash!, to: third)
        let fourthFolder = try folder("fourth-source/Manual Install")
        try fm.copyItem(at: third, to: fourthFolder.appendingPathComponent("Too deep.dmg"))
        let fourth = try image("Four Layers", source: fourthFolder.deletingLastPathComponent())
        let fourthDestination = try folder("Four Layer Applications")
        let limited = DiskInstaller(destination: fourthDestination).install(fourth)
        check(limited.installed.isEmpty && limited.problems.contains { $0.contains("上限") } && fm.fileExists(atPath: fourth.path), "nesting limit refuses deep images and preserves source")
        let allMounts = try SystemCommand.checked("/usr/bin/hdiutil", ["info", "-plist"])
        check(!String(decoding: allMounts, as: UTF8.self).contains(root.path), "all nested test mounts detached on success and failure")
    }
}
