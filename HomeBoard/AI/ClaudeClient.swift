import Foundation

/// Minimal Messages API client over URLSession (there's no official Swift SDK).
struct ClaudeClient {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Reply {
        let text: String
        /// The full assistant content, appended back unchanged on the next turn.
        let content: [[String: Any]]
    }

    let apiKey: String
    let model: String
    let effort: String

    /// `schema`, when given, constrains the reply to JSON matching it.
    func send(system: String, messages: [[String: Any]], schema: [String: Any]? = nil) async throws -> Reply {
        var outputConfig: [String: Any] = ["effort": effort]
        if let schema {
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": messages,
            "output_config": outputConfig,
            // If a safety classifier declines, the API reruns the request on Anthropic's
            // recommended fallback model instead of returning the refusal.
            "fallbacks": "default",
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw APIError(message: "Claude: \(message)")
        }
        if json["stop_reason"] as? String == "refusal" {
            throw APIError(message: "Claude declined to answer that.")
        }
        let content = json["content"] as? [[String: Any]] ?? []
        let text = content.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return Reply(text: text, content: content)
    }
}
