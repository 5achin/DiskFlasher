import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = FlashModel()
    @State private var isPickingISO = false
    @State private var isConfirming = false
    @State private var isConfirmingCancel = false
    @State private var isDropTargeted = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Choose…") { isPickingISO = true }
                } label: {
                    Label {
                        if let url = model.isoURL {
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(isoDetail(for: url))
                        } else {
                            Text("Disk Image")
                            Text("Choose an ISO file, or drag one here.")
                        }
                    } icon: {
                        Image(systemName: "opticaldisc")
                    }
                }

                Picker(selection: $model.selectedDiskID) {
                    if model.disks.isEmpty {
                        Text("None").tag(Disk.ID?.none)
                    }
                    ForEach(model.disks) { disk in
                        Text("\(disk.name) (\(disk.formattedSize))").tag(Disk.ID?.some(disk.id))
                    }
                } label: {
                    Label {
                        Text("USB Drive")
                        Text(diskDetail)
                    } icon: {
                        Image(systemName: "mediastick")
                    }
                }
                .disabled(model.disks.isEmpty)
            } footer: {
                Text("Only external drives are listed. Flashing erases everything on the selected drive.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.isFlashing)

            statusSection
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 500)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(6)
            }
        }
        .navigationTitle("Disk Flasher")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isFlashing {
                    Button(role: .cancel) {
                        isConfirmingCancel = true
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.isCancelling)
                    .help("Stop flashing")
                } else {
                    Button {
                        isConfirming = true
                    } label: {
                        Label("Flash", systemImage: "bolt.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canFlash)
                    .help("Write the disk image to the selected USB drive")
                }
            }
        }
        .task {
            // Keep the drive list current as drives are plugged in and removed.
            while !Task.isCancelled {
                if !model.isFlashing {
                    await model.refreshDisks()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .fileImporter(isPresented: $isPickingISO, allowedContentTypes: Self.imageTypes) { result in
            if case .success(let url) = result {
                model.isoURL = url
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isFlashing,
                  let url = urls.first(where: { Self.imageExtensions.contains($0.pathExtension.lowercased()) }) else {
                return false
            }
            model.isoURL = url
            return true
        } isTargeted: { isDropTargeted = $0 && !model.isFlashing }
        .confirmationDialog(
            "Erase “\(model.selectedDisk?.name ?? "this disk")” and flash it?",
            isPresented: $isConfirming,
            presenting: model.selectedDisk
        ) { _ in
            Button("Erase and Flash", role: .destructive) {
                Task { await model.flash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { disk in
            Text("All data on \(disk.name) (\(disk.formattedSize), \(disk.devicePath)) will be permanently lost. You can’t undo this action.")
        }
        .confirmationDialog("Stop flashing?", isPresented: $isConfirmingCancel) {
            Button("Stop Flashing", role: .destructive) { model.cancel() }
            Button("Keep Flashing", role: .cancel) {}
        } message: {
            Text("The USB drive will be left partially written and will be unusable until you flash it again or erase it in Disk Utility.")
        }
        .onChange(of: model.isFlashing) {
            if !model.isFlashing { isConfirmingCancel = false }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .flashing:
            Section {
                ProgressView(value: model.progress) {
                    Text(model.isCancelling ? "Cancelling…" : "Flashing…")
                } currentValueLabel: {
                    Text("\(Self.format(model.bytesWritten)) of \(Self.format(model.isoSize))")
                        .monospacedDigit()
                }
            }
        case .succeeded(let message):
            statusRow("Flash Complete", message, symbol: "checkmark.circle.fill", color: .green)
        case .cancelled(let message):
            statusRow("Flash Cancelled", message, symbol: "xmark.octagon.fill", color: .orange)
        case .failed(let message):
            statusRow("Flash Failed", message, symbol: "exclamationmark.triangle.fill", color: .red)
        }
    }

    private func statusRow(_ title: String, _ message: String, symbol: String, color: Color) -> some View {
        Section {
            Label {
                Text(title)
                Text(message)
            } icon: {
                Image(systemName: symbol)
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(color)
            }
        }
    }

    private var diskDetail: String {
        if let disk = model.selectedDisk {
            "\(disk.busProtocol), \(disk.devicePath)"
        } else {
            "Connect a USB drive to get started."
        }
    }

    private func isoDetail(for url: URL) -> String {
        let folder = url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return folder }
        return "\(Self.format(Int64(size))), in \(folder)"
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let imageExtensions = ["iso", "img"]
    private static let imageTypes: [UTType] = imageExtensions.map { UTType(filenameExtension: $0) ?? .diskImage }
}

#Preview {
    ContentView()
}
