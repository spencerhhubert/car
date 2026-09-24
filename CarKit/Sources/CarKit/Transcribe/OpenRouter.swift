import Foundation

// OpenRouter: the words, and optionally the times, from a cloud model.
public enum OpenRouter {
    public struct Model: Codable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    struct Segment: Codable { var start: Double; var end: Double; var text: String }
    /// Sound to send, and what it is (m4a, wav).
    struct Audio { let data: Data; let format: String }

    private static let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    static let transcribePrompt = """
    You are a transcription engine. Write down exactly what is said in the recording, verbatim, \
    in the speaker's own words: keep every filler ("um", "uh", "like"), false start and repetition. \
    Do not summarize, clean up, or add anything. No timestamps, no speaker labels, no commentary, \
    no headings. Plain text, broken into paragraphs where the speaker pauses. If there is no speech, \
    reply with exactly: [no speech]
    """

    static let timesPrompt = """
    You are a transcription engine with a clock. Transcribe the recording verbatim and return ONLY a \
    JSON array of segments, one per sentence or phrase, each {"start": seconds, "end": seconds, \
    "text": "..."} with times as decimal seconds from the start of the audio, as accurate as you can \
    make them. No prose, no code fence.
    """

    /// The words, as one plain text.
    /// The words of `seconds` of sound. The answer is capped at what a person
    /// could say in the time, twice over: a chat model that starts repeating
    /// itself on a clip is stopped there, not billed for pages.
    static func transcribe(audio: Audio, seconds: Double, model: String, key: String) async throws -> (String, Double?) {
        let (text, cost) = try await chat(model: model, system: transcribePrompt,
                                          userText: "Transcribe this recording.", audio: audio, key: key,
                                          maxTokens: Int(seconds * 10) + 200, timeout: 60 + seconds * 2)
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), cost)
    }

    /// Timed segments, from a model asked to keep time itself.
    static func timedSegments(audio: Audio, seconds: Double, model: String, key: String) async throws -> ([Segment], Double?) {
        let (text, cost) = try await chat(model: model, system: timesPrompt,
                                          userText: "Transcribe this recording with timestamps.", audio: audio, key: key,
                                          maxTokens: Int(seconds * 25) + 400, timeout: 60 + seconds * 2)
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        }
        if let start = body.firstIndex(of: "["), let end = body.lastIndex(of: "]") {
            body = String(body[start...end])
        }
        guard let data = body.data(using: .utf8),
              let segs = try? JSONDecoder().decode([Segment].self, from: data) else {
            throw Failure("\(model) did not return a JSON array of segments")
        }
        return (segs, cost)
    }

    static func chat(model: String, system: String, userText: String, audio: Audio?,
                     key: String, maxTokens: Int, timeout: TimeInterval) async throws -> (String, Double?) {
        var content: [[String: Any]] = [["type": "text", "text": userText]]
        if let audio {
            content.append(["type": "input_audio",
                            "input_audio": ["data": audio.data.base64EncodedString(), "format": audio.format]])
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": content]],
            "temperature": 0,
            "reasoning": ["enabled": false],
            "usage": ["include": true],
            "max_tokens": maxTokens,
        ]
        do {
            return try await post(body, key: key, timeout: timeout)
        } catch let e as Failure where e.message.lowercased().contains("reasoning") {
            body["reasoning"] = nil
            return try await post(body, key: key, timeout: timeout)
        }
    }

    private static func post(_ body: [String: Any], key: String, timeout: TimeInterval) async throws -> (String, Double?) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("car", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard code == 200 else {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8)?.prefix(300).description ?? ""
            throw Failure("openrouter \(code): \(msg)")
        }
        if let err = obj["error"] as? [String: Any] {
            throw Failure("openrouter: \(err["message"] ?? err)")
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw Failure("openrouter: no choices in the reply")
        }
        var text = ""
        if let s = message["content"] as? String { text = s }
        else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        }
        let cost = (obj["usage"] as? [String: Any])?["cost"] as? Double
        return (text, cost)
    }

    /// Every model that takes audio in.
    public static func audioModels(key: String) async throws -> [Model] {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { throw Failure("openrouter: bad models list") }
        return list.compactMap { m in
            guard let id = m["id"] as? String,
                  let arch = m["architecture"] as? [String: Any],
                  let inputs = arch["input_modalities"] as? [String], inputs.contains("audio") else { return nil }
            return Model(id: id, name: m["name"] as? String ?? id)
        }.sorted { $0.id < $1.id }
    }
}
