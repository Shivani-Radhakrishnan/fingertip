import AVFoundation
import SwiftUI

/// The whole loop: scan the panel -> hear the goal -> speak the plan ->
/// guide the finger to each button -> check the press -> next step (or re-plan).
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, ready, listening, planning, guiding, checking, done }

    @Published var phase: Phase = .idle
    @Published var status = "Point the phone at the panel and hold it still."
    @Published var heard = ""
    @Published var panel: Panel?
    @Published var plan: Plan?
    @Published var stepIndex = 0
    @Published var tip: CGPoint?
    @Published var preview: UIImage?
    @AppStorage("backendURL") var backendURL = "http://192.168.1.89:8000"
    @AppStorage("verbose") var verbose = false

    let camera = Camera()
    private let guide = Guide()
    private let speech = AVSpeechSynthesizer()
    private let listener = Listener()
    private var panelJSON = Data()
    private var goal = ""
    private var beforePhoto: Data?
    private var pressCuedAt: Date?
    private var lastCheck = Date.distantPast
    private var replans = 0

    var backend: Backend { Backend(baseURL: URL(string: backendURL) ?? URL(string: "http://localhost:8000")!) }
    var currentStep: Step? { plan.flatMap { stepIndex < $0.steps.count ? $0.steps[stepIndex] : nil } }
    var targetBox: [Double]? { currentStep.flatMap { camera.box(for: $0.button_id) } }
    var liveBoxes: [(String, [Double])] {
        (panel?.buttons ?? []).compactMap { b in camera.box(for: b.id).map { (b.id, $0) } }
    }

    func start() {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio,
                                                         options: [.defaultToSpeaker, .duckOthers, .allowBluetooth])
        try? AVAudioSession.sharedInstance().setActive(true)
        camera.onFingertip = { [weak self] tip in self?.onFingertip(tip) }
        camera.onPreview = { [weak self] img in self?.preview = img }
        camera.start()
        listener.onPartial = { [weak self] text in self?.heard = text }
        listener.onFinal = { [weak self] text in self?.handleUtterance(text) }
        listener.onError = { [weak self] err in
            self?.phase = self?.plan == nil ? .ready : .guiding
            self?.say("I didn't catch that. Hold Speak and try again. \(err)")
        }
        say("Fingertip ready. Point the phone at the panel and hold it still.")
        Task {  // scan by itself once the camera has settled
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if phase == .idle { scan() }
        }
    }

    /// Tap anywhere: confirm a press while guiding, otherwise (re)scan.
    func primaryAction() {
        switch phase {
        case .guiding: pressedManually()
        case .scanning, .planning, .checking, .listening: break
        default: scan()
        }
    }

    // MARK: speech

    /// With VoiceOver on, speak through VoiceOver so two voices never talk over each other.
    func say(_ text: String, interrupt: Bool = true) {
        guard !text.isEmpty else { return }
        status = text
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
            return
        }
        if interrupt { speech.stopSpeaking(at: .word) }  // drop stale directions
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.55
        speech.speak(u)
    }

    /// Snapshots must show the panel, not the user's hand.
    private func clearPhoto(forScan: Bool = false) async -> Data? {
        if camera.handVisible {
            say("Move your hand away from the panel.")
            for _ in 0..<30 where camera.handVisible { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        return camera.snapshot(forScan: forScan)
    }

    // MARK: 1. scan

    func scan() {
        phase = .scanning
        Task {
            guard let photo = await clearPhoto(forScan: true) else { say("Camera not ready yet."); phase = .idle; return }
            say("Reading the panel.")
            do {
                let (p, raw) = try await backend.read(photo: photo)
                panel = p
                panelJSON = raw
                plan = nil
                if !p.framing.ok {
                    phase = .idle
                    say(p.framing.hint.isEmpty ? "I can't see the whole panel. Move the phone back." : p.framing.hint)
                    return
                }
                camera.anchor(buttons: p.buttons)
                phase = .ready
                let remembered = p.remembered == true ? "I know this one. " : ""
                let display = p.display_text.isEmpty ? "" : " Display shows \(p.display_text)."
                var text = "\(remembered)\(p.device). \(p.buttons.count) buttons.\(display)"
                if verbose { text += " Buttons: " + p.buttons.map(\.label).joined(separator: ", ") + "." }
                say(text + " What would you like to do?")
                try? await Task.sleep(nanoseconds: 2_500_000_000)  // let the question finish
                if phase == .ready { startListening() }  // hands-free: just answer
            } catch {
                phase = .idle
                say("Couldn't read the panel. \(error.localizedDescription)")
            }
        }
    }

    // MARK: 2. voice

    func startListening() {
        guard let panel else { say("Scan the panel first."); return }
        speech.stopSpeaking(at: .immediate)
        heard = ""
        phase = .listening
        status = "Listening…"
        listener.start(backend: backend.baseURL, keywords: panel.buttons.map(\.label) + ["repeat", "skip", "stop"])
    }

    func stopListening() { listener.stop() }

    /// Words said while a plan is running are commands; otherwise they are the goal.
    private func handleUtterance(_ text: String) {
        heard = text
        let t = text.lowercased()
        if plan != nil, t.contains("repeat") { say(plan!.say); phase = .guiding; return }
        if plan != nil, t.contains("skip") { stepIndex += 1; beginStep(); return }
        if t.contains("stop") || t.contains("cancel") { plan = nil; phase = .ready; say("Stopped."); return }
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else {
            phase = .ready
            say("I didn't hear anything. Hold Speak and try again.")
            return
        }
        requestPlan(goal: text)
    }

    func requestPlan(goal: String) {
        self.goal = goal
        replans = 0
        phase = .planning
        say("Planning.")
        Task { await fetchPlan(goal) }
    }

    private func fetchPlan(_ request: String) async {
        do {
            let p = try await backend.plan(panelJSON: panelJSON, goal: request, audio: nil)
            plan = p
            guard p.feasible, !p.steps.isEmpty else {
                phase = .ready
                say(p.say.isEmpty ? "I can't do that on this panel." : p.say)
                return
            }
            stepIndex = 0
            say(p.say)
            beginStep()
        } catch {
            phase = .ready
            say("Couldn't plan that. \(error.localizedDescription)")
        }
    }

    // MARK: 3. guide

    private func beginStep() {
        guard let step = currentStep else { finish(); return }
        guide.reset()
        pressCuedAt = nil
        phase = .guiding
        Task {
            beforePhoto = await clearPhoto()
            say("Next: \(step.label).", interrupt: false)
        }
    }

    private func onFingertip(_ tip: CGPoint?) {
        self.tip = tip
        guard phase == .guiding, let box = targetBox else { return }
        let cue = guide.update(tip: tip, box: box)
        if let s = cue.speech { say(s) }
        if cue.tick { Guide.playTick() }
        if cue.onTarget, pressCuedAt == nil { pressCuedAt = Date() }
        // After "Press", once the finger leaves the button (or the hand
        // disappears) for a moment, treat it as pressed and check the result.
        if let cued = pressCuedAt, !cue.onTarget, Date().timeIntervalSince(cued) > 0.8 {
            pressCuedAt = nil
            checkPress()
        }
    }

    /// Manual fallback: the user (or a helper) says the press is done.
    func pressedManually() { if phase == .guiding { checkPress() } }

    // MARK: 4. check

    private func checkPress() {
        guard let step = currentStep, Date().timeIntervalSince(lastCheck) > 1.5 else { return }
        lastCheck = Date()
        phase = .checking
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)  // give the display time to change
            guard let before = beforePhoto, let after = await clearPhoto() else { beginStep(); return }
            do {
                let v = try await backend.check(before: before, after: after, step: step)
                switch v.verdict {
                case "ok":
                    say(v.say)
                    stepIndex += 1
                    beginStep()
                case "wrong" where replans < 2:
                    // Something else changed: re-plan from the panel's new state.
                    replans += 1
                    say(v.say + " Let's fix that.")
                    phase = .planning
                    await fetchPlan("\(goal). The last press went wrong: \(v.say) The display now shows \"\(v.display_text)\". Plan from this state.")
                default:  // retry / unsure / too many re-plans
                    say(v.say.isEmpty ? "That didn't register. Press again." : v.say)
                    beginStep()
                }
            } catch {
                say("Couldn't check the press. Moving on.")
                stepIndex += 1
                beginStep()
            }
        }
    }

    private func finish() {
        phase = .done
        plan = nil
        say("Done.")
    }
}
