import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = FlashModel()
    @State private var isPickingISO = false
    @State private var isConfirming = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("ISO File") {
                    HStack {
                        Text(model.isoURL?.path ?? "No file selected")
                            .foregroundStyle(model.isoURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { isPickingISO = true }
                    }
                }

                Section("USB Drive") {
                    HStack {
                        Picker("Disk", selection: $model.selectedDiskID) {
                            if model.disks.isEmpty {
                                Text("No external disks found").tag(Disk.ID?.none)
                            }
                            ForEach(model.disks) { disk in
                                Text(disk.label).tag(Disk.ID?.some(disk.id))
                            }
                        }
                        .labelsHidden()
                        .disabled(model.disks.isEmpty)

                        Button {
                            Task { await model.refreshDisks() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh the list of disks")
                    }
                }

                statusSection
            }
            .formStyle(.grouped)
            .disabled(model.isFlashing)

            Divider()

            HStack {
                Spacer()
                Button("Flash") { isConfirming = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canFlash)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 360)
        .task { await model.refreshDisks() }
        .fileImporter(isPresented: $isPickingISO, allowedContentTypes: Self.imageTypes) { result in
            if case .success(let url) = result {
                model.isoURL = url
            }
        }
        .confirmationDialog(
            "Erase \(model.selectedDisk?.name ?? "this disk")?",
            isPresented: $isConfirming,
            presenting: model.selectedDisk
        ) { _ in
            Button("Erase and Flash", role: .destructive) {
                Task { await model.flash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { disk in
            Text("You are about to completely erase \(disk.devicePath) (\(disk.name), \(disk.formattedSize)). All data on this drive will be permanently lost.")
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
                    Text("Flashing… this may take a few minutes")
                } currentValueLabel: {
                    Text("\(ByteCountFormatter.string(fromByteCount: model.bytesWritten, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: model.isoSize, countStyle: .file))")
                }
            }
        case .succeeded(let message):
            Section {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private static let imageTypes: [UTType] = [
        UTType(filenameExtension: "iso") ?? .diskImage,
        UTType(filenameExtension: "img") ?? .diskImage,
    ]
}

#Preview {
    ContentView()
}
