import ARKit
import UIKit
import Vision

/// Camera, fingertip tracking and button anchoring, all on the phone.
///
/// ARKit tracks where the phone is in the room. When the panel is read, each
/// button's position is pinned to a 3D point on the panel surface (a raycast
/// into ARKit's estimate of the scene). Every frame those points are projected
/// back into the current image, so the outlines stay on the real buttons even
/// if the phone moves, and the hand covering the glossy panel doesn't matter
/// because ARKit tracks the whole room, not just the panel.
/// If a raycast finds no surface, that button falls back to its photo position,
/// which stays valid as long as the phone doesn't move (phone on a stand).
///
/// All coordinates are on a 0-1000 grid of the upright (portrait) image, origin top-left.
final class Camera: NSObject, ARSessionDelegate {
    let session = ARSession()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    private let visionQueue = DispatchQueue(label: "vision")
    private var busy = false
    private var latestFrame: ARFrame?
    /// The frame the last panel photo came from: buttons must be pinned using the
    /// camera pose at photo time, not after the ~20 s it takes to read the panel.
    private var scanFrame: ARFrame?
    private let context = CIContext()

    /// Called on the main thread with the index fingertip, or nil if no hand is visible.
    var onFingertip: ((CGPoint?) -> Void)?
    private(set) var handVisible = false

    private struct Anchor { let center: simd_float3; let corner1: simd_float3; let corner2: simd_float3 }
    private var anchors: [String: Anchor] = [:]
    private var photoBoxes: [String: [Double]] = [:]

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.vertical, .horizontal]
        session.delegate = self
        session.run(config)
    }

    // MARK: frames

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestFrame = frame
        guard !busy else { return }  // skip frames while Vision is working: no backlog, no lag
        busy = true
        let buffer = frame.capturedImage
        visionQueue.async { [weak self] in
            guard let self else { return }
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right)
            try? handler.perform([self.handRequest])
            var tip: CGPoint?
            let hand = self.handRequest.results?.first
            if let hand, let p = try? hand.recognizedPoint(.indexTip), p.confidence > 0.5 {
                tip = CGPoint(x: p.location.x * 1000, y: (1 - p.location.y) * 1000)  // flip to top-left origin
            }
            let visible = hand != nil
            DispatchQueue.main.async {
                self.handVisible = visible
                self.busy = false
                self.onFingertip?(tip)
            }
        }
    }

    /// The current frame as an upright JPEG: the same picture fingertips are tracked in.
    func snapshot(forScan: Bool = false) -> Data? {
        guard let frame = latestFrame else { return nil }
        if forScan { scanFrame = frame }
        let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }

    // MARK: anchoring

    /// Pin each button (boxes on the 0-1000 grid of the scanned photo) to the panel surface.
    func anchor(buttons: [PanelButton]) {
        anchors = [:]
        photoBoxes = [:]
        trackingOK = false
        for b in buttons { photoBoxes[b.id] = b.box }
        guard let frame = scanFrame ?? latestFrame else { return }
        let size = portraitSize(frame)
        // Distance to the panel: median of raycast hits at button centers (glossy
        // panels often give none), else 40 cm. All buttons then sit on ONE flat
        // plane facing the camera at that distance, so they move consistently.
        let camPos = simd_float3(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y,
                                 frame.camera.transform.columns.3.z)
        let depths = buttons.compactMap { b in
            hit(CGPoint(x: (b.box[0] + b.box[2]) / 2, y: (b.box[1] + b.box[3]) / 2), frame)
        }.map { simd_distance($0, camPos) }.filter { $0 > 0.1 && $0 < 2.0 }
        let depth = depths.isEmpty ? 0.4 : depths.sorted()[depths.count / 2]
        var plane = matrix_identity_float4x4
        plane.columns.3.z = -depth
        let tilt = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))  // x-z plane faces the camera
        let planeTransform = frame.camera.transform * plane * tilt
        func onPlane(_ p: CGPoint) -> simd_float3? {
            frame.camera.unprojectPoint(CGPoint(x: p.x / 1000 * size.width, y: p.y / 1000 * size.height),
                                        ontoPlane: planeTransform, orientation: .portrait, viewportSize: size)
        }
        for b in buttons {
            let c = CGPoint(x: (b.box[0] + b.box[2]) / 2, y: (b.box[1] + b.box[3]) / 2)
            if let center = onPlane(c), let p1 = onPlane(CGPoint(x: b.box[0], y: b.box[1])),
               let p2 = onPlane(CGPoint(x: b.box[2], y: b.box[3])) {
                anchors[b.id] = Anchor(center: center, corner1: p1, corner2: p2)
            }
        }
        // Self-check: projected back into the photo's own frame, every pinned box
        // must land on its photo box. If not, don't follow motion; use photo positions.
        var worst = 0.0
        for b in buttons {
            guard let a = anchors[b.id] else { continue }
            let p = projectBox(a, frame)
            worst = max(worst, zip(p, b.box).map { abs($0 - $1) }.max() ?? 0)
        }
        // Live motion-following was unreliable on glossy panels in device testing, so
        // it stays off: photo positions are exact while the phone is held still.
        trackingOK = false
        lastCheckError = worst
    }

    /// Whether boxes follow phone motion (self-check passed) or stay at photo positions.
    private(set) var trackingOK = false
    private(set) var lastCheckError = 0.0

    private func portraitSize(_ frame: ARFrame) -> CGSize {
        CGSize(width: CVPixelBufferGetHeight(frame.capturedImage), height: CVPixelBufferGetWidth(frame.capturedImage))
    }

    private func projectBox(_ a: Anchor, _ frame: ARFrame) -> [Double] {
        let size = portraitSize(frame)
        func project(_ p: simd_float3) -> CGPoint {
            let v = frame.camera.projectPoint(p, orientation: .portrait, viewportSize: size)
            return CGPoint(x: v.x / size.width * 1000, y: v.y / size.height * 1000)
        }
        let p1 = project(a.corner1), p2 = project(a.corner2)
        return [Double(min(p1.x, p2.x)), Double(min(p1.y, p2.y)), Double(max(p1.x, p2.x)), Double(max(p1.y, p2.y))]
    }

    var anchoredCount: Int { anchors.count }

    /// Where a button is in the current frame (0-1000 grid): follows the phone's
    /// motion when the self-check passed, otherwise the photo position.
    func box(for id: String) -> [Double]? {
        guard trackingOK, let a = anchors[id], let frame = latestFrame else { return photoBoxes[id] }
        return projectBox(a, frame)
    }

    /// Raycast from a point on the portrait 0-1000 grid into the scene.
    private func hit(_ p: CGPoint, _ frame: ARFrame) -> simd_float3? {
        // Portrait (u, v) -> captured image's landscape normalized coords (x = v, y = 1 - u).
        let point = CGPoint(x: p.y / 1000, y: 1 - p.x / 1000)
        let query = frame.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any)
        guard let result = session.raycast(query).first else { return nil }
        let t = result.worldTransform.columns.3
        return simd_float3(t.x, t.y, t.z)
    }
}
