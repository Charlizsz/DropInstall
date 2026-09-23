import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var window: NSWindow?
    private var provider: ServicesProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMenu()
        model.onRequestDecision = { [weak self] in self?.showWindow() }
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
