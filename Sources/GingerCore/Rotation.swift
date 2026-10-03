import Foundation

public struct Rotation {
    public private(set) var currentID: String?
    private var shownAt: Date?
    public init() {}

    public mutating func select(_ id: String, now: Date) {
        currentID = id
        shownAt = now
    }

    public mutating func update(widgets: [WidgetConfiguration], now: Date) -> String? {
        let enabled = widgets.filter(\.enabled)
        guard !enabled.isEmpty else {
            currentID = nil
            shownAt = nil
            return nil
        }
        guard let index = enabled.firstIndex(where: { $0.id == currentID }) else {
            select(enabled[0].id, now: now)
            return currentID
        }
        if enabled.count > 1, let shownAt,
           now.timeIntervalSince(shownAt) >= enabled[index].displaySeconds {
            select(enabled[(index + 1) % enabled.count].id, now: now)
        }
        return currentID
    }
}
