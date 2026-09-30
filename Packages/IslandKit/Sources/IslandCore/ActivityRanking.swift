import Foundation

public struct RankedActivities: Equatable, Sendable {
    /// Shown on the compact island, most important first. At most `limit`.
    public var visible: [Activity]
    /// Live but not shown in compact; summarised as a "+N" chip.
    public var overflow: [Activity]

    public init(visible: [Activity] = [], overflow: [Activity] = []) {
        self.visible = visible; self.overflow = overflow
    }

    public var primary: Activity? { visible.first }
    public var secondaries: ArraySlice<Activity> { visible.dropFirst() }
    public var isEmpty: Bool { visible.isEmpty }
    public var all: [Activity] { visible + overflow }
}

public enum ActivityRanking {
    /// Orders live activities for the compact island.
    ///
    /// - Parameters:
    ///   - order: the user's priority list; kinds missing from it rank last in declaration order.
    ///   - compactKinds: kinds allowed on the compact island at all.
    ///   - limit: how many share the compact island; `nil` means unlimited, values below 1 mean 1.
    ///
    /// Ties within a kind go to higher relevance, then to whichever started first
    /// (Apple's rule for Live Activities), then by id for a stable order.
    public static func rank(_ activities: [Activity], order: [ActivityKind], compactKinds: Set<ActivityKind>, limit: Int?) -> RankedActivities {
        let fallback = ActivityKind.allCases
        func index(_ k: ActivityKind) -> Int {
            if let i = order.firstIndex(of: k) { return i }
            return order.count + (fallback.firstIndex(of: k) ?? 0)
        }
        let sorted = activities
            .filter { compactKinds.contains($0.kind) }
            .sorted { a, b in
                let ia = index(a.kind), ib = index(b.kind)
                if ia != ib { return ia < ib }
                if a.relevance != b.relevance { return a.relevance > b.relevance }
                if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
                return a.id < b.id
            }
        let n = limit.map { max(1, $0) } ?? sorted.count
        return RankedActivities(visible: Array(sorted.prefix(n)), overflow: Array(sorted.dropFirst(n)))
    }
}
