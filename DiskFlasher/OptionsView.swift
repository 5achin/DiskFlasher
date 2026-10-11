import SwiftUI

/// The rows inside the Advanced Options disclosure: the dd operands a flash commonly needs.
struct OptionsView: View {
    @Binding var options: FlashOptions

    var body: some View {
        Picker(selection: $options.blockSize) {
            ForEach(FlashOptions.BlockSize.allCases) { size in
                Text(size.label).tag(size)
            }
        } label: {
            row("Block Size", "bs", "How much dd reads and writes at a time.", symbol: "square.grid.3x3")
        }

        Toggle(isOn: $options.useRawDevice) {
            row("Write to Raw Device", "rdisk", "Unbuffered and much faster. Turn off to use the buffered device.", symbol: "bolt.horizontal")
        }

        Toggle(isOn: $options.padBlocks) {
            row("Pad Blocks", "conv=sync", "Fill a short final block with zeros.", symbol: "rectangle.righthalf.inset.filled")
        }

        Toggle(isOn: $options.continueOnReadErrors) {
            row("Continue on Read Errors", "conv=noerror", "Keep going if part of the image can’t be read.", symbol: "exclamationmark.arrow.triangle.2.circlepath")
        }

        Toggle(isOn: $options.flushBeforeFinishing) {
            row("Flush Before Finishing", "conv=fsync", "Make sure everything is on the drive before dd exits.", symbol: "checkmark.seal")
        }

        Toggle(isOn: $options.synchronousWrites) {
            row("Synchronous Writes", "oflag=sync", "Wait for each block to reach the drive. Slower.", symbol: "arrow.triangle.2.circlepath")
        }

        Toggle(isOn: $options.bypassCache) {
            row("Bypass Cache", "oflag=direct", "Write without using the system’s disk cache.", symbol: "memorychip")
        }

        blocksField($options.count, prompt: "All") {
            row("Count", "count", "Copy only this many blocks.", symbol: "number")
        }

        blocksField($options.skip, prompt: "0") {
            row("Skip Input Blocks", "skip", "Start this many blocks into the image.", symbol: "arrow.right.to.line")
        }

        blocksField($options.seek, prompt: "0") {
            row("Seek Output Blocks", "seek", "Start writing this many blocks into the drive.", symbol: "arrow.down.to.line")
        }

        LabeledContent {
            HStack(spacing: 4) {
                numberField($options.speedLimit, prompt: "None")
                Text("MB/s").foregroundStyle(.secondary)
            }
        } label: {
            row("Speed Limit", "speed", "Cap how fast dd writes.", symbol: "gauge.with.dots.needle.33percent")
        }

        Toggle(isOn: $options.ejectWhenDone) {
            row("Eject When Done", nil, "Eject the drive after a successful flash.", symbol: "eject")
        }

        LabeledContent {
            Button("Restore Defaults") { options = FlashOptions() }
                .disabled(options == FlashOptions())
        } label: {
            EmptyView()
        }
    }

    private func row(_ title: String, _ operand: String?, _ detail: String, symbol: String) -> some View {
        Label {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                if let operand {
                    Text(operand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(detail)
        } icon: {
            Image(systemName: symbol).frame(width: 24)
        }
    }

    private func blocksField(_ value: Binding<Int?>, prompt: String, @ViewBuilder label: () -> some View) -> some View {
        LabeledContent {
            numberField(value, prompt: prompt)
        } label: {
            label()
        }
    }

    private func numberField(_ value: Binding<Int?>, prompt: String) -> some View {
        TextField("", value: value, format: .number.grouping(.never), prompt: Text(prompt))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
    }
}
