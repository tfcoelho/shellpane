import Foundation

/// How the window's panes are arranged: a pane, or a row or column of smaller layouts with their sizes.
/// Every change splits or closes a pane, as in VS Code, so any arrangement comes from the same few moves.
public indirect enum PaneLayout: Equatable, Sendable, Codable {
    /// `row`: side by side. `column`: stacked.
    public enum Axis: String, Sendable, Codable { case row, column }

    public enum Edge: String, Sendable, Codable, CaseIterable {
        case left, right, top, bottom

        public var axis: Axis { self == .left || self == .right ? .row : .column }
        /// Whether something placed at this edge comes first in its row or column.
        public var isLeading: Bool { self == .left || self == .top }
    }

    /// The arrangements in View › Layout.
    public enum Preset: String, Sendable, CaseIterable {
        case sideBySide, stacked, twoOverOne, oneOverTwo, threeColumns, fourInARow, grid, threeOverTwo, threeOverThree

        public var paneCount: Int {
            switch self {
            case .sideBySide, .stacked: 2
            case .twoOverOne, .oneOverTwo, .threeColumns: 3
            case .fourInARow, .grid: 4
            case .threeOverTwo: 5
            case .threeOverThree: 6
            }
        }

        public var title: String {
            switch self {
            case .sideBySide: "Two Side by Side"
            case .stacked: "Two Stacked"
            case .twoOverOne: "Two on Top, One Below"
            case .oneOverTwo: "One on Top, Two Below"
            case .threeColumns: "Three Columns"
            case .fourInARow: "Four in a Row"
            case .grid: "Grid of Four"
            case .threeOverTwo: "Three on Top, Two Below"
            case .threeOverThree: "Grid of Six"
            }
        }

        /// This arrangement with these panes. Needs `paneCount` ids.
        public func layout(_ ids: [UUID]) -> PaneLayout {
            precondition(ids.count >= paneCount)
            func row(_ i: [Int]) -> PaneLayout { .even(.row, i.map { .pane(ids[$0]) }) }
            switch self {
            case .sideBySide: return row([0, 1])
            case .stacked: return .even(.column, [.pane(ids[0]), .pane(ids[1])])
            case .twoOverOne: return .even(.column, [row([0, 1]), .pane(ids[2])])
            case .oneOverTwo: return .even(.column, [.pane(ids[0]), row([1, 2])])
            case .threeColumns: return row([0, 1, 2])
            case .fourInARow: return row([0, 1, 2, 3])
            case .grid: return .even(.column, [row([0, 1]), row([2, 3])])
            case .threeOverTwo: return .even(.column, [row([0, 1, 2]), row([3, 4])])
            case .threeOverThree: return .even(.column, [row([0, 1, 2]), row([3, 4, 5])])
            }
        }
    }

    /// The most panes a window holds.
    public static let maxPanes = 6

    case pane(UUID)
    /// `sizes` are each child's share of the split, adding up to 1.
    case split(Axis, [PaneLayout], sizes: [Double])

    static func even(_ axis: Axis, _ children: [PaneLayout]) -> PaneLayout {
        .split(axis, children, sizes: Array(repeating: 1 / Double(children.count), count: children.count))
    }

    /// The panes in reading order: left to right, top to bottom.
    public var paneIDs: [UUID] {
        switch self {
        case let .pane(id): [id]
        case let .split(_, children, _): children.flatMap(\.paneIDs)
        }
    }

    public func contains(_ id: UUID) -> Bool { paneIDs.contains(id) }

    /// A new pane beside `target`. Taking half of the target's space, as a split does.
    public func inserting(_ new: UUID, beside target: UUID, at edge: Edge) -> PaneLayout {
        switch self {
        case .pane(target):
            return .even(edge.axis, edge.isLeading ? [.pane(new), self] : [self, .pane(new)])
        case .pane:
            return self
        case let .split(axis, children, sizes):
            if axis == edge.axis, let i = children.firstIndex(of: .pane(target)) {
                var c = children, s = sizes
                s[i] /= 2
                let at = edge.isLeading ? i : i + 1
                c.insert(.pane(new), at: at)
                s.insert(s[i], at: at)
                return .split(axis, c, sizes: s)
            }
            return .split(axis, children.map { $0.inserting(new, beside: target, at: edge) }, sizes: sizes)
        }
    }

    /// A new pane along a whole side of the layout, taking its fair share: a bottom edge across the full width.
    public func inserting(_ new: UUID, atOuter edge: Edge) -> PaneLayout {
        if case let .split(axis, children, sizes) = self, axis == edge.axis {
            let share = 1 / Double(children.count + 1)
            var s = sizes.map { $0 * (1 - share) }, c = children
            s.insert(share, at: edge.isLeading ? 0 : s.count)
            c.insert(.pane(new), at: edge.isLeading ? 0 : c.count)
            return .split(axis, c, sizes: s)
        }
        return .even(edge.axis, edge.isLeading ? [.pane(new), self] : [self, .pane(new)])
    }

    /// Without this pane; its neighbours take over its space. nil when it was the last one.
    public func removing(_ id: UUID) -> PaneLayout? {
        switch self {
        case let .pane(own):
            return own == id ? nil : self
        case let .split(axis, children, sizes):
            var kept: [PaneLayout] = [], keptSizes: [Double] = []
            for (child, size) in zip(children, sizes) {
                guard let left = child.removing(id) else { continue }
                // A child that collapsed into the same direction as this split joins it.
                if case let .split(a, inner, innerSizes) = left, a == axis {
                    kept += inner
                    keptSizes += innerSizes.map { $0 * size }
                } else {
                    kept.append(left)
                    keptSizes.append(size)
                }
            }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0] }
            let total = keptSizes.reduce(0, +)
            return .split(axis, kept, sizes: keptSizes.map { $0 / total })
        }
    }

    /// Moves a pane beside another one. Unchanged if it's the same pane or either isn't here.
    public func moving(_ id: UUID, beside target: UUID, at edge: Edge) -> PaneLayout {
        guard id != target, contains(id), contains(target), let rest = removing(id) else { return self }
        return rest.inserting(id, beside: target, at: edge)
    }

    /// Moves a pane to a whole side of the layout. Unchanged if it's the only pane.
    public func moving(_ id: UUID, toOuter edge: Edge) -> PaneLayout {
        guard contains(id), let rest = removing(id) else { return self }
        return rest.inserting(id, atOuter: edge)
    }

    /// The least space this layout needs, with every pane at its minimum.
    public func minimumSize(paneWidth: Double, paneHeight: Double, divider: Double = 1) -> (width: Double, height: Double) {
        switch self {
        case .pane:
            return (paneWidth, paneHeight)
        case let .split(axis, children, _):
            let sizes = children.map { $0.minimumSize(paneWidth: paneWidth, paneHeight: paneHeight, divider: divider) }
            let gaps = divider * Double(children.count - 1)
            switch axis {
            case .row: return (sizes.map(\.width).reduce(0, +) + gaps, sizes.map(\.height).max() ?? 0)
            case .column: return (sizes.map(\.width).max() ?? 0, sizes.map(\.height).reduce(0, +) + gaps)
            }
        }
    }
}
