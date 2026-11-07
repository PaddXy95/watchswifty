import Elementary

struct SiteFooter: HTML {
    /// Shown to admins when the update check found a newer release.
    var updateVersion: String? = nil

    var body: some HTML {
        footer(.class("site-footer")) {
            let version = AppVersion.current
            span(.class("version")) {
                if let url = version.releaseURL {
                    a(.href(url), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) { version.label }
                } else {
                    version.label
                }
                if let updateVersion {
                    " · "
                    a(.href("/admin/system"), .class("update-hint")) { "Update auf v\(updateVersion) verfügbar" }
                }
            }
            p(.class("made-with")) {
                "Built with "
                a(.href("https://www.swift.org"), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) { "Swift" }
                " and "
                a(.href("https://vapor.codes"), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) { "Vapor" }
                " with ❤️"
            }
            a(.class("github"), .href("https://github.com/PaddXy95/watchswifty"), .target(.blank),
              .custom(name: "rel", value: "noopener noreferrer")) { "GitHub" }
        }
    }
}
