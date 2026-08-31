import Foundation

/// Maps WorkBuddy Teams `CODEBUDDY_PROJECT_ID` values to UI display names (e.g. `bblock`).
/// File: `~/.agent-signal/workbuddy-project-names.json` (or beside `status.json` when state dir is overridden).
public enum WorkBuddyProjectNameCache {
    private struct FileDocument: Decodable {
        let projects: [String: ProjectEntry]?

        struct ProjectEntry: Decodable {
            let displayName: String?
        }
    }

    #if DEBUG
    /// Test-only override for the cache file location.
    nonisolated(unsafe) static var cacheFileURLOverride: URL?
    #endif

    nonisolated(unsafe) private static var cachedProjects: [String: String] = [:]
    nonisolated(unsafe) private static var loadedFileModificationTime: Date?

    public static func displayName(
        forProjectID projectID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let trimmed = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        reloadIfNeeded(environment: environment)
        return cachedProjects[trimmed]
    }

    public static func resetForTesting() {
        cachedProjects = [:]
        loadedFileModificationTime = nil
        #if DEBUG
        cacheFileURLOverride = nil
        #endif
    }

    public static func defaultCacheFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let stateDirectory = nonEmptyEnvironmentValue("AGENT_SIGNAL_LIGHT_STATE_DIR", in: environment)
            ?? nonEmptyEnvironmentValue("SIGNAL_LIGHT_STATE_DIR", in: environment)
            ?? "/tmp/agent-signal"
        return URL(fileURLWithPath: (stateDirectory as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("workbuddy-project-names.json")
    }

    private static func reloadIfNeeded(environment: [String: String]) {
        #if DEBUG
        let fileURL = cacheFileURLOverride ?? defaultCacheFileURL(environment: environment)
        #else
        let fileURL = defaultCacheFileURL(environment: environment)
        #endif

        let modificationTime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate])
            as? Date
        if modificationTime == loadedFileModificationTime {
            return
        }

        loadedFileModificationTime = modificationTime
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(FileDocument.self, from: data),
              let projects = document.projects
        else {
            cachedProjects = [:]
            return
        }

        var resolved: [String: String] = [:]
        for (projectID, entry) in projects {
            guard let name = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else {
                continue
            }
            resolved[projectID] = name
        }
        cachedProjects = resolved
    }

    private static func nonEmptyEnvironmentValue(_ key: String, in environment: [String: String]) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
