import SwiftUI

@main
struct DiskFlasherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Disk Flasher", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .help) {
                Button("Show Logs in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([RunLog.fileURL])
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        RunLog.write("=== Disk Flasher \(version) (\(build)) launched from \(Bundle.main.bundlePath), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        RunLog.write("Quit")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
