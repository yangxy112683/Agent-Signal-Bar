import Foundation

struct LaunchAtLoginManager: Sendable {
    private static let launchctlTimeout: TimeInterval = 5

    let label: String
    let appURL: URL
    let launchAgentDirectory: URL

    init(
        label: String = "com.agentsignallight.AgentSignalLight",
        appURL: URL = Bundle.main.bundleURL,
        launchAgentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    ) {
        self.label = label
        self.appURL = appURL
        self.launchAgentDirectory = launchAgentDirectory
    }

    var plistURL: URL {
        launchAgentDirectory.appendingPathComponent("\(label).plist")
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private func install() throws {
        try FileManager.default.createDirectory(
            at: launchAgentDirectory,
            withIntermediateDirectories: true
        )

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/usr/bin/open</string>
            <string>\(appURL.path)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>StandardOutPath</key>
          <string>/tmp/agent-signal/app.out.log</string>
          <key>StandardErrorPath</key>
          <string>/tmp/agent-signal/app.err.log</string>
        </dict>
        </plist>
        """

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: "/tmp/agent-signal", isDirectory: true),
            withIntermediateDirectories: true
        )
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        try? runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistURL.path], allowsFailure: true)
        try runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private func uninstall() throws {
        try? runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistURL.path], allowsFailure: true)
        try? FileManager.default.removeItem(at: plistURL)
    }

    private func runLaunchctl(arguments: [String], allowsFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        let deadline = Date().addingTimeInterval(Self.launchctlTimeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw LaunchAtLoginError.launchctlFailed("launchctl timed out")
        }

        if process.terminationStatus != 0 && !allowsFailure {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LaunchAtLoginError.launchctlFailed(message ?? "launchctl failed")
        }
    }
}

enum LaunchAtLoginError: Error, LocalizedError {
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let message):
            return message
        }
    }
}
