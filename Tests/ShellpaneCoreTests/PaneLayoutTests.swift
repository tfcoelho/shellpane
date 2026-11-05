import Foundation
import ShellpaneCore
import Testing

@Suite struct PaneLayoutTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID(), f = UUID()

    private func close(_ x: [Double], _ y: [Double]) -> Bool {
        x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) < 0.0001 }
    }

    @Test func splittingAPaneTakesHalfItsSpace() {
        let two = PaneLayout.pane(a).inserting(b, beside: a, at: .right)
        #expect(two == .split(.row, [.pane(a), .pane(b)], sizes: [0.5, 0.5]))
        let three = two.inserting(c, beside: b, at: .right)
        #expect(three == .split(.row, [.pane(a), .pane(b), .pane(c)], sizes: [0.5, 0.25, 0.25]))
    }

    @Test func splittingTheOtherWayNests() {
        let l = PaneLayout.Preset.sideBySide.layout([a, b]).inserting(c, beside: b, at: .bottom)
        #expect(l == .split(.row, [.pane(a), .split(.column, [.pane(b), .pane(c)], sizes: [0.5, 0.5])], sizes: [0.5, 0.5]))
    }

    @Test func leadingEdgesComeFirst() {
        #expect(PaneLayout.pane(a).inserting(b, beside: a, at: .left).paneIDs == [b, a])
        #expect(PaneLayout.pane(a).inserting(b, beside: a, at: .top).paneIDs == [b, a])
    }

    @Test func anOuterEdgeSpansTheWholeLayout() {
        // Two on top, one across the bottom.
        let l = PaneLayout.Preset.sideBySide.layout([a, b]).inserting(c, atOuter: .bottom)
        #expect(l == .even2(.column, .split(.row, [.pane(a), .pane(b)], sizes: [0.5, 0.5]), .pane(c)))
        guard case let .split(_, _, sizes) = PaneLayout.Preset.threeColumns.layout([a, b, c]).inserting(d, atOuter: .right) else {
            Issue.record("expected a split"); return
        }
        #expect(close(sizes, [0.25, 0.25, 0.25, 0.25]))
    }

    @Test func removingGivesTheSpaceBack() {
        let three = PaneLayout.Preset.sideBySide.layout([a, b]).inserting(c, beside: b, at: .right)
        guard case let .split(_, _, sizes)? = three.removing(c) else { Issue.record("expected a split"); return }
        #expect(close(sizes, [2.0 / 3, 1.0 / 3]))
        #expect(PaneLayout.pane(a).removing(a) == nil)
        #expect(PaneLayout.Preset.sideBySide.layout([a, b]).removing(a) == .pane(b))
    }

    @Test func aCollapsedSplitJoinsItsParent() {
        // [a | (b over (c | d))] without b: c and d join a's row.
        let l = PaneLayout.split(.row, [.pane(a), .split(.column, [.pane(b), .split(.row, [.pane(c), .pane(d)], sizes: [0.5, 0.5])], sizes: [0.5, 0.5])], sizes: [0.5, 0.5])
        guard case let .split(axis, children, sizes)? = l.removing(b) else { Issue.record("expected a split"); return }
        #expect(axis == .row)
        #expect(children == [.pane(a), .pane(c), .pane(d)])
        #expect(close(sizes, [0.5, 0.25, 0.25]))
    }

    @Test func movingRearranges() {
        let l = PaneLayout.Preset.threeColumns.layout([a, b, c]).moving(a, toOuter: .bottom)
        #expect(l.paneIDs == [b, c, a])
        if case let .split(axis, children, _) = l {
            #expect(axis == .column)
            #expect(children.count == 2)
        } else { Issue.record("expected a column") }
        let beside = PaneLayout.Preset.threeColumns.layout([a, b, c]).moving(c, beside: a, at: .left)
        #expect(beside.paneIDs == [c, a, b])
    }

    @Test func movingOntoItselfOrAloneChangesNothing() {
        let two = PaneLayout.Preset.sideBySide.layout([a, b])
        #expect(two.moving(a, beside: a, at: .left) == two)
        #expect(PaneLayout.pane(a).moving(a, toOuter: .left) == .pane(a))
        #expect(two.moving(c, beside: a, at: .left) == two)
    }

    @Test func presetsHaveTheirPanesInReadingOrder() {
        for preset in PaneLayout.Preset.allCases {
            let ids = Array([a, b, c, d, e, f].prefix(preset.paneCount))
            #expect(preset.layout(ids).paneIDs == ids, "\(preset)")
        }
    }

    @Test func minimumSizeAddsAlongTheSplit() {
        let row = PaneLayout.Preset.fourInARow.layout([a, b, c, d]).minimumSize(paneWidth: 220, paneHeight: 180)
        #expect(row.width == 883)
        #expect(row.height == 180)
        let grid = PaneLayout.Preset.grid.layout([a, b, c, d]).minimumSize(paneWidth: 220, paneHeight: 180)
        #expect(grid.width == 441)
        #expect(grid.height == 361)
    }

    @Test func noPresetAsksForMoreThanTheLimit() {
        #expect(PaneLayout.Preset.allCases.allSatisfy { $0.paneCount <= PaneLayout.maxPanes })
    }

    @Test func aLayoutSurvivesSavingAndLoading() throws {
        let l = PaneLayout.Preset.twoOverOne.layout([a, b, c])
        let saved = try JSONEncoder().encode(l)
        #expect(try JSONDecoder().decode(PaneLayout.self, from: saved) == l)
    }
}

private extension PaneLayout {
    static func even2(_ axis: Axis, _ x: PaneLayout, _ y: PaneLayout) -> PaneLayout { .split(axis, [x, y], sizes: [0.5, 0.5]) }
}
