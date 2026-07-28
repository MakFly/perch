import CoreGraphics
import Testing

@testable import PerchKit

@Suite("Idle strip")
struct IdleStripTests {
    /// A strip as the controller builds one: 200pt of cutout, 204pt of shoulder each side,
    /// and 10pt taller than the 32pt cutout so its rounded bottom shows below the bezel.
    private let strip = CGRect(x: 300, y: 900, width: 608, height: 42)
    private let contentHeight: CGFloat = 32

    @Test("both icons sit inside the strip, at its trailing edge")
    func insideTheStrip() {
        let (mute, settings) = IdleStrip.hotspots(in: strip, contentHeight: contentHeight)

        #expect(strip.contains(mute))
        #expect(strip.contains(settings))
        #expect(settings.maxX == strip.maxX)
    }

    @Test("they do not overlap, and sit in that order")
    func sideBySide() {
        let (mute, settings) = IdleStrip.hotspots(in: strip, contentHeight: contentHeight)

        #expect(mute.maxX < settings.minX)
        #expect(settings.minX - mute.maxX == IdleStrip.iconSpacing)
    }

    @Test("they are centred in the cutout, not in the window")
    func centredInTheContentBand() {
        // The window is taller than the cutout. Centring in it would put both icons 5pt
        // low — half off the band they are drawn in, and half onto the rounded skirt.
        let (mute, _) = IdleStrip.hotspots(in: strip, contentHeight: contentHeight)
        let band = CGRect(
            x: strip.minX, y: strip.maxY - contentHeight, width: strip.width,
            height: contentHeight)

        #expect(mute.midY == band.midY)
        #expect(mute.midY != strip.midY)
    }

    @Test("a click lands on the icon under it")
    func clicksHitWhatTheyLookAt() {
        let (mute, settings) = IdleStrip.hotspots(in: strip, contentHeight: contentHeight)

        #expect(mute.contains(CGPoint(x: mute.midX, y: mute.midY)))
        #expect(!mute.contains(CGPoint(x: settings.midX, y: settings.midY)))
        // Between them is neither, and falls through to opening the panel.
        let between = CGPoint(x: (mute.maxX + settings.minX) / 2, y: mute.midY)
        #expect(!mute.contains(between) && !settings.contains(between))
    }
}
