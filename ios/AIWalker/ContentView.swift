import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ContentView: View {
    enum AppMode: String, CaseIterable, Identifiable { case safety = "Safety scan", navigate = "Navigate CBD"; var id: String { rawValue } }
    @StateObject private var viewModel = VideoAnalysisViewModel()
    @StateObject private var navigation = MelbourneNavigationViewModel()
    @State private var isShowingImporter = false
    @State private var isPredicting = false
    @State private var mode: AppMode = .safety

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ZStack {
                    AppBackground()
                    VStack(spacing: viewport.size.width > 700 ? 20 : 14) {
                        header
                        GlassModeSwitcher(selection: $mode)
                        if mode == .navigate { CBDNavigationView(viewModel: navigation) { mode = .safety } }
                        else if viewModel.player == nil { chooseVideo }
                        else if isPredicting { results(in: viewport.size) }
                        else { predictReady }
                    }
                    .padding(viewport.size.width > 700 ? 28 : 16)
                    .frame(maxWidth: 1_100, maxHeight: .infinity, alignment: .top)
                }
            }
            .fileImporter(isPresented: $isShowingImporter, allowedContentTypes: [.movie]) { result in
                guard case let .success(url) = result else { return }
                isPredicting = false
                viewModel.loadVideo(from: url)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.roll")
                .font(.title2.weight(.bold)).foregroundStyle(.black)
                .frame(width: 46, height: 46).background(.blue, in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Walker").font(.title2.weight(.bold))
                Text(isPredicting ? "Path-aware guidance" : "Video safety simulator")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
            Button { isShowingImporter = true } label: {
                Image(systemName: "plus").font(.headline.bold()).frame(width: 42, height: 42)
                    .background(.white.opacity(0.1), in: Circle())
            }
        }
        .padding(14)
        .background(CardBackground(cornerRadius: 26))
    }

    private var chooseVideo: some View {
        VStack(spacing: 22) {
            Image(systemName: "video.badge.plus").font(.system(size: 44)).foregroundStyle(.blue)
            Text("Upload video").font(.title2.bold())
            Button { isShowingImporter = true } label: {
                Label("Select video", systemImage: "folder").frame(maxWidth: .infinity)
            }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(28).background(CardBackground())
    }

    private var predictReady: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Video ready").font(.headline)
                    Text(viewModel.selectedVideoName).font(.subheadline).lineLimit(1).foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
            }.padding(16).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 8) {
                Label("Ready to analyse", systemImage: "sparkles").font(.headline).foregroundStyle(.blue)
                Text("An annotated guidance video, walking corridor, spoken alerts, and a timeline of relevant movement.")
                    .foregroundStyle(.white.opacity(0.7))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                isPredicting = true
                viewModel.startPrediction()
            } label: {
                Label("Predict surroundings", systemImage: "waveform.path.ecg").frame(maxWidth: .infinity)
            }.buttonStyle(PrimaryButtonStyle()).disabled(!viewModel.isModelReady)
        }
        .padding(20).background(CardBackground())
    }

    private func results(in viewport: CGSize) -> some View {
        let videoHeight = videoHeight(for: viewport)

        return VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Guidance view").font(.title3.bold())
                    Text(viewModel.isPlaying ? "Analysing your surroundings" : viewModel.statusText)
                        .font(.subheadline).foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                Label(viewModel.isPlaying ? "Live" : "Paused", systemImage: "circle.fill")
                    .font(.caption.bold()).foregroundStyle(viewModel.isPlaying ? .blue : .orange)
            }
            if let player = viewModel.player {
                GuidanceVideo(player: player, detections: viewModel.detections, status: viewModel.statusText,
                              spoken: viewModel.lastSpokenMessage, aspectRatio: viewModel.videoAspectRatio)
                    .aspectRatio(viewModel.videoAspectRatio, contentMode: .fit)
                    .frame(height: videoHeight)
            }
            HStack(spacing: 10) {
                Text(viewModel.formattedTime(for: viewModel.playbackProgress))
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                Slider(value: $viewModel.playbackProgress, in: 0...1, onEditingChanged: viewModel.setScrubbing)
                    .tint(.blue)
                    .disabled(viewModel.durationSeconds <= 0)
                Text(viewModel.formattedTime(for: 1))
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.65))
            }
            HStack(spacing: 12) {
                Button { viewModel.skip(by: -5) } label: {
                    Label("Back 5s", systemImage: "gobackward.5").frame(maxWidth: .infinity)
                }.buttonStyle(SecondaryButtonStyle())
                Button { viewModel.togglePlayback() } label: {
                    Label(viewModel.isPlaying ? "Pause" : "Resume", systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill").frame(maxWidth: .infinity)
                }.buttonStyle(SecondaryButtonStyle())
                Button { viewModel.skip(by: 5) } label: {
                    Label("Forward 5s", systemImage: "goforward.5").frame(maxWidth: .infinity)
                }.buttonStyle(SecondaryButtonStyle())
                Button { isPredicting = false; viewModel.reset() } label: {
                    Label("New prediction", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                }.buttonStyle(SecondaryButtonStyle())
            }
            guidanceMessage
            timeline
            settings
        }
    }

    private func videoHeight(for viewport: CGSize) -> CGFloat {
        switch viewport.sizeClass {
        case .large: return min(500, viewport.height * 0.56)
        case .medium: return min(390, viewport.height * 0.46)
        case .compact: return min(260, viewport.height * 0.34)
        }
    }

    private var guidanceMessage: some View {
        HStack(spacing: 12) {
            Image(systemName: "ear.and.waveform").foregroundStyle(.blue).font(.title3)
            Text(viewModel.lastSpokenMessage.isEmpty ? "Watching for movement in your path" : viewModel.lastSpokenMessage)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
        }.padding(15).background(.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Guidance timeline", systemImage: "clock.arrow.circlepath").font(.headline)
            if viewModel.events.isEmpty {
                Text("Relevant movement will appear here.").foregroundStyle(.white.opacity(0.52))
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.events) { event in
                            HStack(alignment: .top) {
                                Text(event.timestamp).font(.caption.monospacedDigit().bold()).foregroundStyle(.blue)
                                Text(event.message).font(.subheadline)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 128, maxHeight: 128, alignment: .leading)
        .padding(18)
        .background(CardBackground())
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("Speak guidance", isOn: $viewModel.isSpeechEnabled).font(.headline)
                Spacer()
                Button("Test voice") { viewModel.speakGuidanceTest() }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isSpeechEnabled)
            }
            HStack { Text("Detection sensitivity"); Spacer(); Text("\(Int(viewModel.confidenceThreshold * 100))%").foregroundStyle(.blue) }
            Slider(value: $viewModel.confidenceThreshold, in: 0.2...0.9, step: 0.05).tint(.blue)
        }.padding(18).background(CardBackground())
    }
}

