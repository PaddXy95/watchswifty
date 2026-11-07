import Elementary
import ElementaryHTMX2

/// Date + service form used for marking (or re-marking) an episode or movie.
struct WatchForm: HTML {
    let action: String
    let target: String
    let submitLabel: String
    let rewatch: Bool
    let today: String
    let defaultService: StreamingService?

    var body: some HTML {
        form(.class("watch-form"), .hx.post(action), .hx.target(target), .hx.swap(.outerHTML)) {
            label {
                "Datum"
                input(.type(.date), .name("day"), .value(today), .max(today), .required)
            }
            label {
                "Dienst"
                select(.name("service")) {
                    option(.value("")) { "unbekannt" }.attributes(.selected, when: defaultService == nil)
                    for service in StreamingService.allCases {
                        option(.value(service.rawValue)) { service.label }.attributes(.selected, when: service == defaultService)
                    }
                }
            }
            if rewatch {
                input(.type(.hidden), .name("rewatch"), .value("true"))
            }
            button(.type(.submit), .class("primary")) { submitLabel }
        }
    }
}
