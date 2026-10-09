import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var window: NSWindow?
    private var provider: ServicesProvider?
    private var runningAppAlert: NSAlert?

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMenu()
        model.onRequestDecision = { [weak self] in self?.showWindow() }
        model.onRunningAppConfirmation = { [weak self] target in
            guard let self else { return false }
            return await self.confirmQuitAndUpdate(target)
        }
        model.onCancelRunningAppConfirmation = { [weak self] in
            guard let alert = self?.runningAppAlert else { return }
            alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort)
        }
        provider = ServicesProvider { [weak self] urls in
            self?.showWindow()
            self?.model.add(urls, startImmediately: true)
        }
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        showWindow()
        // Optional launch-time queue import; never starts an install implicitly.
        if CommandLine.arguments.dropFirst().first == "--enqueue" {
            model.add(CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) })
        }
    }

    private func confirmQuitAndUpdate(_ target: URL) async -> Bool {
        showWindow()
        guard let window else { return false }
        // Let the batch-confirmation sheet finish dismissing before presenting this one.
        while window.attachedSheet != nil {
            guard !model.stopRequested, !model.quitRequested else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !model.stopRequested, !model.quitRequested else { return false }
        let alert = NSAlert()
        alert.messageText = "\(target.deletingPathExtension().lastPathComponent) 正在运行"
        alert.informativeText = "是否帮你正常退出，更新成功后再重新打开？如果有未保存内容，请先处理该应用的提示。不会强制退出。"
        alert.addButton(withTitle: "退出并更新")
        alert.addButton(withTitle: "暂不更新")
        runningAppAlert = alert
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.runningAppAlert = nil
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    @objc func showWindow() {
        guard !model.quitRequested else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "DropInstall"
            window.contentView = NSHostingView(rootView: InstallerView(model: model))
            window.minSize = NSSize(width: 700, height: 690)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showWindow()
        model.add(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        window?.orderOut(nil)
        sender.setActivationPolicy(.accessory)
        if !model.busy {
            model.requestQuit()
            return .terminateNow
        }
        model.onReadyToQuit = { sender.reply(toApplicationShouldTerminate: true) }
        model.requestQuit()
        return .terminateLater
    }

    private func createMenu() {
        let bar = NSMenu()
        let item = NSMenuItem()
        bar.addItem(item)
        let app = NSMenu(title: "DropInstall")
        app.addItem(withTitle: "关于 DropInstall", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu(title: "服务")
        let serviceItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        serviceItem.submenu = services
        app.addItem(serviceItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 DropInstall", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "退出 DropInstall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app
        let windowItem = NSMenuItem()
        bar.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        let show = NSMenuItem(title: "显示安装队列", action: #selector(showWindow), keyEquivalent: "0")
        show.target = self
        windowMenu.addItem(show)
        windowItem.submenu = windowMenu
        NSApp.mainMenu = bar
    }
}

@main
struct DropInstallMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
