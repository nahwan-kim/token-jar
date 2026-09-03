import AppKit
import SwiftUI

@main
struct TokenTankApp: App {
    @NSApplicationDelegateAdaptor(TokenTankApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            DetailPopoverView(model: model)
        } label: {
            #if UITEST
            TokenTankUITestMenuBarLabel(model: model)
            #else
            MenuBarLabelView(model: model)
                .task {
                    guard
                        NSClassFromString("XCTestCase") == nil,
                        ProcessInfo.processInfo.environment["TOKENTANK_DISABLE_AUTOSTART"] != "1"
                    else {
                        return
                    }
                    applicationDelegate.model = model
                    model.ensureStarted()
                }
            #endif
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Label("action.settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Settings {
            ProviderSettingsView(model: model)
                .frame(minWidth: 620, minHeight: 520)
        }

        #if UITEST
        WindowGroup("Token Tank UI Test Detail", id: "ui-test-detail") {
            DetailPopoverView(model: model)
                .frame(width: 420, height: 520)
        }

        WindowGroup("Token Tank UI Test Settings", id: "ui-test-settings") {
            ProviderSettingsView(model: model)
                .frame(minWidth: 620, minHeight: 520)
        }
        #endif

    }
}

#if UITEST
private struct TokenTankUITestMenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarLabelView(model: model)
            .task {
                guard ProcessInfo.processInfo.environment["TOKENTANK_UI_MATRIX"] == "1" else {
                    return
                }
                openWindow(id: "ui-test-detail")
                if ProcessInfo.processInfo.environment["TOKENTANK_UI_SETTINGS"] == "1" {
                    try? await Task.sleep(for: .seconds(30))
                    openWindow(id: "ui-test-settings")
                }
            }
    }
}
#endif


@MainActor
final class TokenTankApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationPending = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        guard let model else { return .terminateNow }
        terminationPending = true
        Task { [weak self] in
            await model.stop()
            self?.terminationPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
