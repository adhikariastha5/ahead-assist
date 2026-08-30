import SwiftUI
import Combine

enum MobilityChoice: String, CaseIterable, Identifiable {
    case lift = "Lift"
    case stairs = "Stairs"
    var id: String { rawValue }
    var icon: String { self == .lift ? "arrow.up.arrow.down" : "stairs" }
}

enum CBDDestination: String, CaseIterable, Identifiable {
    case federationSquare = "Federation Square"
    case melbourneCentral = "Melbourne Central"
    case stateLibrary = "State Library Victoria"
    case southernCross = "Southern Cross Station"

    var id: String { rawValue }
}

@MainActor
final class MelbourneNavigationViewModel: ObservableObject {
    @Published var command = ""
    @Published var destination: CBDDestination?
    @Published var mobilityChoice: MobilityChoice?
    @Published var isNavigating = false
    @Published var stepIndex = 0
    @Published var prompt = "Say or type where you would like to go."

    private let speech = SpeechCoordinator()

    var steps: [String] {
        guard let destination else { return [] }
        let access = mobilityChoice == .lift
        switch destination {
        case .federationSquare:
            return [
                "Start at Flinders Street Station main concourse.",
                access ? "Use the accessible lift to the Swanston Street exit." : "Use the stairs to the Swanston Street exit.",
                "At the pedestrian signals, cross Swanston Street when it is safe.",
                "Federation Square is ahead."
            ]
        case .melbourneCentral:
            return [
                "Start at Flinders Street Station on Swanston Street.",
                "Travel north along Swanston Street, keeping the building line on your right.",
                "Continue past Bourke Street Mall using signal-controlled crossings.",
                access ? "At Melbourne Central, look for lift access and ask staff if needed." : "At Melbourne Central, use the stairs only if safe and preferred.",
                "You have reached Melbourne Central."
            ]
        case .stateLibrary:
            return [
                "Start at Flinders Street Station on Swanston Street.",
                "Travel north along Swanston Street toward La Trobe Street.",
                "Use pedestrian signals at each crossing.",
                access ? "Use the accessible entry or lift where available." : "Use stairs only where safe and preferred.",
                "State Library Victoria is ahead."
            ]
        case .southernCross:
            return [
                "Start at Flinders Street Station on Flinders Street.",
                "Travel west toward Spencer Street using signal-controlled crossings.",
                access ? "At Southern Cross Station, follow signs for lifts and accessible entry." : "At Southern Cross Station, follow signs for the stair entry.",
                "You have reached Southern Cross Station."
            ]
        }
    }

    func submitCommand() {
        let text = command.lowercased()
        destination = CBDDestination.allCases.first { text.contains($0.rawValue.lowercased()) }
        if destination == nil, text.contains("library") { destination = .stateLibrary }
        if destination == nil, text.contains("central") { destination = .melbourneCentral }
        if destination == nil, text.contains("federation") || text.contains("fed square") { destination = .federationSquare }
        if destination == nil, text.contains("southern cross") { destination = .southernCross }

        if let destination {
            prompt = "Would you prefer a lift or stairs for elevation changes?"
            speech.speak("Destination set to \(destination.rawValue). Would you prefer a lift or stairs?")
        } else {
            prompt = "Try Federation Square, Melbourne Central, State Library Victoria, or Southern Cross Station."
            speech.speak(prompt)
        }
    }

    func choose(_ choice: MobilityChoice) {
        mobilityChoice = choice
        prompt = "\(choice.rawValue) preference selected. Start guidance when ready."
        speech.speak(prompt)
    }

    func start() {
        guard destination != nil, mobilityChoice != nil, !steps.isEmpty else { return }
        isNavigating = true
        stepIndex = 0
        speakCurrentStep()
    }

    func nextStep() {
        guard stepIndex < steps.count - 1 else { isNavigating = false; speech.speak("You have reached your destination."); return }
        stepIndex += 1
        speakCurrentStep()
    }

    func stop() { isNavigating = false; speech.stop() }

    private func speakCurrentStep() {
        let message = steps[stepIndex]
        prompt = "Step \(stepIndex + 1) of \(steps.count). \(message)"
        speech.speak(prompt)
    }
}
