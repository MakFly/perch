import AppKit

/// Where the notch is — or, on hardware without one, where we pretend it is.
struct NotchGeometry: Equatable {
    /// Physical size of the notch cutout, in points.
    var size: CGSize
    /// Screen-space rect of the cutout.
    var rect: CGRect
    /// False on external displays and pre-2021 hardware, where we float instead.
    var hasNotch: Bool

    /// Fallback used when a screen reports no safe-area inset. Roughly matches the
    /// cutout on 14"/16" MacBook Pros so the UI keeps the same proportions.
    static let syntheticSize = CGSize(width: 190, height: 32)

    /// Applies the user's tuning. The macOS API is right on every Mac this has been
    /// measured on and wrong on some it has not, so the adjustment exists — but zero,
    /// meaning "trust the API", stays the default.
    func adjusted(width: Double, height: Double) -> NotchGeometry {
        guard width != 0 || height != 0 else { return self }
        var copy = self
        copy.size = CGSize(
            width: max(40, size.width + width), height: max(8, size.height + height))
        // Grow around the centre, so a wider notch stays over the cutout.
        copy.rect = CGRect(
            x: rect.midX - copy.size.width / 2,
            y: rect.maxY - copy.size.height,
            width: copy.size.width,
            height: copy.size.height)
        return copy
    }

    static func detect(on screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let insetTop = screen.safeAreaInsets.top

        // `auxiliaryTopLeftArea` is the usable menu-bar strip left of the cutout; the gap
        // between the two auxiliary areas *is* the notch.
        if insetTop > 0,
            let left = screen.auxiliaryTopLeftArea,
            let right = screen.auxiliaryTopRightArea
        {
            let width = frame.width - left.width - right.width
            if width > 0 {
                let size = CGSize(width: width, height: insetTop)
                let rect = CGRect(
                    x: frame.minX + left.width,
                    y: frame.maxY - insetTop,
                    width: width,
                    height: insetTop
                )
                return NotchGeometry(size: size, rect: rect, hasNotch: true)
            }
        }

        let size = syntheticSize
        let rect = CGRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        return NotchGeometry(size: size, rect: rect, hasNotch: false)
    }

    /// Frame for a panel of `size`, centred on the notch and hanging below it.
    func panelFrame(for size: CGSize, on screen: NSScreen) -> CGRect {
        let x = rect.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        // Keep the panel on-screen if the notch sits near an edge (external display).
        let clampedX = min(max(x, screen.frame.minX), screen.frame.maxX - size.width)
        return CGRect(x: clampedX, y: y, width: size.width, height: size.height)
    }
}
