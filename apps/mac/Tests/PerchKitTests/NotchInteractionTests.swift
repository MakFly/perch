import CoreGraphics
import Testing

@testable import PerchKit

// MARK: - Regressions
//
// Both of these shipped and were caught by using the app, not by reading the code. They
// are first in the file on purpose.

/// BUG: the panel stayed open forever once clicked — moving the cursor away did nothing,
/// because the hover-out case for `.expanded` was simply missing.
@Test func expandedPanelClosesWhenTheCursorLeaves() {
    var notch = NotchInteraction()
    notch.handle(.hoverEntered)
    notch.handle(.tappedNotch)
    #expect(notch.state == .expanded)

    let effects = notch.handle(.hoverExited)
    #expect(effects == [.scheduleCollapse(milliseconds: NotchInteraction.expandedGrace)])

    notch.handle(.collapseTimerFired)
    #expect(notch.state == .idle)
}

/// BUG: a click anywhere inside the panel collapsed it, so interacting with the panel
/// dismissed it. Once expanded, a body click must be inert — it belongs to the control
/// that was hit.
@Test func clickingInsideTheExpandedPanelDoesNotCloseIt() {
    var notch = NotchInteraction()
    notch.handle(.hoverEntered)
    notch.handle(.tappedNotch)
    #expect(notch.state == .expanded)

    #expect(notch.handle(.tappedBody).isEmpty)
    #expect(notch.state == .expanded)
}

/// BUG: after the fix above, the peek became a dead end — its body was inert and the only
/// way in was a 32pt strip. A peek has no controls, so its whole surface opens the panel.
@Test func clickingThePeekBodyOpensThePanel() {
    var notch = NotchInteraction()
    notch.handle(.hoverEntered)
    #expect(notch.state == .peek)

    notch.handle(.tappedBody)
    #expect(notch.state == .expanded)
}

@Test func bodyClicksDoNothingWhenIdleOrAlerting() {
    var idle = NotchInteraction()
    #expect(idle.handle(.tappedBody).isEmpty)
    #expect(idle.state == .idle)

    var alerting = NotchInteraction()
    alerting.handle(.permissionArrived)
    alerting.handle(.tappedBody)
    #expect(alerting.state == .alert)
}

/// The cutout must go back to looking like hardware, so idle draws nothing at all and is
/// never wider than the notch. A panel a few points wider paints black shoulders.
@Test func idleDrawsNothingAndNeverExceedsTheCutoutWidth() {
    #expect(!NotchState.idle.drawsPanel)
    #expect(NotchState.peek.drawsPanel)
    #expect(NotchState.expanded.drawsPanel)
    #expect(NotchState.alert.drawsPanel)

    let notch = CGSize(width: 185, height: 32)
    #expect(NotchState.idle.size(notch: notch).width == notch.width)
    for state in NotchState.allCases where state != .idle {
        #expect(state.size(notch: notch).width >= notch.width)
    }
}

/// The window is set to this once and never resized, so anything it fails to contain is
/// content clipped mid-animation with no way to notice from the code.
@Test func theCanvasContainsEveryStateItHasToHold() {
    let notch = CGSize(width: 185, height: 32)
    let canvas = NotchState.canvas(notch: notch)

    for state in NotchState.allCases {
        let size = state.size(notch: notch, flank: 40)
        // The shoulders are drawn past the panel's own edge, so the canvas has to hold
        // them too — a curve outside the window is a corner that comes out square.
        #expect(size.width + NotchState.shoulder * 2 <= canvas.width)
        #expect(size.height <= canvas.height)
    }

    // The widest thing Perch ever draws is a plan card: `AppModel` adds 140pt to the alert
    // for it. Shoulders included, it still has to fit.
    let widestAlert = NotchState.alert.size(notch: notch).width + 140
    #expect(widestAlert + NotchState.shoulder * 2 <= canvas.width)

    // An alert is the one state that grows past its own size: `AppModel` adds room for the
    // card's options on top of it. Four options — more than Claude Code ever asks — is
    // 4 × 44 + 40.
    let tallestAlert = NotchState.alert.size(notch: notch).height + 4 * 44 + 40
    #expect(tallestAlert <= canvas.height)
}

// MARK: - Flash

@Test func newsFlashesFromRestAndTakesItselfBack() {
    var notch = NotchInteraction()
    let effects = notch.handle(.flashRequested)

    #expect(notch.state == .flash)
    #expect(effects == [.scheduleCollapse(milliseconds: NotchInteraction.flashGrace)])

    notch.handle(.collapseTimerFired)
    #expect(notch.state == .idle)
}

/// A flash is news, not a question — so it loses to anything someone is already reading.
@Test func aFlashNeverTakesAPanelSomeoneIsUsing() {
    for state in [NotchState.peek, .expanded, .alert] {
        var notch = NotchInteraction(state: state)
        notch.handle(.flashRequested)
        #expect(notch.state == state)
    }
}

@Test func reachingForAFlashOpensThePeekAndKillsItsTimer() {
    var notch = NotchInteraction(state: .flash)
    let effects = notch.handle(.hoverEntered)

    #expect(notch.state == .peek)
    // Without this the peek someone just opened closes under the cursor two seconds later.
    #expect(effects == [.cancelCollapse])
}

/// A cursor that merely passed by must not restart the clock on news nobody read.
@Test func aCursorLeavingAFlashSchedulesNothing() {
    var notch = NotchInteraction(state: .flash)
    #expect(notch.handle(.hoverExited).isEmpty)
    #expect(notch.state == .flash)
}

