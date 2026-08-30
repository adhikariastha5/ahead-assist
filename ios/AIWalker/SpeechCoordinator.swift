import Foundation

#if !os(macOS)
import AVFAudio
#endif

@MainActor
final class SpeechCoordinator {
#if os(macOS)
    // The macOS simulator delegates voice output to the system speech service.
    // This avoids sharing AVPlayer's Core Audio graph while video is being analysed.
    private var speechProcess: Process?
#else
    private let synthesizer = AVSpeechSynthesizer()
#endif

    func speak(_ message: String) {
#if os(macOS)
        speechProcess?.terminate()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // The Mac's default voice can be unavailable or produce an empty buffer.
        // Karen is an installed Australian English voice verified on this machine.
        process.arguments = ["-v", "Karen", "-r", "185", message]
        do {
            try process.run()
            speechProcess = process
        } catch {
            print("Unable to play guidance speech: \(error.localizedDescription)")
        }
#else
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }
        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = 0.48
        utterance.voice = AVSpeechSynthesisVoice(language: "en-AU")
        synthesizer.speak(utterance)
#endif
    }

    func stop() {
#if os(macOS)
        speechProcess?.terminate()
        speechProcess = nil
#else
        synthesizer.stopSpeaking(at: .immediate)
#endif
    }
}
