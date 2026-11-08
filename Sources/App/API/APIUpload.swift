import Foundation
import OpenAPIRuntime

/// Reads the `file` part of an upload, at most `limit` bytes (`413 payloadTooLarge` above). OpenAPIVapor streams
/// request bodies, so this is the only size limit for API uploads.
func uploadedFile<Payload: Sendable & Hashable>(
    _ body: MultipartBody<Payload>, limit: Int, file: (Payload) -> (body: HTTPBody, filename: String?)?
) async throws -> (data: Data, filename: String) {
    for try await part in body {
        guard let (content, filename) = file(part) else { continue }
        var data = Data()
        for try await chunk in content {
            guard data.count + chunk.count <= limit else { throw APIError.payloadTooLarge }
            data.append(contentsOf: chunk)
        }
        return (data, filename ?? "upload.csv")
    }
    throw APIError.validation("Keine Datei hochgeladen.")
}

/// Decodes an uploaded CSV as UTF-8 (Windows-1252 as fallback for spreadsheet exports when allowed).
func uploadedText(_ data: Data, allowLatin: Bool = false) throws -> String {
    if let text = String(data: data, encoding: .utf8) { return text }
    if allowLatin, let text = String(data: data, encoding: .windowsCP1252) { return text }
    throw APIError.validation("Die Datei ist nicht UTF-8-kodiert.")
}
