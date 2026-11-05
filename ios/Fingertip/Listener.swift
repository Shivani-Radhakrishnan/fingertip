import AVFoundation

/// Hands-free listening: streams microphone audio (24 kHz, 16-bit mono PCM)
/// to the backend's /listen socket, which relays it to Muse Voice Transcribe
/// in endpointing mode. Meta's model decides when the user has finished speaking.
final class Listener {
    private let engine = AVAudioEngine()
    private var socket: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private var finished = false

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    func start(backend: URL, keywords: [String]) {
        finished = false
        var comps = URLComponents(url: backend.appendingPathComponent("listen"), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        let task = URLSession.shared.webSocketTask(with: comps.url!)
        socket = task
        task.resume()
        let hello = (try? JSONSerialization.data(withJSONObject: ["keywords": keywords])) ?? Data()
        task.send(.string(String(decoding: hello, as: UTF8.self))) { _ in }
        receive()

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2400, format: inFormat) { [weak self] buffer, _ in
            self?.send(buffer)
        }
        try? engine.start()
    }

    /// Manual end (button released). Normally Meta's endpointing ends it on its own.
    func stop() {
        guard !finished else { return }
        socket?.send(.string("end")) { _ in }
        stopAudio()
    }

    private func stopAudio() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func send(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let socket, !finished else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat,
                                         frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        socket.send(.data(data)) { _ in }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                if !self.finished { DispatchQueue.main.async { self.onError?(e.localizedDescription) } }
            case .success(let msg):
                guard case .string(let s) = msg,
                      let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
                    self.receive(); return
                }
                let type = obj["type"] as? String ?? ""
                let text = obj["text"] as? String ?? ""
                DispatchQueue.main.async {
                    switch type {
                    case "final":
                        self.finished = true
                        self.stopAudio()
                        self.onFinal?(text)
                    case "error":
                        self.finished = true
                        self.stopAudio()
                        self.onError?(text)
                    default:
                        if !text.isEmpty { self.onPartial?(text) }
                    }
                }
                if type != "final" && type != "error" { self.receive() }
            }
        }
    }
}
