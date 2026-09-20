import SwiftUI

/// Spike #22 screen. Buttons in the order the spike runs them; the log is the evidence.
struct RoutingSpikeView: View {
    @State private var probe = RoutingProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $probe.mode) {
                ForEach(RoutingProbe.Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Configure") { probe.configure() }
                Button("Record 10 s") { Task { await probe.record() } }
                Button("Play") { probe.play() }
                Button("Route now") { probe.logRoute("manual") }
                Button("Copy log") { probe.copyLog() }
            }
            .buttonStyle(.bordered)
            ScrollView {
                Text(probe.log.isEmpty ? "1 Configure, 2 Record (speak into the DJI transmitter), 3 Play" : probe.log)
                    .font(.footnote.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .navigationTitle("Routing spike (#22)")
        .onDisappear { probe.tearDown() }
    }
}

#Preview {
    NavigationStack { RoutingSpikeView() }
}
