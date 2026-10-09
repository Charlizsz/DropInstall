import AppKit

@MainActor
enum RunningAppTests {
    final class FakeProcess {
        var running = true
        var requests = 0
        var accepts = true
        var exits = true
        var handles: [RunningAppUpdater.ProcessHandle] {
            guard running else { return [] }
            return [.init(terminated: { !self.running }, requestQuit: {
                self.requests += 1
                if self.accepts && self.exits { self.running = false }
                return self.accepts
            })]
        }
    }

    static func run() async throws {
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            precondition(value(), name)
            print("PASS: \(name)")
        }
        func isBlocked(_ result: RunningAppUpdater.Preparation) -> Bool {
            if case .blocked = result { return true }; return false
        }
        let url = URL(fileURLWithPath: "/unused/Example.app")
        var prompts = 0
        var opens = 0
        let fake = FakeProcess()
        let updater = RunningAppUpdater(timeout: 0.15, processes: { _ in fake.handles }, open: { target in
            precondition(target == url); opens += 1
        })
        fake.running = false
        let idle = await updater.prepare(url, confirm: { _ in prompts += 1; return true }, shouldStop: { false }, progress: { _ in })
        if case .ready(let reopen) = idle { check(!reopen && prompts == 0, "non-running app does not prompt or request relaunch") }
        else { preconditionFailure("Idle app blocked") }
        fake.running = true
        let declined = await updater.prepare(url, confirm: { _ in prompts += 1; return false }, shouldStop: { false }, progress: { _ in })
        check(isBlocked(declined) && fake.requests == 0 && fake.running, "declining running-app prompt never quits the app")
        let accepted = await updater.prepare(url, confirm: { _ in true }, shouldStop: { false }, progress: { _ in })
        if case .ready(let reopen) = accepted { check(reopen && !fake.running && fake.requests == 1, "consent requests normal quit and waits for termination") }
        else { preconditionFailure("Accepted quit failed") }
        _ = await updater.reopen(url, replacementSucceeded: false)
        check(opens == 0, "failed replacement never reopens application")
        let reopened = await updater.reopen(url, replacementSucceeded: true)
        check(opens == 1 && reopened == nil, "successful replacement reopens exact destination")
        fake.running = true; fake.accepts = false
        let refused = await updater.prepare(url, confirm: { _ in true }, shouldStop: { false }, progress: { _ in })
        check(isBlocked(refused) && fake.running, "quit refusal blocks update without force quitting")
        fake.accepts = true; fake.exits = false
        let timedOut = await updater.prepare(url, confirm: { _ in true }, shouldStop: { false }, progress: { _ in })
        check(isBlocked(timedOut) && fake.running, "unsaved-content wait times out with app still running")
        let beforeCancel = fake.requests
        var stopped = false
        let cancelled = await updater.prepare(url, confirm: { _ in stopped = true; return true }, shouldStop: { stopped }, progress: { _ in })
        check(isBlocked(cancelled) && fake.requests == beforeCancel, "stop during confirmation prevents quit request")
        let failure = RunningAppUpdater(processes: { _ in [] }, open: { _ in throw InstallFailure(message: "test launch failure") })
        let warning = await failure.reopen(url, replacementSucceeded: true)
        check(warning?.contains("重新打开失败") == true, "relaunch failure produces a visible warning")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DropInstall-running-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var trash: [URL] = []
        defer { for url in trash { try? fm.removeItem(at: url) } }
        func fixture(_ name: String) throws -> (URL, URL, PendingReplacement) {
            let destination = root.appendingPathComponent(name)
            let target = destination.appendingPathComponent("\(name).app")
            let staged = destination.appendingPathComponent(".DropInstall-test/\(name).app")
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: target.appendingPathComponent("version"))
            try Data("new".utf8).write(to: staged.appendingPathComponent("version"))
            let image = root.appendingPathComponent(name + ".dmg")
            try Data("test input".utf8).write(to: image)
            let pending = PendingReplacement(stagedApp: staged, target: target, originalIdentity: try FileIdentity.read(target), stagedIdentity: try FileIdentity.read(staged))
            return (destination, image, pending)
        }
        func model(_ destination: URL, _ image: URL, _ conflict: PendingReplacement, _ updater: RunningAppUpdater) throws -> AppModel {
            let m = AppModel(destination: destination, runningApps: updater)
            m.jobs = [InstallJob(url: image, state: .pending, status: "待确认覆盖", report: InstallReport(pending: [conflict], ejected: true, imageIdentity: try FileIdentity.read(image)))]
            return m
        }
        func wait(_ m: AppModel) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while m.busy && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(50)) }
            precondition(!m.busy, "model did not finish")
        }

        let (destination, image, conflict) = try fixture("Successful")
        let process = FakeProcess()
        var modelOpens = 0
        let service = RunningAppUpdater(processes: { _ in process.handles }, open: { target in
            precondition(try! String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "new")
            modelOpens += 1
        })
        let m = try model(destination, image, conflict, service)
        m.onRunningAppConfirmation = { _ in true }
        m.replaceAll(); try await wait(m)
        check(m.conflicts.isEmpty && modelOpens == 1 && process.requests == 1, "queue quits then replaces then reopens once")
        trash += m.jobs.flatMap { $0.report?.backupsInTrash ?? [] }
        if let imageTrash = m.jobs[0].report?.imageInTrash { trash.append(imageTrash) }

        let (d2, i2, c2) = try fixture("Declined")
        let p2 = FakeProcess()
        let m2 = try model(d2, i2, c2, RunningAppUpdater(processes: { _ in p2.handles }, open: { _ in preconditionFailure("must not reopen") }))
        m2.onRunningAppConfirmation = { _ in false }
        m2.replaceAll(); try await wait(m2)
        check(m2.conflicts.count == 1 && p2.requests == 0 && fm.fileExists(atPath: i2.path), "declined queue item remains pending with DMG retained")
        m2.keepExisting()

        let (d3, i3, c3) = try fixture("Failed")
        let p3 = FakeProcess()
        var retryOpens = 0
        let m3 = try model(d3, i3, c3, RunningAppUpdater(processes: { _ in p3.handles }, open: { _ in retryOpens += 1 }))
        m3.onRunningAppConfirmation = { _ in true }
        let original = root.appendingPathComponent("original-target.app")
        try fm.moveItem(at: c3.target, to: original)
        try fm.createDirectory(at: c3.target, withIntermediateDirectories: false)
        m3.replaceAll(); try await wait(m3)
        check(m3.conflicts.count == 1 && retryOpens == 0 && !p3.running, "failed queue replacement does not reopen the closed app")
        try fm.removeItem(at: c3.target); try fm.moveItem(at: original, to: c3.target)
        m3.replaceAll(); try await wait(m3)
        check(m3.conflicts.isEmpty && retryOpens == 1, "successful retry remembers requested relaunch")
        trash += m3.jobs.flatMap { $0.report?.backupsInTrash ?? [] }
        if let imageTrash = m3.jobs[0].report?.imageInTrash { trash.append(imageTrash) }
    }
}
