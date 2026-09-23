import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InstallJob: Identifiable {
    enum State { case waiting, running, pending, installed, skipped, attention }
    let id = UUID()
    var url: URL
    var originalURL: URL?
    var state: State = .waiting
    var status = "等待安装"
    var report: InstallReport?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var jobs: [InstallJob] = []
    @Published var busy = false
    @Published var stopRequested = false
    @Published var inputMessage: String?
    @Published var showConflictSheet = false
    @Published var searchRules = ImageSearchRuleStore.load()
    @Published var showRules = false
    private(set) var quitRequested = false
    var onRequestDecision: (() -> Void)?
    var onReadyToQuit: (() -> Void)?
    private let destinationOverride: URL?
    init(destination: URL? = nil) { destinationOverride = destination }
    @Published var userOnly = UserDefaults.standard.bool(forKey: "installForCurrentUser") {
        didSet { UserDefaults.standard.set(userOnly, forKey: "installForCurrentUser") }
    }
    var destination: URL {
        destinationOverride ?? (userOnly ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
                 : URL(fileURLWithPath: "/Applications", isDirectory: true)
        )
    }
    struct ConflictItem: Identifiable {
        let jobID: UUID
        let imageName: String
        let conflict: PendingReplacement
        var id: UUID { conflict.id }
    }
    var conflicts: [ConflictItem] {
        jobs.flatMap { job in
            (job.report?.pending ?? []).map { ConflictItem(jobID: job.id, imageName: job.url.lastPathComponent, conflict: $0) }
        }
    }
    var pendingCount: Int { jobs.filter { $0.state == .waiting }.count }
    var finishedCount: Int { jobs.filter { $0.report != nil }.count }
    var installedCount: Int { jobs.compactMap(\.report).reduce(0) { $0 + $1.installed.count } }

    func add(_ urls: [URL], startImmediately: Bool = false) {
        guard !quitRequested else { return }
        inputMessage = nil
        let accepted = urls.filter(ImageInput.accepts)
        if accepted.count != urls.count { inputMessage = "仅接受 DMG 或 ISO 文件；其他项目已忽略。" }
        var seen: Set<URL> = []
        for url in accepted {
            let canonical = url.standardizedFileURL
            guard seen.insert(canonical).inserted,
                  !jobs.contains(where: { ($0.url == canonical || $0.originalURL == canonical) && ($0.state == .waiting || $0.state == .running || $0.state == .pending) }) else { continue }
            var job = InstallJob(url: canonical)
            do {
                job.url = try ImageInput.prepare(canonical)
                if canonical.pathExtension.lowercased() == "iso" { job.originalURL = canonical }
                guard !jobs.contains(where: { $0.url == job.url && ($0.state == .waiting || $0.state == .running || $0.state == .pending) }) else { continue }
            } catch {
                job.state = .attention
                job.status = "无法改名"
                job.report = InstallReport(problems: [error.localizedDescription])
            }
            jobs.append(job)
        }
        if startImmediately { start() }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dmg") ?? .diskImage, UTType(filenameExtension: "iso") ?? .diskImage]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "加入队列"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func start() {
        guard !quitRequested, !busy, pendingCount > 0 else { return }
        busy = true
        stopRequested = false
        showConflictSheet = false
        showRules = false
        let target = destination
        let rules = searchRules // Freeze rules for this whole batch.
        Task {
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "安装 DMG 并弹出磁盘")
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                busy = false
                stopRequested = false
                if quitRequested { finishQuit() }
                else if pendingCount == 0 && !conflicts.isEmpty { requestDecision() }
            }
            while !stopRequested, let index = jobs.firstIndex(where: { $0.state == .waiting }) {
                let id = jobs[index].id
                let url = jobs[index].url
                jobs[index].state = .running
                jobs[index].status = "准备安装…"
                let report = await Task.detached(priority: .userInitiated) {
                    DiskInstaller(destination: target, searchRules: rules).install(url) { status in
                        Task { @MainActor [weak self] in
                            guard let self, let i = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[i].state == .running else { return }
                            self.jobs[i].status = status
                        }
                    }
                }.value
                guard let i = jobs.firstIndex(where: { $0.id == id }) else { continue }
                jobs[i].report = report
                refreshStatus(i)
            }
        }
    }

    func saveRules(_ rules: [ImageSearchRule]) {
        guard !busy, !quitRequested, rules.allSatisfy(\.isValid) else { return }
        searchRules = rules
        ImageSearchRuleStore.save(rules)
        showRules = false
    }

    func retry(_ id: UUID) {
        guard !busy, let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].report?.pending.isEmpty != false else { return }
        if jobs[index].url.pathExtension.lowercased() == "iso" {
            do {
                let original = jobs[index].url
                jobs[index].url = try ImageInput.prepare(original)
                jobs[index].originalURL = original
            } catch {
                jobs[index].status = "无法改名"
                jobs[index].report = InstallReport(problems: [error.localizedDescription])
                return
            }
        }
        jobs[index].state = .waiting
        jobs[index].status = "等待安装"
        jobs[index].report = nil
    }

    private func refreshStatus(_ index: Int) {
        guard let report = jobs[index].report else { return }
        if !report.pending.isEmpty {
            jobs[index].state = .pending
            jobs[index].status = report.problems.isEmpty && report.replacementProblems.isEmpty ? "待确认覆盖" : "待确认覆盖（另有问题）"
        } else if !report.problems.isEmpty || !report.replacementProblems.isEmpty {
            jobs[index].state = .attention
            jobs[index].status = report.installed.isEmpty ? "需要处理" : "部分完成"
        } else if report.installed.isEmpty {
            jobs[index].state = .skipped
            jobs[index].status = "已保留现有版本"
        } else {
            jobs[index].state = .installed
            jobs[index].status = "安装完成"
        }
    }

    func requestDecision() {
        guard !quitRequested, !busy, !conflicts.isEmpty else { return }
        showConflictSheet = true
        onRequestDecision?()
    }

    func keepExisting() {
        guard !busy else { return }
        showConflictSheet = false
        for item in conflicts {
            guard let i = jobs.firstIndex(where: { $0.id == item.jobID }) else { continue }
            do { try DiskInstaller.discard(item.conflict) }
            catch { jobs[i].report?.problems.append(error.localizedDescription) }
            jobs[i].report?.pending.removeAll { $0.id == item.id }
            jobs[i].report?.replacementProblems.removeValue(forKey: item.id)
            jobs[i].report?.skipped.append(item.conflict.name)
            refreshStatus(i)
        }
    }

    func replaceAll() {
        guard !quitRequested, !busy, !conflicts.isEmpty else { return }
        let approved = conflicts // Consent is limited to the items in this sheet.
        showConflictSheet = false
        busy = true
        stopRequested = false
        Task {
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "批量覆盖应用")
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                let stopped = stopRequested
                busy = false
                stopRequested = false
                if quitRequested { finishQuit() }
                else if !stopped && pendingCount > 0 { start() }
            }
            var handledJobs: Set<UUID> = []
            for item in approved {
                if stopRequested { break }
                guard handledJobs.insert(item.jobID).inserted else { continue }
                guard let i = jobs.firstIndex(where: { $0.id == item.jobID }) else { continue }
                jobs[i].state = .running
                jobs[i].status = "正在准备已确认的覆盖项目…"
                var selected: [PendingReplacement] = []
                for candidate in approved where candidate.jobID == item.jobID {
                    if let reason = Self.replacementBlockReason(candidate.conflict.target) {
                        jobs[i].report?.replacementProblems[candidate.id] = reason
                    } else { selected.append(candidate.conflict) }
                }
                guard !selected.isEmpty else { refreshStatus(i); continue }
                let selectedConflicts = selected
                let jobID = item.jobID
                let result = await Task.detached(priority: .userInitiated) {
                    DiskInstaller.replaceDeferred(selectedConflicts, progress: { status in
                        Task { @MainActor [weak self] in
                            guard let self, let index = self.jobs.firstIndex(where: { $0.id == jobID }), self.jobs[index].state == .running else { return }
                            self.jobs[index].status = status
                        }
                    }, replacementCheck: { target in
                        DispatchQueue.main.sync { Self.replacementBlockReason(target) }
                    })
                }.value
                let completed = Set(result.completedReplacements)
                for conflict in selected {
                    if completed.contains(conflict.id) {
                        jobs[i].report?.pending.removeAll { $0.id == conflict.id }
                        jobs[i].report?.replacementProblems.removeValue(forKey: conflict.id)
                        jobs[i].report?.installed.append(conflict.name)
                    } else {
                        jobs[i].report?.replacementProblems[conflict.id] = result.replacementProblems[conflict.id]
                            ?? (result.problems.isEmpty ? "未能完成覆盖，请重试。" : result.problems.joined(separator: "\n"))
                    }
                }
                jobs[i].report?.backupsInTrash += result.backupsInTrash
                jobs[i].report?.ejected = result.ejected
                if !result.problems.isEmpty && completed.count == selected.count {
                    jobs[i].report?.problems += result.problems
                }
                if let report = jobs[i].report, report.readyToTrashImage {
                    let imageURL = jobs[i].url
                    jobs[i].report = await Task.detached(priority: .userInitiated) {
                        DiskInstaller.finishImage(imageURL, report: report)
                    }.value
                }
                refreshStatus(i)
            }
        }
    }

    private static func replacementBlockReason(_ url: URL) -> String? {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        if target == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL {
            return "DropInstall 自身需退出后用 Finder 手动更新，请在这里保留现有版本。"
        }
        if NSWorkspace.shared.runningApplications.contains(where: { app in
            guard let running = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL else { return false }
            return running == target || DiskInstaller.isInside(running, root: target)
        }) {
            return "\(target.lastPathComponent) 正在运行。退出该应用后，可再次确认覆盖。"
        }
        return nil
    }

    /// One quit request is enough: stop taking new work, finish the current item,
    /// discard unapproved staged copies, then let NSApplication finish termination.
    func requestQuit() {
        guard !quitRequested else { return }
        quitRequested = true
        stopRequested = true
        showConflictSheet = false
        showRules = false
        if !busy { finishQuit() }
    }

    private func finishQuit() {
        keepExisting()
        onReadyToQuit?()
    }
}

@MainActor
final class ServicesProvider: NSObject {
    let receive: ([URL]) -> Void
    init(receive: @escaping ([URL]) -> Void) { self.receive = receive }

    @objc func installDMG(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, urls.allSatisfy(ImageInput.accepts) else {
            error.pointee = "请在 Finder 中选择一个或多个 DMG 或 ISO 文件。"
            return
        }
        // Return immediately; the app owns the asynchronous queue and progress UI.
        receive(urls)
    }
}
