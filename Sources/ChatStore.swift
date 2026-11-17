import Foundation

struct ModelInfo: Identifiable, Hashable {
    let id: String
    let provider: String

    var name: String { id }
    var icon: String {
        switch provider {
        case "anthropic": return "brain"
        case "openai": return "sparkles"
        case "google": return "globe"
        case "deepseek": return "waveform.path.ecg"
        case "xai": return "x.square"
        case "z.ai": return "z.circle"
        default: return "cpu"
        }
    }
}

enum APIError: LocalizedError {
    case badKey
    case http(Int, String)
    case decode

    var errorDescription: String? {
        switch self {
        case .badKey: return "Invalid API key (expected sk-…)"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(400))"
        case .decode: return "Could not decode response"
        }
    }
}

@MainActor
final class ChatStore: ObservableObject {
    @Published var key: String = "" {
        didSet { UserDefaults.standard.set(key, forKey: "positionai.key") }
    }
    @Published var models: [ModelInfo] = []
    @Published var selectedModel: String = "" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "positionai.model") }
    }
    @Published var conversations: [Conversation] = [] {
        didSet { saveConversations() }
    }
    @Published var currentID: UUID = UUID()
    @Published var input: String = ""
    @Published var sending = false
    @Published var errorMessage: String?
    @Published var systemPrompt: String = "" {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "positionai.system") }
    }
    @Published var temperature: Double = 0.7 {
        didSet { UserDefaults.standard.set(temperature, forKey: "positionai.temp") }
    }
    @Published var maxTokens: Int = 2048 {
        didSet { UserDefaults.standard.set(maxTokens, forKey: "positionai.maxTokens") }
    }

    private var task: URLSessionDataTask?

    var current: Conversation? {
        conversations.first { $0.id == currentID }
    }

    init() {
        key = UserDefaults.standard.string(forKey: "positionai.key") ?? ""
        selectedModel = UserDefaults.standard.string(forKey: "positionai.model") ?? ""
        systemPrompt = UserDefaults.standard.string(forKey: "positionai.system") ?? ""
        temperature = UserDefaults.standard.object(forKey: "positionai.temp") as? Double ?? 0.7
        maxTokens = UserDefaults.standard.object(forKey: "positionai.maxTokens") as? Int ?? 2048
        loadConversations()
        if conversations.isEmpty { newChat() }
        if !key.isEmpty { Task { try? await loadModels() } }
    }

    var baseURL: URL { URL(string: "https://positionapi.top/v1")! }

    private func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    func loadModels() async throws {
        guard key.hasPrefix("sk-") else { throw APIError.badKey }
        var r = URLRequest(url: baseURL.appendingPathComponent("models"))
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw APIError.decode }
        guard http.statusCode == 200 else {
            throw APIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(ModelList.self, from: data)
        models = decoded.data.map { ModelInfo(id: $0.id, provider: $0.owned_by) }.sorted { $0.id < $1.id }
        if selectedModel.isEmpty || !models.contains(where: { $0.id == selectedModel }) {
            selectedModel = models.first?.id ?? ""
        }
    }

    func newChat() {
        let c = Conversation()
        conversations.insert(c, at: 0)
        currentID = c.id
    }

    func deleteChat(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = conversations.first?.id ?? UUID() }
        if conversations.isEmpty { newChat() }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, !selectedModel.isEmpty else { return }
        guard var convo = current else { return }
        convo.messages.append(Message(role: "user", content: text))
        input = ""
        let index = conversations.firstIndex { $0.id == convo.id }!
        conversations[index] = convo
        sending = true
        errorMessage = nil
        let placeholder = Message(role: "assistant", content: "", isStreaming: true)
        conversations[index].messages.append(placeholder)

        var messages: [[String: Any]] = []
        if !systemPrompt.isEmpty { messages.append(["role": "system", "content": systemPrompt]) }
        for m in convo.messages {
            messages.append(["role": m.role, "content": m.content])
        }
        var body: [String: Any] = [
            "model": selectedModel,
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": true
        ]
        // Newer Claude models reject explicit temperature / sampling fields.
        if ["claude-"].contains(where: { selectedModel.hasPrefix($0) }) {
            body.removeValue(forKey: "temperature")
        }
        let r = request("chat/completions")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)

        task = URLSession.shared.dataTask(with: r) { [weak self] data, response, error in
            guard let self = self else { return }
            Task { @MainActor in
                defer { self.sending = false }
                if let error { self.errorMessage = error.localizedDescription; self.finishStream(); return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    self.errorMessage = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(String(decoding: data ?? Data(), as: UTF8.self).prefix(400))"
                    self.finishStream(); return
                }
                let raw = String(decoding: data ?? Data(), as: UTF8.self)
                var answer = ""
                for line in raw.split(separator: "\n") {
                    guard line.hasPrefix("data: ") else { continue }
                    let payload = line.dropFirst(6)
                    if payload == "[DONE]" { break }
                    guard let json = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any] else { continue }
                    if let content = delta["content"] as? String { answer += content }
                    else if let content = delta["content"] as? [[String: Any]] {
                        for part in content { if let t = part["text"] as? String { answer += t } }
                    }
                }
                if answer.isEmpty {
                    // Non-streaming fallback shape.
                    if let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let msg = choices.first?["message"] as? [String: Any] {
                        answer = msg["content"] as? String ?? ""
                    }
                }
                self.setStream(answer)
            }
        }
        task?.resume()
    }

    func stop() {
        task?.cancel()
        sending = false
        finishStream()
    }

    private func finishStream() {
        guard var c = current, var last = c.messages.last, last.isStreaming else { return }
        last.isStreaming = false
        c.messages[c.messages.count - 1] = last
        if let i = conversations.firstIndex(where: { $0.id == c.id }) { conversations[i] = c }
    }

    private func setStream(_ text: String) {
        guard var c = current, var last = c.messages.last, last.isStreaming else { return }
        last.content = text
        last.isStreaming = false
        c.messages[c.messages.count - 1] = last
        if let i = conversations.firstIndex(where: { $0.id == c.id }) { conversations[i] = c }
    }

    private func conversationsFile() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conversations.json")
    }

    private func saveConversations() {
        try? JSONEncoder().encode(conversations).write(to: conversationsFile())
    }

    private func loadConversations() {
        guard let data = try? Data(contentsOf: conversationsFile()),
              let decoded = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = decoded
        currentID = decoded.first?.id ?? UUID()
    }
}

struct ModelList: Decodable {
    let data: [ModelDTO]
}

struct ModelDTO: Decodable {
    let id: String
    let owned_by: String
}

struct Message: Identifiable, Codable {
    let id: UUID
    let role: String
    var content: String
    var isStreaming: Bool

    init(role: String, content: String, isStreaming: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
    }
}

struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [Message]

    init() {
        id = UUID()
        title = "New chat"
        messages = []
    }
}
