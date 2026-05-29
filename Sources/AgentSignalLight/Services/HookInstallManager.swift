import Foundation

struct HookInstallManager: Sendable {
    func preview() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "all", "--codex-scope", root.codexScope, "--dry-run"]
        )
    }

    func previewClaude() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "claude", "--dry-run"]
        )
    }

    func install() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "all", "--codex-scope", root.codexScope, "--install"]
        )
    }

    func installClaude() throws -> HookInstallResult {
        let root = try hookRoot()
        return try runInstallHooks(
            hookRoot: root,
            arguments: ["--target", "claude", "--install"]
        )
    }

    private func runInstallHooks(hookRoot: HookRoot, arguments: [String]) throws -> HookInstallResult {
        let hookRootURL = hookRoot.url
        let scriptURL = hookRootURL.appendingPathComponent("script/install_hooks.py")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw HookInstallError.missingInstallScript(scriptURL.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path] + arguments
        process.currentDirectoryURL = hookRootURL

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        let result = HookInstallResult(
            exitCode: process.terminationStatus,
            output: output.trimmingCharacters(in: .whitespacesAndNewlines),
            error: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        guard process.terminationStatus == 0 else {
            throw HookInstallError.commandFailed(result)
        }

        return result
    }

    private func hookRoot() throws -> HookRoot {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let distParent = bundleURL.deletingLastPathComponent()
        if distParent.lastPathComponent == "dist" {
            let rootURL = distParent.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("script/install_hooks.py").path) {
                return HookRoot(url: rootURL, codexScope: "project")
            }
        }

        if let resourceURL = Bundle.main.resourceURL?.standardizedFileURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("script/install_hooks.py").path) {
            return HookRoot(url: resourceURL, codexScope: "user")
        }

        let currentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        if FileManager.default.fileExists(atPath: currentURL.appendingPathComponent("script/install_hooks.py").path) {
            return HookRoot(url: currentURL, codexScope: "project")
        }

        throw HookInstallError.cannotLocateProjectRoot(bundleURL.path)
    }
}

private struct HookRoot: Sendable {
    let url: URL
    let codexScope: String
}

struct HookInstallResult: Sendable {
    let exitCode: Int32
    let output: String
    let error: String

    var displayText: String {
        if output.isEmpty {
            return error.isEmpty ? "hook command completed" : error
        }
        if error.isEmpty {
            return output
        }
        return "\(output)\n\(error)"
    }
}

enum HookInstallError: Error, LocalizedError {
    case cannotLocateProjectRoot(String)
    case missingInstallScript(String)
    case commandFailed(HookInstallResult)

    var errorDescription: String? {
        switch self {
        case .cannotLocateProjectRoot(let appPath):
            return "无法从当前 app 位置找到项目根目录或内置 hook 资源：\(appPath)"
        case .missingInstallScript(let path):
            return "没有找到可执行的 hook 安装脚本：\(path)"
        case .commandFailed(let result):
            let detail = result.displayText
            return detail.isEmpty ? "hook 安装命令失败，退出码 \(result.exitCode)" : detail
        }
    }
}
