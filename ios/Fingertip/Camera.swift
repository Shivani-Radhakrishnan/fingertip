import ARKit
import UIKit
import Vision

/// Camera, fingertip tracking and button following, all on the phone.
///
/// Everything uses ONE coordinate space: the upright camera image on a 0-1000
/// grid (origin top-left). The panel photo, the fingertip, the on-screen preview
/// and the button boxes all come from the same camera frames, so what the user
/// (or a sighted helper) sees is exactly what the guidance uses.
///
/// Following the phone's motion: every few frames the current image is matched
/// against the scan photo (Vision translational image registration), and the
/// button boxes are shifted by however much the picture moved. This handles
/// hand shake and small moves without needing a surface for 3D tracking, which
/// glossy black panels don't give.
final class Camera: NSObject, ARSessionDelegate {
    let session = ARSession()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    private let visionQueue = DispatchQueue(label: "vision")
    private var busy = false
    private var frameCount = 0
    private var latestFrame: ARFrame?
    private let context = CIContext()

    /// Called on the main thread with the index fingertip, or nil if no hand is visible.
    var onFingertip: ((CGPoint?) -> Void)?
    /// Called on the main thread with a small upright preview image (~10 per second).
    var onPreview: ((UIImage) -> Void)?
    private(set) var handVisible = false

    // Motion following
    private var reference: CIImage?        // downscaled scan photo
    private var offset = CGPoint.zero      // how far the picture moved since the scan, on the 0-1000 grid
    private var photoBoxes: [String: [Double]] = [:]
    private static let smallScale: CGFloat = 0.25

    func start() {
        session.delegate = self
        session.run(ARWorldTrackingConfiguration())
    }

    private func upright(_ frame: ARFrame) -> CIImage {
        CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
    }

    // MARK: frames

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestFrame = frame
        guard !busy else { return }  // skip frames while Vision is working: no backlog, no lag
        busy = true
        frameCount += 1
        let n = frameCount
        visionQueue.async { [weak self] in
            guard let self else { return }
            let image = self.upright(frame)
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            try? handler.perform([self.handRequest])
            var tip: CGPoint?
            let hand = self.handRequest.results?.first
            if let hand {
                // Prefer the index tip; fall back to the index's middle joints when the tip is unsure.
                for j: VNHumanHandPoseObservation.JointName in [.indexTip, .indexDIP, .indexPIP] {
                    if let p = try? hand.recognizedPoint(j), p.confidence > 0.3 {
                        tip = CGPoint(x: p.location.x * 1000, y: (1 - p.location.y) * 1000)
                        break
                    }
                }
            }
            if n % 4 == 0 { self.updateOffset(image) }
            let preview: UIImage? = n % 3 == 0 ? self.previewImage(image) : nil
            DispatchQueue.main.async {
                self.handVisible = hand != nil
                self.busy = false
                self.onFingertip?(tip)
                if let preview { self.onPreview?(preview) }
            }
        }
    }

    private func small(_ image: CIImage) -> CIImage {
        let s = image.transformed(by: CGAffineTransform(scaleX: Camera.smallScale, y: Camera.smallScale))
        return s.transformed(by: CGAffineTransform(translationX: -s.extent.origin.x, y: -s.extent.origin.y))
    }

    private func previewImage(_ image: CIImage) -> UIImage? {
        let s = image.transformed(by: CGAffineTransform(scaleX: 0.4, y: 0.4))
        guard let cg = context.createCGImage(s, from: s.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Match the current picture against the scan photo and remember the shift.
    private func updateOffset(_ image: CIImage) {
        guard let reference else { return }
        let current = small(image)
        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: reference)
        let handler = VNImageRequestHandler(ciImage: current, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return }
        let t = obs.alignmentTransform
        let w = current.extent.width, h = current.extent.height
        // Core Image's y axis points up; the grid's points down.
        let fx = UserDefaults.standard.bool(forKey: "flipX") ? -1.0 : 1.0
        let fy = UserDefaults.standard.bool(forKey: "flipY") ? -1.0 : 1.0
        let dx = fx * t.tx / w * 1000, dy = fy * -t.ty / h * 1000
        guard abs(dx) < 400, abs(dy) < 400 else { return }  // ignore wild matches (e.g. hand filling the view)
        DispatchQueue.main.async { self.offset = CGPoint(x: dx, y: dy) }
    }

    /// The current frame as an upright JPEG. For a scan, it also becomes the
    /// reference picture that motion is measured against.
    func snapshot(forScan: Bool = false) -> Data? {
        guard let frame = latestFrame else { return nil }
        let image = upright(frame)
        if forScan {
            reference = small(image)
            offset = .zero
        }
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }

    // MARK: boxes

    func anchor(buttons: [PanelButton]) {
        photoBoxes = Dictionary(buttons.map { ($0.id, $0.box) }, uniquingKeysWith: { a, _ in a })
    }

    /// Where a button is now: its photo box shifted by how far the picture moved.
    func box(for id: String) -> [Double]? {
        guard let b = photoBoxes[id] else { return nil }
        let follow = UserDefaults.standard.object(forKey: "followMotion") as? Bool ?? true
        let dx = follow ? Double(offset.x) : 0, dy = follow ? Double(offset.y) : 0
        return [b[0] + dx, b[1] + dy, b[2] + dx, b[3] + dy]
    }
}
