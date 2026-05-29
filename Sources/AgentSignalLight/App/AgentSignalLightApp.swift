import AgentSignalLightCore
import AppKit
import Darwin
import SwiftUI

enum SingleInstanceGuard {
    static func activateExistingInstanceIfNeeded() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let existingApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { application in
                application.processIdentifier != currentProcessIdentifier && !application.isTerminated
            }

        guard let existingApplication else {
            return false
        }

        existingApplication.activate(options: [])
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if DebugLaunchOptions.shouldOpenDebugWindow {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                AgentSignalAppServices.statusBarController.showDebugWindow()
            }
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }

        DispatchQueue.main.async {
            AgentSignalAppServices.statusBarController.showDebugWindow()
        }
        return true
    }
}

@MainActor
enum AgentSignalAppServices {
    static let model = MenuBarStatusModel()
    static let statusBarController = StatusBarController(model: model)
}

@MainActor
@main
struct AgentSignalLightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: MenuBarStatusModel
    private let statusBarController: StatusBarController

    init() {
        if SingleInstanceGuard.activateExistingInstanceIfNeeded() {
            exit(0)
        }

        let sharedModel = AgentSignalAppServices.model
        _model = StateObject(wrappedValue: sharedModel)
        statusBarController = AgentSignalAppServices.statusBarController
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
