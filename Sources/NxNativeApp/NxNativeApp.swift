import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct NxNativeApp: App {
    @StateObject private var model = BuildModel()

    var body: some Scene {
        WindowGroup("nxnative") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 620)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About nxnative") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
        }
    }
}

enum BuildTarget: String, CaseIterable, Identifiable {
    case macOS
    case iOS
    case iPadOS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macOS: "macOS app"
        case .iOS: "iOS IPA"
        case .iPadOS: "iPadOS IPA"
        }
    }

    var subtitle: String {
        switch self {
        case .macOS: "Double-clickable Apple Silicon app"
        case .iOS: "IPA for iPhone"
        case .iPadOS: "IPA for iPad"
        }
    }

    var scriptPlatform: String {
        self == .macOS ? "mac-app" : "ios"
    }
}

@MainActor
final class BuildModel: ObservableObject {
    @Published var repositoryURL: URL?
    @Published var gameURL: URL?
    @Published var keysURL: URL?
    @Published var target: BuildTarget = .macOS
    @Published var log = "Ready. Select a game folder and prod.keys.\n"
    @Published var status = "Ready"
    @Published var isBuilding = false
    @Published var lastExitCode: Int32?

    private var process: Process?

    init() {
        repositoryURL = Self.findRepositoryRoot()
    }

    var canBuild: Bool {
        !isBuilding &&
            repositoryURL.map(Self.isRepositoryRoot) == true &&
            gameURL.map { $0.hasDirectoryPath } == true &&
            keysURL.map { !$0.hasDirectoryPath } == true
    }

    func chooseRepository() {
        guard let url = chooseURL(
            title: "Choose nxnative repository",
            message: "Choose the folder containing scripts/build_ipa_from_nsp.py.",
            directories: true,
            files: false
        ) else { return }

        guard Self.isRepositoryRoot(url) else {
            status = "Invalid repository"
            appendLog("The selected folder does not contain scripts/build_ipa_from_nsp.py.\n")
            return
        }
        repositoryURL = url
        status = "Repository selected"
    }

    func chooseGameFolder() {
        guard let url = chooseURL(
            title: "Choose game folder",
            message: "Choose a folder containing the base NSP/XCI and optional updates or DLC.",
            directories: true,
            files: false
        ) else { return }

        gameURL = url
        status = "Game folder selected"
    }

    func chooseKeys() {
        let panel = NSOpenPanel()
        panel.title = "Choose prod.keys"
        panel.message = "The key is used in place and is not copied into nxnative."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        keysURL = url
        status = "Keys selected"
    }

