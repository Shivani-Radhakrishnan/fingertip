import Foundation

struct PanelButton: Codable, Identifiable {
    let id: String
    let label: String
    let kind: String
    let x: Double
    let y: Double
    let box: [Double]
    let confidence: String
}

struct Panel: Codable {
    struct Framing: Codable { let ok: Bool; let hint: String }
    let device: String
    let display_text: String
    let framing: Framing
    let buttons: [PanelButton]
    let remembered: Bool?
}

struct Step: Codable { let button_id: String; let label: String; let expect_display: String }
struct Plan: Codable { let feasible: Bool; let say: String; let steps: [Step]; let heard: String? }
struct Verdict: Codable { let verdict: String; let display_text: String; let say: String }

/// Talks to the Fingertip backend running on your Mac (same Wi-Fi).
struct Backend {
    var baseURL: URL

    func read(photo: Data) async throws -> (Panel, Data) {
        let data = try await post("read", files: [("photo", "panel.jpg", "image/jpeg", photo)], fields: [:])
        return (try JSONDecoder().decode(Panel.self, from: data), data)
    }

    func plan(panelJSON: Data, goal: String?, audio: Data?) async throws -> Plan {
        var files: [(String, String, String, Data)] = []
        if let audio { files.append(("audio", "goal.wav", "audio/wav", audio)) }
        let data = try await post("plan", files: files,
                                  fields: ["panel": String(decoding: panelJSON, as: UTF8.self), "goal": goal ?? ""])
        return try JSONDecoder().decode(Plan.self, from: data)
    }

    func check(before: Data, after: Data, step: Step) async throws -> Verdict {
        let stepJSON = String(decoding: try JSONEncoder().encode(step), as: UTF8.self)
        let data = try await post("check", files: [("before", "before.jpg", "image/jpeg", before),
                                                   ("after", "after.jpg", "image/jpeg", after)],
                                  fields: ["step": stepJSON])
        return try JSONDecoder().decode(Verdict.self, from: data)
    }

    private func post(_ path: String, files: [(String, String, String, Data)], fields: [String: String]) async throws -> Data {
        let boundary = UUID().uuidString
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        for (k, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        for (name, filename, type, data) in files {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n")
            body.append(data)
            add("\r\n")
        }
        add("--\(boundary)--\r\n")
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "Fingertip", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return data
    }
}
