import ARKit
import SwiftUI

@main
struct FingertipApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model).onAppear { model.start() }
        }
    }
}

/// No buttons to find: the whole screen is one control, because a blind user
/// can't locate on-screen buttons any more than buttons on a microwave.
///   tap anywhere        -> scan (or "I pressed it" while guiding)
///   press and hold      -> talk; release when done
/// The app also scans by itself when it opens and listens by itself after a scan.
/// The camera view and overlay are for sighted helpers and the demo video.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var typedGoal = ""
    @State private var showSettings = false
    @AppStorage("flipX") private var flipX = false
    @AppStorage("flipY") private var flipY = false
    @AppStorage("followMotion") private var followMotion = true

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 12) {
                ZStack {
                    // The camera image itself, so the outlines are drawn on exactly the
                    // picture the guidance measures.
                    if let img = model.preview {
                        Image(uiImage: img).resizable()
                    } else {
                        Color.black
                    }
                    Overlay(boxes: model.liveBoxes, target: model.targetBox, tip: model.tip)
                }
                // ARKit frames are 3:4 portrait; the view must match or the outlines drift.
                .aspectRatio(3.0 / 4.0, contentMode: .fit)

                if !model.heard.isEmpty {
                    Text("Heard: \(model.heard)").font(.callout).foregroundStyle(.secondary)
                }
                Text(model.status)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Tap anywhere to scan · hold anywhere to talk")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.primaryAction() }
            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 60, perform: {}, onPressingChanged: { down in
                if down { model.startListening() } else if model.phase == .listening { model.stopListening() }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.status)
            .accessibilityHint("Double tap to scan or confirm a press. Double tap and hold to talk.")
            .accessibilityAction(.magicTap) { model.startListening() }
            .accessibilityAddTraits(.allowsDirectInteraction)
            HStack {
                TextField("Or type a goal", text: $typedGoal)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.requestPlan(goal: typedGoal) }
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Backend address")
            }
            if showSettings {
                TextField("Backend URL", text: $model.backendURL)
                    .textFieldStyle(.roundedBorder).keyboardType(.URL).autocorrectionDisabled()
                Toggle("Detailed speech", isOn: $model.verbose)
                Toggle("Flip motion left/right", isOn: $flipX)
                Toggle("Flip motion up/down", isOn: $flipY)
                Toggle("Follow motion", isOn: $followMotion)
            }
        }
        .padding()
    }
}

struct BigButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack { Image(systemName: systemImage).font(.title); Text(title).font(.headline) }
                .frame(maxWidth: .infinity, minHeight: 80)
        }
        .buttonStyle(.borderedProminent)
    }
}

/// Draws button outlines, the current target and the tracked fingertip (0-1000 grid).
struct Overlay: View {
    let boxes: [(String, [Double])]
    let target: [Double]?
    let tip: CGPoint?
    var body: some View {
        GeometryReader { geo in
            let sx = geo.size.width / 1000, sy = geo.size.height / 1000
            ForEach(boxes, id: \.0) { item in
                let b = item.1
                Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1)
                    .frame(width: (b[2] - b[0]) * sx, height: (b[3] - b[1]) * sy)
                    .position(x: (b[0] + b[2]) / 2 * sx, y: (b[1] + b[3]) / 2 * sy)
            }
            if let t = target {
                Rectangle().stroke(Color.green, lineWidth: 4)
                    .frame(width: (t[2] - t[0]) * sx, height: (t[3] - t[1]) * sy)
                    .position(x: (t[0] + t[2]) / 2 * sx, y: (t[1] + t[3]) / 2 * sy)
            }
            if let p = tip {
                Circle().fill(Color.yellow).frame(width: 18, height: 18).position(x: p.x * sx, y: p.y * sy)
            }
        }
    }
}

/// Live camera view from the same ARKit session the app tracks with.
struct CameraPreview: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.session = session
        v.automaticallyUpdatesLighting = false
        return v
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
