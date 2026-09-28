import BackgroundTasks
import SwiftUI
import UIKit

@main
struct NotyApp: App {
    @UIApplicationDelegateAdaptor(NotyAppDelegate.self) private var appDelegate
    @State private var store = NotyStore()
    @State private var oneDrive = OneDriveService()
    @State private var importAlertTitle = "Import"
    @State private var importAlertMessage: String?

    init() {
        // Register the Inter resources before SwiftUI resolves shared theme fonts.
        NotionFontRegistrar.registerInter()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(store: store, oneDrive: oneDrive)
                .onOpenURL { url in
                    Task {
                        do {
                            _ = try await store.importDocument(from: url, folderID: nil, converter: nil)
                            if let message = store.lastOperationMessage {
                                importAlertTitle = "Import details"
                                importAlertMessage = message
                            }
                        } catch {
                            importAlertTitle = "Import failed"
                            importAlertMessage = error.localizedDescription
                        }
                    }
                }
                .alert(importAlertTitle, isPresented: Binding(
                    get: { importAlertMessage != nil },
                    set: { if !$0 { importAlertMessage = nil } }
                )) {
                    Button("OK") { importAlertMessage = nil }
                } message: {
                    Text(importAlertMessage ?? "The document could not be opened.")
                }
        }
    }
}

/// Registers the processing task during the UIKit launch sequence, which is
/// early enough for iPadOS to relaunch Noty specifically to finish cloud work.
final class NotyAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: NotyBackgroundSyncScheduler.identifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleCloudSync(processingTask)
        }
        return true
    }

    private static func handleCloudSync(_ backgroundTask: BGProcessingTask) {
        let work = Task { @MainActor in
            let store = NotyStore()
            let oneDrive = OneDriveService()
            let hasICloudWork = store.hasICloudMirror
            let hasOneDriveWork = oneDrive.isConnected

            // A processing request is one-shot. Re-arm it while cloud backup is
            // configured so iPadOS has another opportunity after this run.
            NotyBackgroundSyncScheduler.scheduleIfNeeded(
                hasWork: hasICloudWork || hasOneDriveWork
            )

            if hasOneDriveWork {
                await oneDrive.syncAllPDFs(store: store)
            }
            if Task.isCancelled {
                backgroundTask.setTaskCompleted(success: false)
                return
            }
            if hasICloudWork {
                await store.syncICloudMirror()
            }

            let iCloudFailed = hasICloudWork && store.syncStatus.localizedCaseInsensitiveContains("failed")
            let oneDriveFailed = hasOneDriveWork && oneDrive.lastError != nil
            backgroundTask.setTaskCompleted(
                success: !Task.isCancelled && !iCloudFailed && !oneDriveFailed
            )
        }

        backgroundTask.expirationHandler = {
            work.cancel()
        }
    }
}

enum NotyBackgroundSyncScheduler {
    static let identifier = "com.malik.noty.sync"

    /// Ask iPadOS for a future retry. The date is only an earliest start time;
    /// iPadOS decides whether and when the processing task actually runs.
    static func scheduleIfNeeded(hasWork: Bool) {
        guard hasWork else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }

        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("Noty could not schedule a background cloud sync: %@", error.localizedDescription)
        }
    }
}
