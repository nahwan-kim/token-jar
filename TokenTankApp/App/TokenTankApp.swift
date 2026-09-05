import AppKit
import SwiftUI

@main
struct TokenTankApp: App {
    @NSApplicationDelegateAdaptor(TokenTankApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            DetailPopoverView(model: model)
                .environment(\.locale, model.locale)
        } label: {
            #if UITEST
            TokenTankUITestMenuBarLabel(model: model)
                .environment(\.locale, model.locale)
            #else
            MenuBarLabelView(model: model)
                .environment(\.locale, model.locale)
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
                    Label("settings.title", systemImage: "gearshape")
                }
                .environment(\.locale, model.locale)
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("Token Tank", id: "detail") {
            DetailPopoverView(model: model, isStandaloneWindow: true)
                .environment(\.locale, model.locale)
        }
        .defaultSize(width: 480, height: 640)
        .windowResizability(.contentMinSize)
        Settings {
            ProviderSettingsView(model: model)
                .environment(\.locale, model.locale)
                .frame(minWidth: 620, minHeight: 520)
        }

        #if UITEST
        WindowGroup("Token Tank UI Test Detail", id: "ui-test-detail") {
            DetailPopoverView(model: model)
                .environment(\.locale, model.locale)
                .frame(width: 480, height: 640)
        }

        WindowGroup("Token Tank UI Test Settings", id: "ui-test-settings") {
            ProviderSettingsView(model: model)
                .environment(\.locale, model.locale)
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
