import Foundation
import XCTest

/// Hook 安装合并缝（ADR-0004 / #19）：对 `install_hooks.py` 的 WorkBuddy 托管 CLI 目标
/// 做预览 / 安装 / 卸载，不测 App 按钮点击。
final class WorkBuddyHookInstallTests: XCTestCase {
    private var temporaryHome: URL!
    private var installerURL: URL {
        repositoryRoot.appendingPathComponent("script/install_hooks.py")
    }

    private var genericWrapperURL: URL {
        repositoryRoot.appendingPathComponent("scripts/generic-agent-signal-hook")
    }

    private var workbuddySettingsURL: URL {
        temporaryHome.appendingPathComponent(".workbuddy/settings.json")
    }

    private var codebuddySettingsURL: URL {
        temporaryHome.appendingPathComponent(".codebuddy/settings.json")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("workbuddy-hook-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryHome {
            try? FileManager.default.removeItem(at: temporaryHome)
        }
        temporaryHome = nil
    }

    func testWorkBuddyDryRunDoesNotWriteConfig() throws {
        let output = try runInstaller(arguments: ["--target", "workbuddy", "--dry-run"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: workbuddySettingsURL.path))
        XCTAssertTrue(output.contains("generic-agent-signal-hook"))
        XCTAssertTrue(output.contains("No files were written"))
    }

    func testWorkBuddyInstallCreatesConfigAndPassesThroughRawAgentAndCwd() throws {
        _ = try runInstaller(arguments: ["--target", "workbuddy", "--install"])
        let settings = try loadJSON(workbuddySettingsURL)
        let command = try firstHookCommand(in: settings)

        XCTAssertTrue(command.contains(genericWrapperURL.path))
        XCTAssertFalse(command.contains("workbuddy_"))
        XCTAssertFalse(command.contains("cursor_"))
        XCTAssertFalse(command.contains("--agent"))
        XCTAssertFalse(command.contains("("))
        XCTAssertEqual(try hookEventNames(in: settings).sorted(), Self.expectedWorkBuddyEvents.sorted())
    }

    func testWorkBuddyInstallIsIdempotentAndBacksUpExistingConfig() throws {
        try FileManager.default.createDirectory(
            at: workbuddySettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"keep":true,"hooks":{}}
        """.write(to: workbuddySettingsURL, atomically: true, encoding: .utf8)

        _ = try runInstaller(arguments: ["--target", "workbuddy", "--install"])
        _ = try runInstaller(arguments: ["--target", "workbuddy", "--install"])

        let settings = try loadJSON(workbuddySettingsURL)
        XCTAssertEqual(settings["keep"] as? Bool, true)
        XCTAssertEqual(try hookCommandCount(in: settings, wrapperName: "generic-agent-signal-hook"), Self.expectedWorkBuddyEvents.count)
        XCTAssertFalse(try backups(of: workbuddySettingsURL).isEmpty)
    }

    func testWorkBuddyUninstallRemovesOnlyAgentSignalHooks() throws {
        try FileManager.default.createDirectory(
            at: workbuddySettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"theme":"dark","hooks":{}}
        """.write(to: workbuddySettingsURL, atomically: true, encoding: .utf8)

        _ = try runInstaller(arguments: ["--target", "workbuddy", "--install"])
        _ = try runInstaller(arguments: ["--target", "workbuddy", "--remove", "--install"])

        let settings = try loadJSON(workbuddySettingsURL)
        XCTAssertEqual(settings["theme"] as? String, "dark")
        XCTAssertEqual(try hookCommandCount(in: settings, wrapperName: "generic-agent-signal-hook"), 0)
    }

    func testTargetAllIncludesWorkBuddyAndLeavesCodeBuddyConfigUntouched() throws {
        try FileManager.default.createDirectory(
            at: codebuddySettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = """
        {"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo keep-codebuddy"}]}]}}
        """
        try original.write(to: codebuddySettingsURL, atomically: true, encoding: .utf8)

        _ = try runInstaller(arguments: ["--target", "all", "--install"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: workbuddySettingsURL.path))
        XCTAssertEqual(try String(contentsOf: codebuddySettingsURL, encoding: .utf8), original)
        let settings = try loadJSON(workbuddySettingsURL)
        XCTAssertGreaterThan(try hookCommandCount(in: settings, wrapperName: "generic-agent-signal-hook"), 0)
    }

    private static let expectedWorkBuddyEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Notification",
        "Stop",
        "PermissionRequest",
        "SubagentStart",
        "SubagentStop",
        "SessionEnd"
    ]

    @discardableResult
    private func runInstaller(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [installerURL.path, "--home", temporaryHome.path] + arguments
        process.currentDirectoryURL = repositoryRoot

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "installer failed: \(error)\n\(output)")
        return output
    }

    private func loadJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func firstHookCommand(in settings: [String: Any]) throws -> String {
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        for blocks in hooks.values {
            guard let blocks = blocks as? [[String: Any]] else { continue }
            for block in blocks {
                guard let items = block["hooks"] as? [[String: Any]] else { continue }
                if let command = items.first?["command"] as? String {
                    return command
                }
            }
        }
        XCTFail("no hook command found")
        return ""
    }

    private func hookEventNames(in settings: [String: Any]) throws -> [String] {
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        return Array(hooks.keys)
    }

    private func hookCommandCount(in settings: [String: Any], wrapperName: String) throws -> Int {
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        var count = 0
        for blocks in hooks.values {
            guard let blocks = blocks as? [[String: Any]] else { continue }
            for block in blocks {
                guard let items = block["hooks"] as? [[String: Any]] else { continue }
                for item in items {
                    if let command = item["command"] as? String, command.contains(wrapperName) {
                        count += 1
                    }
                }
            }
        }
        return count
    }

    private func backups(of url: URL) throws -> [URL] {
        let parent = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".bak-"
        return try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
}