private struct CBDNavigationView: View {
    @ObservedObject var viewModel: MelbourneNavigationViewModel
    let openSafetyScan: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "map.fill").font(.title3.bold()).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(.blue, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Melbourne CBD guidance").font(.title3.bold())
                        Text("Route simulation").font(.caption).foregroundStyle(.white.opacity(0.58))
                    }
                }
                Text("Demo routes begin at Flinders Street Station. Check live conditions and ask staff before travelling.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.62))
                VStack(alignment: .leading, spacing: 8) {
                    Label("Destination command", systemImage: "waveform").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                    TextField("e.g. Take me to State Library Victoria", text: $viewModel.command)
                        .textFieldStyle(.plain)
                        .padding(14)
                        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                        .onSubmit(viewModel.submitCommand)
                }.padding(16).background(CardBackground())
                Button("Use destination command", action: viewModel.submitCommand).buttonStyle(PrimaryButtonStyle())
                if viewModel.destination != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose elevation preference").font(.headline)
                        HStack {
                            ForEach(MobilityChoice.allCases) { choice in
                                Button { viewModel.choose(choice) } label: {
                                    Label(choice.rawValue, systemImage: choice.icon).frame(maxWidth: .infinity)
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(viewModel.mobilityChoice == choice ? .blue : .clear, lineWidth: 2))
                            }
                        }
                    }.padding(16).background(CardBackground())
                }
                Label(viewModel.prompt, systemImage: "ear.and.waveform")
                    .font(.subheadline.weight(.medium)).padding(16)
                    .background(.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
                if viewModel.isNavigating, !viewModel.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Current guidance").font(.headline)
                        Text(viewModel.steps[viewModel.stepIndex]).font(.title3.weight(.semibold))
                        HStack {
                            Button("Stop", action: viewModel.stop).buttonStyle(SecondaryButtonStyle())
                            Button(viewModel.stepIndex == viewModel.steps.count - 1 ? "Finish" : "Next instruction", action: viewModel.nextStep).buttonStyle(PrimaryButtonStyle())
                        }
                    }.padding(18).background(CardBackground())
                } else {
                    Button("Start guidance", action: viewModel.start)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(viewModel.destination == nil || viewModel.mobilityChoice == nil)
                }
                Button { openSafetyScan() } label: {
                    Label("Open safety video scan", systemImage: "video.badge.checkmark").frame(maxWidth: .infinity)
                }.buttonStyle(SecondaryButtonStyle())
            }.padding(.vertical, 4)
        }
    }
}

