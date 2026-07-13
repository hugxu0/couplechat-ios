import Foundation

enum PlanEditorMode: Identifiable {
    case create(PersonalItemKind)
    case edit(PersonalItem)

    var id: String {
        switch self {
        case .create(let kind): return "create-\(kind.rawValue)"
        case .edit(let item): return "edit-\(item.id)"
        }
    }

    var kind: PersonalItemKind {
        switch self {
        case .create(let kind): return kind
        case .edit(let item): return item.kind
        }
    }

    var item: PersonalItem? {
        if case .edit(let item) = self { return item }
        return nil
    }
}
