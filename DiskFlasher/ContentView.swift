import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "externaldrive.badge.plus")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Disk Flasher")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
