import Foundation

/// The network seam: providers talk to this, tests substitute a stub.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse("not an HTTP response")
        }
        return (data, http)
    }
}

/// JSON-over-HTTP with bearer auth, mapping non-2xx answers to ``ProviderError/http(status:message:)``.
struct APIClient: Sendable {
    let transport: any HTTPTransport
    let bearer: String?

    func post<Body: Encodable, Response: Decodable>(_ url: URL, body: Body) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try decode(try await data(for: request))
    }

    func post<Response: Decodable>(_ url: URL, form: MultipartForm) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.encoded
        return try decode(try await data(for: request))
    }

    func get<Response: Decodable>(_ url: URL) async throws -> Response {
        try decode(try await data(for: URLRequest(url: url)))
    }

    func data(for request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 300
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.http(status: response.statusCode, message: Self.errorMessage(in: data))
        }
        return data
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderError.malformedResponse(String(describing: error))
        }
    }

    /// Providers report errors as `{"error": "..."}` or `{"error": {"message": "..."}}`.
    private static func errorMessage(in data: Data) -> String {
        struct Flat: Decodable { let error: String }
        struct Nested: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }
        let decoder = JSONDecoder()
        if let flat = try? decoder.decode(Flat.self, from: data) { return flat.error }
        if let nested = try? decoder.decode(Nested.self, from: data) { return nested.error.message }
        return String(data: data.prefix(500), encoding: .utf8) ?? "no message"
    }
}

/// A `multipart/form-data` body, for endpoints that take file uploads.
struct MultipartForm {
    private let boundary = "appicon-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// The complete body, including the closing boundary.
    var encoded: Data { body + Data("--\(boundary)--\r\n".utf8) }

    mutating func field(_ name: String, _ value: String) {
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
    }

    mutating func file(_ name: String, filename: String, type: String, data: Data) {
        body += Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n"
                .utf8)
        body += data
        body += Data("\r\n".utf8)
    }
}
