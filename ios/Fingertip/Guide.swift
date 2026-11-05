import AudioToolbox
import UIKit

/// Turns "where is the fingertip" + "where is the target" into feedback.
/// Two stages, following what worked for blind users in guidance studies:
/// short spoken words for big moves, then ticks that speed up as the finger
/// closes in, then a single "On it. Press." once it has held on target.
final class Guide {
    struct Cue { let speech: String?; let tick: Bool; let onTarget: Bool }

    private var lastSpoken = Date.distantPast
    private var lastTick = Date.distantPast
    private var onSince: Date?
    private var lastHandSeen = Date()
    private(set) var announcedPress = false

    func reset() {
        onSince = nil
        announcedPress = false
        lastSpoken = .distantPast
        lastHandSeen = Date()
    }

    /// `box` is [x1, y1, x2, y2] on the 0-1000 grid.
    func update(tip: CGPoint?, box: [Double], now: Date = Date()) -> Cue {
        guard let tip else {
            onSince = nil
            if now.timeIntervalSince(lastHandSeen) > 2.5, now.timeIntervalSince(lastSpoken) > 3 {
                lastSpoken = now
                return Cue(speech: "I can't see your hand.", tick: false, onTarget: false)
            }
            return Cue(speech: nil, tick: false, onTarget: false)
        }
        lastHandSeen = now
        let cx = (box[0] + box[2]) / 2, cy = (box[1] + box[3]) / 2
        let w = max(box[2] - box[0], 20), h = max(box[3] - box[1], 20)
        let inside = tip.x >= box[0] && tip.x <= box[2] && tip.y >= box[1] && tip.y <= box[3]

        if inside {
            if onSince == nil { onSince = now }
            if !announcedPress, now.timeIntervalSince(onSince!) > 0.5 {
                announcedPress = true
                return Cue(speech: "On it. Press.", tick: false, onTarget: true)
            }
            return Cue(speech: nil, tick: false, onTarget: announcedPress)
        }
        onSince = nil
        announcedPress = false

        let dx = cx - tip.x, dy = cy - tip.y
        let dist = (dx * dx + dy * dy).squareRoot()
        let size = max(w, h)

        // Close: ticks only, faster as the finger gets closer (no words in the way).
        if dist < size * 2.5 {
            let interval = 0.08 + 0.5 * min(dist / (size * 2.5), 1)
            if now.timeIntervalSince(lastTick) > interval {
                lastTick = now
                return Cue(speech: nil, tick: true, onTarget: false)
            }
            return Cue(speech: nil, tick: false, onTarget: false)
        }
        // Far: one or two words, at most about once a second.
        if now.timeIntervalSince(lastSpoken) > 1.1 {
            lastSpoken = now
            var words: [String] = []
            if abs(dx) > w * 0.6 { words.append(dx > 0 ? "right" : "left") }
            if abs(dy) > h * 0.6 { words.append(dy > 0 ? "down" : "up") }
            return Cue(speech: words.joined(separator: ", "), tick: false, onTarget: false)
        }
        return Cue(speech: nil, tick: false, onTarget: false)
    }

    static func playTick() {
        AudioServicesPlaySystemSound(1104)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