@Test func aPermissionOutranksAFlash() {
    var notch = NotchInteraction(state: .flash)
    notch.handle(.permissionArrived)
    #expect(notch.state == .alert)
}

// MARK: - Hover

@Test func hoveringTheNotchOpensThePeek() {
    var notch = NotchInteraction()
    notch.handle(.hoverEntered)
    #expect(notch.state == .peek)
}

@Test func peekClosesAfterTheGracePeriod() {
    var notch = NotchInteraction()
    notch.handle(.hoverEntered)

    let effects = notch.handle(.hoverExited)
    #expect(effects == [.scheduleCollapse(milliseconds: NotchInteraction.peekGrace)])
    // Still open until the timer actually fires — that grace is what stops the flicker.
    #expect(notch.state == .peek)

    notch.handle(.collapseTimerFired)
    #expect(notch.state == .idle)
}

/// Re-entering must cancel a pending collapse, or the panel closes under the cursor.
@Test func reenteringCancelsAPendingCollapse() {
    var notch = NotchInteraction()
    notch.handle(.hoverEntered)
    notch.handle(.hoverExited)

    #expect(notch.handle(.hoverEntered) == [.cancelCollapse])
    #expect(notch.state == .peek)

    // A timer that fires after re-entry was cancelled, but prove the state survives even
    // if a stale one slips through: it must not close while the cursor is inside.
    notch.handle(.hoverEntered)
    #expect(notch.state == .peek)
}

@Test func collapseTimerIsIgnoredWhenAlreadyIdle() {
    var notch = NotchInteraction()
    notch.handle(.collapseTimerFired)
    #expect(notch.state == .idle)
}

/// A quota crossing shows itself and takes itself away. Nothing else in Perch opens the
/// panel without being asked, so the exit has to be part of the same event.
@Test func aRevealShowsThePeekAndSchedulesItsOwnExit() {
    var notch = NotchInteraction()

    let effects = notch.handle(.revealRequested)
    #expect(notch.state == .peek)
    #expect(effects == [.scheduleCollapse(milliseconds: NotchInteraction.revealGrace)])

    notch.handle(.collapseTimerFired)
    #expect(notch.state == .idle)
}

/// Hovering during a reveal cancels its exit — the peek belongs to the cursor from then on.
@Test func aRevealUnderTheCursorStaysUntilTheCursorLeaves() {
    var notch = NotchInteraction()
    notch.handle(.revealRequested)

    #expect(notch.handle(.hoverEntered) == [.cancelCollapse])
    #expect(notch.state == .peek)
    #expect(notch.handle(.hoverExited) == [.scheduleCollapse(milliseconds: NotchInteraction.peekGrace)])
}

/// It never interrupts. A panel someone opened, or a card waiting for an answer, outranks
/// a number that will still be true in a minute.
@Test func aRevealNeverTakesAPanelThatIsAlreadyOpen() {
    for state in [NotchState.peek, .expanded, .alert] {
        var notch = NotchInteraction(state: state)
        #expect(notch.handle(.revealRequested).isEmpty)
        #expect(notch.state == state)
    }
}

// MARK: - Click and keyboard

@Test func tappingTheNotchTogglesTheExpandedPanel() {
    var notch = NotchInteraction()
    notch.handle(.tappedNotch)
    #expect(notch.state == .expanded)
    notch.handle(.tappedNotch)
    #expect(notch.state == .idle)
}

@Test func escapeReturnsToTheRestingState() {
    var notch = NotchInteraction()
    notch.handle(.tappedNotch)
    notch.handle(.escapePressed)
    #expect(notch.state == .idle)
}

@Test func escapeOnIdleIsANoOp() {
    var notch = NotchInteraction()
    #expect(notch.handle(.escapePressed).isEmpty)
    #expect(notch.state == .idle)
}

// MARK: - Alerts
//
// A pending permission is a blocked Claude Code session. Nothing incidental may hide it.

@Test func permissionTakesOverFromAnyState() {
    for start in NotchState.allCases {
        var notch = NotchInteraction(state: start)
        notch.handle(.permissionArrived)
        #expect(notch.state == .alert, "from \(start)")
    }
}

@Test(arguments: [
    NotchInteraction.Event.hoverExited,
    .hoverEntered,
    .tappedNotch,
    .escapePressed,
    .collapseTimerFired,
])
func nothingButADecisionDismissesAnAlert(event: NotchInteraction.Event) {
    var notch = NotchInteraction()
    notch.handle(.permissionArrived)

    notch.handle(event)
    #expect(notch.state == .alert)
}

@Test func clearingTheQueueReturnsToIdle() {
    var notch = NotchInteraction()
    notch.handle(.permissionArrived)
    notch.handle(.permissionsCleared)
    #expect(notch.state == .idle)
}

/// A second request arriving while one is on screen must not disturb the alert.
@Test func aSecondPermissionKeepsTheAlertUp() {
    var notch = NotchInteraction()
    notch.handle(.permissionArrived)
    notch.handle(.permissionArrived)
    #expect(notch.state == .alert)
}

// MARK: - Keyboard focus

/// Focus is taken only when there is something to type into — that is what keeps Perch
/// from needing Accessibility permission.
@Test func onlyPanelsThatNeedKeysTakeFocus() {
    #expect(!NotchState.idle.wantsKeyboard)
    #expect(!NotchState.peek.wantsKeyboard)
    #expect(NotchState.expanded.wantsKeyboard)
    #expect(NotchState.alert.wantsKeyboard)
}
