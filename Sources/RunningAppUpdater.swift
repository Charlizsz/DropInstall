import AppKit

@MainActor
final class RunningAppUpdater {
    struct ProcessHandle {
        let terminated: () -> Bool
        let requestQuit: () -> Bool
    }
    enum Preparation {
        case ready(reopen: Bool)
        case blocked(String)
    }

    private let processes: @MainActor (URL) -> [ProcessHandle]
    private let open: @MainActor (URL) async throws -> Void
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 60,
         processes: @escaping @MainActor (URL) -> [ProcessHandle] = RunningAppUpdater.systemProcesses,
         open: @escaping @MainActor (URL) async throws -> Void = RunningAppUpdater.systemOpen) {
        self.timeout = timeout
        self.processes = processes
        self.open = open
    }

    static func systemProcesses(_ url: URL) -> [ProcessHandle] {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard let bundle = application.bundleURL?.resolvingSymlinksInPath().standardizedFileURL,
                  bundle == target || DiskInstaller.isInside(bundle, root: target) else { return nil }
            return ProcessHandle(terminated: { application.isTerminated }, requestQuit: { application.terminate() })
        }
    }

    static func systemOpen(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func prepare(_ target: URL, confirm: (URL) async -> Bool,
                 shouldStop: () -> Bool, progress: (String) -> Void) async -> Preparation {
        guard !shouldStop() else { return .blocked("队列已停止，应用保持待定。") }
        guard !processes(target).isEmpty else { return .ready(reopen: false) }
        guard await confirm(target) else { return .blocked("未获准退出应用，已暂缓更新。") }
        guard !shouldStop() else { return .blocked("队列已停止，应用保持待定。") }
        let handles = processes(target)
        progress("正在等待 \(target.lastPathComponent) 退出…")
        for handle in handles {
            guard !shouldStop() else { return .blocked("队列已停止，应用保持待定。") }
            if !handle.terminated(), !handle.requestQuit(), !handle.terminated() {
                return .blocked("应用未接受退出请求，请处理未保存内容或手动退出后重试。")
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !handles.allSatisfy({ $0.terminated() }) || !processes(target).isEmpty {
            if shouldStop() { return .blocked("队列已停止，未覆盖应用。") }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                return .blocked("应用尚未退出，可能有未保存内容。已暂缓更新，请处理应用提示后重试。")
            }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return .blocked("等待退出已取消，未覆盖应用。") }
        }
        guard !shouldStop() else { return .blocked("队列已停止，未覆盖应用。") }
        return .ready(reopen: true)
    }

    /// Called only with a recorded successful bundle replacement, never on failure.
    func reopen(_ target: URL, replacementSucceeded: Bool) async -> String? {
        guard replacementSucceeded else { return nil }
        do { try await open(target); return nil }
        catch { return "\(target.lastPathComponent) 已更新，但重新打开失败，请手动打开：\(error.localizedDescription)" }
    }
}