    func startBuild() {
        guard canBuild, let repositoryURL, let gameURL, let keysURL else {
            status = "Select a valid repository, game folder, and prod.keys first"
            return
        }

        let script = repositoryURL.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        let arguments = [
            script.path,
            gameURL.path,
            "--keys", keysURL.path,
            "--platform", target.scriptPlatform,
            "--progress", "lines"
        ]
        let displayCommand = (["python3"] + arguments).map(Self.shellQuote).joined(separator: " ")

        isBuilding = true
        lastExitCode = nil
        status = "Building for \(target.title)"
        log = "Command:\n\(displayCommand)\n\n"

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = Self.findPython()
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        // Keep the system administration tools available to the Python pipeline.
        // macOS ships sysctl in /usr/sbin, while GUI apps do not inherit a shell PATH.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        self.process = process

        let model = self
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                let outputHandle = outputPipe.fileHandleForReading
                while true {
                    let data = try outputHandle.read(upToCount: 4096) ?? Data()
                    if data.isEmpty { break }
                    let output = String(data: data, encoding: .utf8) ?? "(non-UTF-8 build output)"
                    Task { @MainActor in
                        model.appendLog(output)
                    }
                }
                process.waitUntilExit()
                Task { @MainActor in
                    model.finishBuild(exitCode: process.terminationStatus)
                }
            } catch {
                Task { @MainActor in
                    model.finishBuild(exitCode: -1, output: "Failed to start build: \(error.localizedDescription)\n")
                }
            }
        }
    }

    func cancelBuild() {
        guard let process, process.isRunning else { return }
        process.terminate()
        status = "Cancelling build..."
    }

    func revealGameFolder() {
        guard let gameURL else { return }
        NSWorkspace.shared.open(gameURL)
    }

    func revealRepository() {
        guard let repositoryURL else { return }
        NSWorkspace.shared.open(repositoryURL)
    }

    private func finishBuild(exitCode: Int32, output: String? = nil) {
        if let output {
            appendLog(output)
        }
        lastExitCode = exitCode
        isBuilding = false
        process = nil
        status = exitCode == 0 ? "Build complete" : "Build failed (exit \(exitCode))"
    }

    private func appendLog(_ text: String) {
        log.append(text)
    }

    private func chooseURL(
        title: String,
        message: String,
        directories: Bool,
        files: Bool
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseDirectories = directories
        panel.canChooseFiles = files
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func isRepositoryRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent("scripts/build_ipa_from_nsp.py").path
        )
    }

    private static func findRepositoryRoot() -> URL? {
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["NXNATIVE_ROOT"] {
            candidates.append(URL(fileURLWithPath: configured))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        candidates.append(Bundle.main.bundleURL)

        for candidate in candidates {
            var current = candidate
            for _ in 0..<8 {
                if isRepositoryRoot(current) { return current }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        return nil
    }

    private static func findPython() -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["NXNATIVE_PYTHON"],
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ].compactMap { $0 }

        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? URL(fileURLWithPath: "/usr/bin/python3")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct ContentView: View {
    @ObservedObject var model: BuildModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            inputSection
            targetSection
            actionBar
            logSection
        }
        .padding(24)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("nxnative")
                .font(.system(size: 30, weight: .bold))
            Text("Build your legally obtained Switch game files for Apple platforms.")
                .foregroundStyle(.secondary)
        }
    }

    private var inputSection: some View {
        GroupBox("Inputs") {
            VStack(spacing: 12) {
                PickerRow(
                    title: "nxnative repository",
                    value: model.repositoryURL?.path ?? "Not found",
                    buttonTitle: "Choose...",
                    action: model.chooseRepository
                )
                PickerRow(
                    title: "Game folder",
                    value: model.gameURL?.path ?? "Select a folder containing NSP/XCI files",
                    buttonTitle: "Select...",
                    action: model.chooseGameFolder
                )
                PickerRow(
                    title: "prod.keys",
                    value: model.keysURL?.path ?? "Not selected",
                    buttonTitle: "Select...",
                    action: model.chooseKeys
                )
            }
            .padding(4)
        }
    }

    private var targetSection: some View {
        GroupBox("Build target") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Target", selection: $model.target) {
                    ForEach(BuildTarget.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.target.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.target != .macOS {
                    Label(
                        "The same iOS IPA can be installed on the selected device family.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    private var actionBar: some View {
        HStack {
            Text(model.status)
                .font(.callout)
                .foregroundStyle(model.lastExitCode == 0 ? .green : .secondary)

            Spacer()

            if model.isBuilding {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel") {
                    model.cancelBuild()
                }
            } else {
                Button("Open Game Folder") {
                    model.revealGameFolder()
                }
                .disabled(model.gameURL == nil)

                Button("Build") {
                    model.startBuild()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .disabled(!model.canBuild)
            }
        }
    }

    private var logSection: some View {
        GroupBox("Build log") {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("log-end")
                }
                .frame(minHeight: 220)
                .onChange(of: model.log) { _, _ in
                    proxy.scrollTo("log-end", anchor: .bottom)
                }
            }
        }
    }
}

struct PickerRow: View {
    let title: String
    let value: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .frame(width: 145, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(buttonTitle, action: action)
        }
    }
}
