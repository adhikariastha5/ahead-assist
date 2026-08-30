import AVFoundation
import Combine

/// Core Video buffers are safe to retain across this app's single inference queue.
private final class SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

private struct GuidanceTrack {
    let id = UUID()
    let label: String
    var object: DetectedObject
    var previousBox: CGRect
    var initialArea: CGFloat
    var seenFrames = 1
    var missedFrames = 0
    var enteredCorridor = false

    init(object: DetectedObject) {
        label = object.label.lowercased()
        self.object = object
        previousBox = object.boundingBox
        initialArea = object.boundingBox.width * object.boundingBox.height
    }

    mutating func update(with object: DetectedObject) {
        let wasInCorridor = WalkingCorridor.contains(CGPoint(x: previousBox.midX, y: previousBox.minY))
        previousBox = self.object.boundingBox
        self.object = object
        enteredCorridor = !wasInCorridor && object.guidanceLocation == .path
        seenFrames += 1
        missedFrames = 0
    }

    var isApproaching: Bool {
        let currentArea = object.boundingBox.width * object.boundingBox.height
        let previousArea = previousBox.width * previousBox.height
        return seenFrames >= 3 && (currentArea > previousArea * 1.05 || currentArea > initialArea * 1.18)
    }

    var isApproachingQuickly: Bool {
        let currentArea = object.boundingBox.width * object.boundingBox.height
        let previousArea = previousBox.width * previousBox.height
        return seenFrames >= 3 && currentArea > previousArea * 1.12
    }

    var isMovingTowardCorridor: Bool {
        let previousDistance = abs(previousBox.midX - 0.5)
        let currentDistance = abs(object.boundingBox.midX - 0.5)
        return seenFrames >= 3 && (enteredCorridor || currentDistance < previousDistance - 0.012)
    }
}

private struct TrackedDetection {
    let id: UUID
    let object: DetectedObject
    let seenFrames: Int
    let isApproaching: Bool
    let isApproachingQuickly: Bool
    let isMovingTowardCorridor: Bool
}

private struct ObjectTracker {
    private var tracks: [GuidanceTrack] = []

    mutating func update(with detections: [DetectedObject]) -> [TrackedDetection] {
        for index in tracks.indices { tracks[index].missedFrames += 1 }
        var usedTrackIndices = Set<Int>()

        for detection in detections {
            let candidates = tracks.indices.filter { index in
                !usedTrackIndices.contains(index) &&
                tracks[index].label == detection.label.lowercased() &&
                tracks[index].missedFrames <= 2
            }
            let bestMatch = candidates.max { left, right in
                matchScore(tracks[left].object.boundingBox, detection.boundingBox) <
                matchScore(tracks[right].object.boundingBox, detection.boundingBox)
            }

            if let bestMatch, matchScore(tracks[bestMatch].object.boundingBox, detection.boundingBox) > 0.12 {
                tracks[bestMatch].update(with: detection)
                usedTrackIndices.insert(bestMatch)
            } else {
                tracks.append(GuidanceTrack(object: detection))
                usedTrackIndices.insert(tracks.count - 1)
            }
        }

        tracks.removeAll { $0.missedFrames > 5 }
        return tracks.filter { $0.missedFrames == 0 }.map {
            TrackedDetection(
                id: $0.id,
                object: $0.object,
                seenFrames: $0.seenFrames,
                isApproaching: $0.isApproaching,
                isApproachingQuickly: $0.isApproachingQuickly,
                isMovingTowardCorridor: $0.isMovingTowardCorridor
            )
        }
    }

    mutating func reset() { tracks = [] }

    private func matchScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection.width * intersection.height
        let iou = union > 0 ? (intersection.width * intersection.height) / union : 0
        let distance = hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
        return iou + max(0, 0.25 - distance)
    }
}