private struct GuidanceVideo: View {
    let player: AVPlayer; let detections: [DetectedObject]; let status: String; let spoken: String; let aspectRatio: CGFloat
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PlayerSurface(player: player)
                CorridorOverlay()
                ForEach(detections) { DetectionBox(detection: $0, size: proxy.size) }
            }
            .background(.black).clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
}

/// A video-only AVPlayerLayer. SwiftUI's VideoPlayer embeds an AVKit control
/// strip (including a volume slider) even though source audio is removed.
private struct PlayerSurface: View {
    let player: AVPlayer

    var body: some View {
#if os(macOS)
        MacPlayerLayer(player: player)
#else
        IOSPlayerLayer(player: player)
#endif
    }
}

#if os(macOS)
private struct MacPlayerLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer = playerLayer
        }

        required init?(coder: NSCoder) { nil }
    }
}
#else
private struct IOSPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            playerLayer.videoGravity = .resizeAspect
        }

        required init?(coder: NSCoder) { nil }
    }
}
#endif

private extension CGSize {
    enum ScreenSize { case compact, medium, large }

    var sizeClass: ScreenSize {
        if width >= 1_000 { return .large }
        if width >= 650 { return .medium }
        return .compact
    }
}

private struct CorridorOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let points = WalkingCorridor.normalizedPoints.map { CGPoint(x: $0.x * proxy.size.width, y: (1 - $0.y) * proxy.size.height) }
                guard let first = points.first else { return }; path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath()
            }.fill(.blue.opacity(0.12)).overlay {
                Path { path in
                    let points = WalkingCorridor.normalizedPoints.map { CGPoint(x: $0.x * proxy.size.width, y: (1 - $0.y) * proxy.size.height) }
                    guard let first = points.first else { return }; path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath()
                }.stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
        }.allowsHitTesting(false)
    }
}

private struct DetectionBox: View {
    let detection: DetectedObject; let size: CGSize
    var body: some View {
        let box = CGRect(x: detection.boundingBox.minX * size.width, y: (1 - detection.boundingBox.maxY) * size.height, width: detection.boundingBox.width * size.width, height: detection.boundingBox.height * size.height)
        RoundedRectangle(cornerRadius: 7).stroke(color, lineWidth: 3).frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY).allowsHitTesting(false)
    }
    private var color: Color { detection.guidanceLocation == .path ? .blue : (detection.guidanceLocation == .outside ? .gray : .orange) }
}

private struct AppBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.025, green: 0.04, blue: 0.075), Color(red: 0.045, green: 0.07, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .topTrailing) { Circle().fill(.blue.opacity(0.22)).frame(width: 420).blur(radius: 90).offset(x: 140, y: -170) }
            .overlay(alignment: .bottomLeading) { Circle().fill(.indigo.opacity(0.18)).frame(width: 360).blur(radius: 80).offset(x: -140, y: 170) }
            .ignoresSafeArea()
    }
}

private struct GlassModeSwitcher: View {
    @Binding var selection: ContentView.AppMode
    var body: some View {
        HStack(spacing: 5) {
            modeButton(.safety, icon: "viewfinder")
            modeButton(.navigate, icon: "map.fill")
        }
        .padding(5).background(.black.opacity(0.2), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.14)) }
    }
    private func modeButton(_ mode: ContentView.AppMode, icon: String) -> some View {
        Button { selection = mode } label: {
            Label(mode.rawValue, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(selection == mode ? .white : .white.opacity(0.58))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(selection == mode ? AnyShapeStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(.clear), in: Capsule())
        }.buttonStyle(.plain)
    }
}

private struct CardBackground: View {
    var cornerRadius: CGFloat = 24
    var body: some View { RoundedRectangle(cornerRadius: cornerRadius).fill(.ultraThinMaterial).overlay { RoundedRectangle(cornerRadius: cornerRadius).stroke(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)) } }
}
private struct PrimaryButtonStyle: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.font(.headline.bold()).foregroundStyle(.white).padding(.vertical, 16).padding(.horizontal, 14).background(LinearGradient(colors: [.blue.opacity(configuration.isPressed ? 0.72 : 1), .indigo], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 17)).shadow(color: .blue.opacity(configuration.isPressed ? 0 : 0.32), radius: 14, y: 6) } }
private struct SecondaryButtonStyle: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.font(.subheadline.bold()).foregroundStyle(.white.opacity(0.92)).padding(.vertical, 13).padding(.horizontal, 12).background(.white.opacity(configuration.isPressed ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: 15)).overlay { RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.12)) } } }

#Preview { ContentView() }
