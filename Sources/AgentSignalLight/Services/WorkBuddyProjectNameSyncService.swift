import AgentSignalLightCore
import Foundation

/// Periodically syncs WorkBuddy project display names into the local cache file that
/// `WorkBuddyProjectNameCache` reads from. Runs entirely in the background; failures are
/// logged (DEBUG only) and never surfaced to the rest of the app.
@MainActor
final class WorkBuddyProjectNameSyncService {
    static let defaultSyncInterval: TimeInterval = 90

    private let source: WorkBuddyDisplayNameSource
    private let cacheFileURL: URL
    private let syncInterval: TimeInterval
    private let synchronizer = WorkBuddyProjectNameSynchronizer()

    private var timer: Timer?

    private(set) var lastSyncedAt: Date?
    private(set) var lastError: Error?

    init(
        source: WorkBuddyDisplayNameSource = WorkBuddyLocalFileDisplayNameSource(),
        cacheFileURL: URL = WorkBuddyProjectNameCache.defaultCacheFileURL(),
        syncInterval: TimeInterval = WorkBuddyProjectNameSyncService.defaultSyncInterval
    ) {
        self.source = source
        self.cacheFileURL = cacheFileURL
        self.syncInterval = syncInterval
    }

    func start() {
        stop()

        Task { [weak self] in
            await self?.syncOnce()
        }

        let timer = Timer(timeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.syncOnce()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func syncOnce() async {
        do {
            let result = try await synchronizer.synchronize(
                source: source,
                cacheFileURL: cacheFileURL,
                now: Date()
            )
            lastSyncedAt = result.lastSyncedAt
            lastError = nil
        } catch {
            lastError = error
            #if DEBUG
            debugPrint("[WorkBuddyProjectNameSyncService] sync failed: \(error)")
            #endif
        }
    }
}
