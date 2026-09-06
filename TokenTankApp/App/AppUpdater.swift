import Foundation
import Sparkle

@MainActor
protocol AppUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var onCanCheckForUpdatesChanged: (@MainActor @Sendable (Bool) -> Void)? { get set }

    func start() throws
    func checkForUpdates()
}

@MainActor
final class AppUpdater: AppUpdating {
    private let updaterController: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?
    private var startAttempted = false

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    var onCanCheckForUpdatesChanged: (@MainActor @Sendable (Bool) -> Void)? {
        didSet {
            onCanCheckForUpdatesChanged?(canCheckForUpdates)
        }
    }

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let updater = updaterController.updater
        canCheckObservation = updater.observe(
            \SPUUpdater.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.onCanCheckForUpdatesChanged?(self?.canCheckForUpdates ?? false)
            }
        }
    }

    func start() throws {
        guard !startAttempted else { return }
        startAttempted = true
        try updaterController.updater.start()
    }

    func checkForUpdates() {
        guard startAttempted, canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
    }
}
