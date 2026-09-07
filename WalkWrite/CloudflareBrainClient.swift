import Foundation

enum BrainClientError: Error {
    case badURL
    case http(Int)
    case empty
    case decode
}

enum CloudflareBrainClient {
    static func define(rawTranscript: String, locale: String = "ru", workerURL: URL) async throws -> BrainResponse {
        var request = URLRequest(url: workerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode([
            "raw_transcript": rawTranscript,
            "locale": locale,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw BrainClientError.http(code) }
        do {
            let decoded = try JSONDecoder().decode(BrainResponse.self, from: data)
            guard !decoded.cards.isEmpty else { throw BrainClientError.empty }
            return decoded
        } catch is BrainClientError {
            throw BrainClientError.empty
        } catch {
            throw BrainClientError.decode
        }
    }
}
