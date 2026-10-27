import HailCore
import SwiftUI

/// Mounted above the adaptive station so rotation/expanded chat do not replay an announcement.
struct ReplySegmentNotices: ViewModifier {
    let playback: ReplyPlaybackController
    @Binding var banners: AnnouncementBanners
    @State private var notice = ReplySegmentNotice()

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            VStack(spacing: 8) {
                AnnouncementBannerView(banners: $banners)
                if notice.isVisible {
                    Button { notice.dismiss() } label: {
                        Label(ReplySegmentNotice.text, systemImage: "pause.circle")
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHint("Dismiss this notice.")
                    .accessibilityIdentifier("station.segment-paused")
                }
            }
            .padding(.horizontal)
        }
        .onChange(of: playback.lastSegmentYield) { _, yield in
            if notice.observe(yield, at: .now, voiceOverRunning: StationPlatform.voiceOverRunning) {
                StationPlatform.announce(ReplySegmentNotice.text)
            }
        }
        .task(id: notice.deadline) {
            guard let deadline = notice.deadline else { return }
            do { try await Task.sleep(for: ContinuousClock.now.duration(to: deadline)) } catch { return }
            notice.expire(at: .now)
        }
    }
}

struct ReplySegmentToolsView: View {
    let playback: ReplyPlaybackController
    let gate: ReplySegmentOnsetGate

    var body: some View {
        Form {
            Section("Turn-taking") {
                Stepper(value: setting(.pause), in: ReplySegmentSetting.pause.bounds, step: 0.1) {
                    VStack(alignment: .leading) {
                        Text("Pause between reply segments")
                        Text("\(playback.segmentSettings.pauseAfterSegment, specifier: "%.1f") seconds")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("station.segment-pause")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Voice needed to take the turn")
                    Slider(value: setting(.threshold), in: ReplySegmentSetting.threshold.bounds, step: 1) {
                        Text("Voice needed to take the turn")
                    } minimumValueLabel: { Text("Quieter") } maximumValueLabel: { Text("Louder") }
                    .accessibilityValue("\(Int(playback.segmentSettings.onsetThresholdDBFS)) dBFS")
                    .accessibilityIdentifier("station.segment-threshold")
                    Text("\(Int(playback.segmentSettings.onsetThresholdDBFS)) dBFS")
                        .foregroundStyle(.secondary)
                    Text("Any sustained sound can take the turn; this does not identify a speaker.")
                        .font(.caption)
                }
            }
            Section("Turn-taking diagnostics") {
                // The gate is lock-protected rather than observable; refresh counts while this screen is open.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    ReplySegmentDiagnosticsView(diagnostics: gate.diagnostics)
                }
            }
        }
        .navigationTitle("Turn-taking")
        .stationInlineTitle()
        .stationToolBackNavigation()
    }

    private func setting(_ field: ReplySegmentSetting) -> Binding<Double> {
        Binding(get: { field.value(in: playback.segmentSettings) }, set: { value in
            let settings = field.updating(playback.segmentSettings, to: value)
            playback.segmentSettings = settings
            settings.save()
        })
    }
}

private struct ReplySegmentDiagnosticsView: View {
    let diagnostics: ReplyOnsetDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            rows(ReplySegmentDiagnosticsPresentation.counters(diagnostics))
            Text("Counts onset signals, including signals refused by the current listening or privacy state.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Analysed levels").font(.headline)
            rows(ReplySegmentDiagnosticsPresentation.histogram(diagnostics.levels))
            Text("Calibrated floors").font(.headline)
            rows(ReplySegmentDiagnosticsPresentation.histogram(diagnostics.floors))
        }
        .accessibilityIdentifier("station.segment-diagnostics")
    }

    private func rows(_ rows: [ReplySegmentDiagnosticRow]) -> some View {
        ForEach(rows) { row in
            LabeledContent(row.id) { Text(row.count).monospacedDigit() }
        }
    }
}
