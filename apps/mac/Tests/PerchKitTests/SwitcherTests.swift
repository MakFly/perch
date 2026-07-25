import Foundation
import Testing

@testable import PerchKit

/// A tap opens the switcher on the current session and leaves it up to pick from.
@Test func tappingOpensAndStays() {
    var switcher = SessionSwitcher(count: 3)

    #expect(switcher.handle(.shortcutPressed(reverse: false)) == .open)
    #expect(switcher.index == 0)
    // Released without ever advancing: this was a tap, so nothing is jumped to.
    #expect(switcher.handle(.modifierReleased) == .nothing)
    #expect(switcher.isOpen)
}

/// Holding and pressing again is ⌘Tab: each press advances, the release jumps.
@Test func holdingCyclesAndReleasingJumps() {
    var switcher = SessionSwitcher(count: 3)

    _ = switcher.handle(.shortcutPressed(reverse: false))
    #expect(switcher.handle(.shortcutPressed(reverse: false)) == .moved)
    #expect(switcher.index == 1)
    #expect(switcher.handle(.shortcutPressed(reverse: false)) == .moved)
    #expect(switcher.index == 2)

    #expect(switcher.handle(.modifierReleased) == .jump(index: 2))
    #expect(!switcher.isOpen)
}

@Test func shiftCyclesBackwardsAndWraps() {
    var switcher = SessionSwitcher(count: 3)
    _ = switcher.handle(.shortcutPressed(reverse: false))

    #expect(switcher.handle(.shortcutPressed(reverse: true)) == .moved)
    // Wrapped past the start rather than sticking at zero.
    #expect(switcher.index == 2)
}

@Test func forwardCyclingWrapsToo() {
    var switcher = SessionSwitcher(count: 2)
    _ = switcher.handle(.shortcutPressed(reverse: false))
    _ = switcher.handle(.shortcutPressed(reverse: false))
    _ = switcher.handle(.shortcutPressed(reverse: false))

    #expect(switcher.index == 0)
}

@Test func arrowsPickWithoutCycling() {
    var switcher = SessionSwitcher(count: 3)
    _ = switcher.handle(.shortcutPressed(reverse: false))
    _ = switcher.handle(.modifierReleased)

    #expect(switcher.handle(.arrow(down: true)) == .moved)
    #expect(switcher.index == 1)
    #expect(switcher.handle(.confirmed) == .jump(index: 1))
    #expect(!switcher.isOpen)
}

@Test func escapeClosesWithoutJumping() {
    var switcher = SessionSwitcher(count: 3)
    _ = switcher.handle(.shortcutPressed(reverse: false))

    #expect(switcher.handle(.cancelled) == .close)
    #expect(!switcher.isOpen)
}

/// Opening an empty switcher just to close it is worse than not reacting at all.
@Test func withNoSessionsTheShortcutDoesNothing() {
    var switcher = SessionSwitcher(count: 0)

    #expect(switcher.handle(.shortcutPressed(reverse: false)) == .nothing)
    #expect(!switcher.isOpen)
}

@Test func eventsWhileClosedAreIgnored() {
    var switcher = SessionSwitcher(count: 3)

    #expect(switcher.handle(.arrow(down: true)) == .nothing)
    #expect(switcher.handle(.confirmed) == .nothing)
    #expect(switcher.handle(.modifierReleased) == .nothing)
}

/// A session can end while the switcher is open.
@Test func theSelectionSurvivesTheListShrinking() {
    var switcher = SessionSwitcher(count: 3)
    _ = switcher.handle(.shortcutPressed(reverse: false))
    _ = switcher.handle(.shortcutPressed(reverse: false))
    _ = switcher.handle(.shortcutPressed(reverse: false))
    #expect(switcher.index == 2)

    switcher.count = 2
    switcher.clamp()
    #expect(switcher.index == 1)

    switcher.count = 0
    switcher.clamp()
    #expect(!switcher.isOpen)
    #expect(switcher.index == 0)
}