@MainActor
final class VideoAnalysisViewModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var detections: [DetectedObject] = []
    @Published private(set) var events: [AlertEvent] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var isModelReady = false
    @Published private(set) var statusText = "Choose a video"
    @Published private(set) var lastSpokenMessage = ""
    @Published private(set) var videoAspectRatio: CGFloat = 9 / 16
    @Published private(set) var selectedVideoName = ""
    @Published private(set) var durationSeconds: Double = 0
    @Published var playbackProgress: Double = 0
    @Published var isSpeechEnabled = true
    @Published var confidenceThreshold: Float = 0.55

    private let speech = SpeechCoordinator()
    private let processingQueue = DispatchQueue(label: "aiwalker.detection", qos: .userInitiated)
    private var detector: ObjectDetector?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var timer: Timer?
    private var isProcessing = false
    private var tracker = ObjectTracker()
    private var lastAlertTimes: [UUID: Date] = [:]
    private var lastGuidanceTime = Date.distantPast
    private var resumeAfterScrubbing = false

    init() {
        do {
            detector = try ObjectDetector()
            isModelReady = true
            statusText = "Model ready"
        } catch {
            statusText = error.localizedDescription
        }
    }

    func loadVideo(from sourceURL: URL) {
        pause()
        do {
            let localURL = try copyToTemporaryFolder(from: sourceURL)
            selectedVideoName = sourceURL.lastPathComponent
            statusText = "Preparing video"
            resetAlerts()

            Task { @MainActor [weak self] in
                let asset = AVURLAsset(url: localURL)
                do {
                    guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
                        self?.statusText = "No video track found"
                        return
                    }
                    let naturalSize = try await sourceTrack.load(.naturalSize)
                    let transform = try await sourceTrack.load(.preferredTransform)
                    let duration = try await asset.load(.duration)

                    // Build a video-only composition. This removes the source audio track
                    // before AVPlayer is created, avoiding its audio graph entirely.
                    let silentVideo = AVMutableComposition()
                    guard let silentTrack = silentVideo.addMutableTrack(
                        withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        self?.statusText = "Could not prepare video"
                        return
                    }
                    try silentTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: duration),
                        of: sourceTrack,
                        at: .zero
                    )
                    silentTrack.preferredTransform = transform

                    let item = AVPlayerItem(asset: silentVideo)
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ])
                    item.add(output)
                    self?.player = AVPlayer(playerItem: item)
                    self?.videoOutput = output
                    self?.videoAspectRatio = abs(naturalSize.applying(transform).width / naturalSize.applying(transform).height)
                    self?.durationSeconds = duration.seconds.isFinite ? duration.seconds : 0
                    self?.playbackProgress = 0
                    self?.statusText = self?.isModelReady == true ? "Ready to simulate" : self?.statusText ?? "Model unavailable"
                } catch {
                    self?.statusText = "Could not open video: \(error.localizedDescription)"
                }
            }
        } catch {
            statusText = "Could not open video: \(error.localizedDescription)"
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func startPrediction() {
        reset()
        play()
    }

    func reset() {
        pause()
        player?.seek(to: .zero)
        playbackProgress = 0
        detections = []
        resetAlerts()
        statusText = isModelReady ? "Ready to simulate" : statusText
    }

    func setScrubbing(_ isScrubbing: Bool) {
        if isScrubbing {
            resumeAfterScrubbing = isPlaying
            pause()
            return
        }

        seek(toProgress: playbackProgress, resumePlayback: resumeAfterScrubbing)
        resumeAfterScrubbing = false
    }

    func skip(by seconds: Double) {
        guard durationSeconds > 0 else { return }
        let currentSeconds = playbackProgress * durationSeconds
        let progress = min(max((currentSeconds + seconds) / durationSeconds, 0), 1)
        seek(toProgress: progress, resumePlayback: isPlaying)
    }

    func formattedTime(for progress: Double) -> String {
        let seconds = max(0, Int((progress * durationSeconds).rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func seek(toProgress progress: Double, resumePlayback: Bool) {
        guard let player, durationSeconds > 0 else { return }
        pause()
        playbackProgress = min(max(progress, 0), 1)
        resetAlerts()
        let target = CMTime(seconds: playbackProgress * durationSeconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if resumePlayback { self.play() }
                else { self.statusText = "Paused" }
            }
        }
    }

    private func play() {
        guard player != nil, isModelReady else { return }
        player?.play()
        isPlaying = true
        statusText = "Analysing video"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.analyseCurrentFrame()
            }
        }
        timer?.tolerance = 0.05
    }

    private func pause() {
        player?.pause()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        speech.stop()
    }

    private func analyseCurrentFrame() {
        guard !isProcessing,
              let player,
              let videoOutput,
              let detector else { return }
        if durationSeconds > 0 {
            playbackProgress = min(max(player.currentTime().seconds / durationSeconds, 0), 1)
        }
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            if let duration = player.currentItem?.duration.seconds,
               duration.isFinite,
               player.currentTime().seconds >= duration {
                pause()
                statusText = "Simulation complete"
            }
            return
        }
        isProcessing = true
        let threshold = confidenceThreshold
        let pixelBufferBox = SendablePixelBuffer(pixelBuffer)
        processingQueue.async { [weak self] in
            let found = (try? detector.detect(in: pixelBufferBox.value, minimumConfidence: threshold)) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessing = false
                self.detections = Array(found.prefix(8))
                self.considerAlerts(from: self.tracker.update(with: found), at: player.currentTime().seconds)
            }
        }
    }

    private func considerAlerts(from tracks: [TrackedDetection], at seconds: Double) {
        let candidates = tracks.compactMap { track -> (TrackedDetection, String)? in
            guard track.seenFrames >= 3 else { return nil }
            let label = track.object.label.lowercased()
            let location = track.object.guidanceLocation
            let moving = track.isApproaching || track.isMovingTowardCorridor

            switch (label, location) {
            case ("person", .path) where moving:
                return (track, approachingMessage(for: track))
            case ("person", .leftSide) where track.isMovingTowardCorridor:
                return (track, "Person moving into your path from the left.")
            case ("person", .rightSide) where track.isMovingTowardCorridor:
                return (track, "Person moving into your path from the right.")
            case ("person", .leftSide) where track.isApproaching:
                return (track, track.isApproachingQuickly ? "Person approaching quickly on your left." : "Person approaching on your left.")
            case ("person", .rightSide) where track.isApproaching:
                return (track, track.isApproachingQuickly ? "Person approaching quickly on your right." : "Person approaching on your right.")
            case (_, .path) where ["bicycle", "motorcycle", "car", "bus", "truck"].contains(label) && moving:
                return (track, "Vehicle entering your path.")
            default:
                return nil
            }
        }

        guard let chosen = candidates.sorted(by: priority).first,
              Date().timeIntervalSince(lastAlertTimes[chosen.0.id] ?? .distantPast) >= 3,
              Date().timeIntervalSince(lastGuidanceTime) >= 3 else { return }

        let message = chosen.1
        lastGuidanceTime = Date()
        lastAlertTimes[chosen.0.id] = Date()
        lastSpokenMessage = message
        let timestamp = String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
        events.insert(AlertEvent(timestamp: timestamp, message: message), at: 0)
        if events.count > 8 { events.removeLast() }
        if isSpeechEnabled { speech.speak(message) }
    }

    func speakGuidanceTest() {
        guard isSpeechEnabled else { return }
        speech.speak("Guidance audio is on.")
    }

    private func approachingMessage(for track: TrackedDetection) -> String {
        let speed = track.isApproachingQuickly ? "quickly " : ""
        switch track.object.relativePosition {
        case .left:
            return "Person approaching \(speed)in your path on your left."
        case .right:
            return "Person approaching \(speed)in your path on your right."
        case .ahead:
            return "Person approaching \(speed)in your path ahead."
        }
    }

    private func priority(_ lhs: (TrackedDetection, String), _ rhs: (TrackedDetection, String)) -> Bool {
        let leftRank = lhs.0.object.guidanceLocation == .path ? 0 : 1
        let rightRank = rhs.0.object.guidanceLocation == .path ? 0 : 1
        return leftRank == rightRank ? lhs.0.object.confidence > rhs.0.object.confidence : leftRank < rightRank
    }

    private func resetAlerts() {
        detections = []
        events = []
        lastSpokenMessage = ""
        tracker.reset()
        lastAlertTimes = [:]
        lastGuidanceTime = .distantPast
    }

    private func copyToTemporaryFolder(from sourceURL: URL) throws -> URL {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }
}
