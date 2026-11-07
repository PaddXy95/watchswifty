import Fluent
import Vapor

struct ImportController {
    struct UploadInput: Content { var file: File }

    static let notNetflixMessage = "Das ist keine Netflix-Wiedergabeaktivität (erwartet wird die Kopfzeile „Title,Date“)."

    func register(on protected: any RoutesBuilder) {
        protected.get("import", use: page)
        protected.on(.POST, "import", body: .collect(maxSize: "10mb"), use: upload)
    }

    func page(req: Request) async throws -> HTMLResponse {
        HTMLResponse(ImportPage(nav: try req.nav(.importing), summary: nil, error: nil))
    }

    func upload(req: Request) async throws -> HTMLResponse {
        let nav = try req.nav(.importing)
        let input = try req.content.decode(UploadInput.self)
        guard let text = String(data: Data(input.file.data.readableBytesView), encoding: .utf8) else {
            return HTMLResponse(status: .unprocessableEntity, ImportPage(nav: nav, summary: nil, error: "Die Datei ist nicht UTF-8-kodiert."))
        }
        do {
            let summary = try await ImportService(db: req.db).ingest(text: text, filename: input.file.filename, userID: try req.userID)
            return HTMLResponse(ImportPage(nav: nav, summary: summary, error: nil))
        } catch NetflixCSVError.notNetflixHistory {
            return HTMLResponse(status: .unprocessableEntity, ImportPage(nav: nav, summary: nil, error: Self.notNetflixMessage))
        } catch let NetflixCSVError.invalidDate(line, value) {
            return HTMLResponse(status: .unprocessableEntity,
                                ImportPage(nav: nav, summary: nil, error: "Zeile \(line): ungültiges Datum „\(value)“."))
        }
    }
}
