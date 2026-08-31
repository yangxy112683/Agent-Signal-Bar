import Foundation

/// A source of WorkBuddy project display names, typically read from WorkBuddy's own local state.
public protocol WorkBuddyDisplayNameSource: Sendable {
    /// Returns project_id → displayName pairs from WorkBuddy local state.
    func fetchProjectDisplayNames() async throws -> [String: String]
}

/// Errors thrown by `WorkBuddyLocalFileDisplayNameSource` when the local WorkBuddy state file
/// cannot be read or does not match any known schema shape.
public enum WorkBuddyLocalFileDisplayNameSourceError: Error, Equatable {
    case fileNotFound(URL)
    case invalidJSON(URL)
}

/// Reads WorkBuddy's own local file (`~/.workbuddy/workspace-display-names.json` by default) to
/// discover project display names. The exact schema of this file is not guaranteed, so this
/// source tolerates two shapes:
///
/// 1. `{"displayNames": {"<project_id>": "bblock"}}`
/// 2. `{"workspaces": {"<project_id>": {"displayName": "bblock", ...}}}`
public struct WorkBuddyLocalFileDisplayNameSource: WorkBuddyDisplayNameSource {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy", isDirectory: true)
            .appendingPathComponent("workspace-display-names.json")
    }

    public func fetchProjectDisplayNames() async throws -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else {
            throw WorkBuddyLocalFileDisplayNameSourceError.fileNotFound(fileURL)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkBuddyLocalFileDisplayNameSourceError.invalidJSON(fileURL)
        }

        if let displayNames = json["displayNames"] as? [String: String] {
            return displayNames
        }

        if let workspaces = json["workspaces"] as? [String: Any] {
            var resolved: [String: String] = [:]
            for (projectID, value) in workspaces {
                guard let entry = value as? [String: Any],
                      let displayName = entry["displayName"] as? String
                else {
                    continue
                }
                resolved[projectID] = displayName
            }
            return resolved
        }

        throw WorkBuddyLocalFileDisplayNameSourceError.invalidJSON(fileURL)
    }
}

/// Outcome of a single `WorkBuddyProjectNameSynchronizer.synchronize` call.
public struct SyncResult: Sendable, Equatable {
    public let insertedCount: Int
    public let updatedCount: Int
    public let unchangedCount: Int
    public let lastSyncedAt: Date

    public init(insertedCount: Int, updatedCount: Int, unchangedCount: Int, lastSyncedAt: Date) {
        self.insertedCount = insertedCount
        self.updatedCount = updatedCount
        self.unchangedCount = unchangedCount
        self.lastSyncedAt = lastSyncedAt
    }
}

/// Merges display names fetched from a `WorkBuddyDisplayNameSource` into the on-disk
/// `workbuddy-project-names.json` cache read by `WorkBuddyProjectNameCache`.
///
/// Merge rules:
/// - Entries present only in the existing cache (not returned by the source) are preserved as-is.
/// - Entries with an empty/whitespace-only display name from the source are skipped.
/// - If the source throws, the cache file is left untouched and the error is rethrown.
/// - If nothing changes (source empty, or all entries already match), the file is not rewritten.
public struct WorkBuddyProjectNameSynchronizer: Sendable {
    public init() {}

    private struct FileDocument: Codable {
        var version: Int
        var projects: [String: ProjectEntry]

        struct ProjectEntry: Codable, Equatable {
            var displayName: String
        }
    }

    public func synchronize(
        source: WorkBuddyDisplayNameSource,
        cacheFileURL: URL,
        now: Date
    ) async throws -> SyncResult {
        let fetched = try await source.fetchProjectDisplayNames()

        var document = Self.readDocument(at: cacheFileURL)

        var insertedCount = 0
        var updatedCount = 0
        var unchangedCount = 0

        for (projectID, rawDisplayName) in fetched {
            let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else { continue }

            if let existingEntry = document.projects[projectID] {
                if existingEntry.displayName == displayName {
                    unchangedCount += 1
                } else {
                    document.projects[projectID] = FileDocument.ProjectEntry(displayName: displayName)
                    updatedCount += 1
                }
            } else {
                document.projects[projectID] = FileDocument.ProjectEntry(displayName: displayName)
                insertedCount += 1
            }
        }

        if insertedCount > 0 || updatedCount > 0 {
            try Self.write(document: document, to: cacheFileURL)
        }

        return SyncResult(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            unchangedCount: unchangedCount,
            lastSyncedAt: now
        )
    }

    private static func readDocument(at url: URL) -> FileDocument {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(FileDocument.self, from: data)
        else {
            return FileDocument(version: 1, projects: [:])
        }
        return document
    }

    private static func write(document: FileDocument, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(document)
        try data.write(to: url, options: .atomic)
    }
}
