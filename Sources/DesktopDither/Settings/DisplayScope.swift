enum DisplayScope: String, CaseIterable, Codable, Sendable {
    case all
    case main

    var title: String {
        switch self {
        case .all:
            "All displays"
        case .main:
            "Menu-bar display"
        }
    }
}
