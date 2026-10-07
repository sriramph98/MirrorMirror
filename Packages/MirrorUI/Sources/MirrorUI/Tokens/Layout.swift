import SwiftUI

/// 4-point spacing scale.
public enum Space {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
}

/// Corner radii. Always applied as continuous ("squircle") corners.
public enum Radius {
    /// Badges like AUTO and •REC.
    public static let badge: CGFloat = 6
    /// Chips, list thumbnails.
    public static let chip: CGFloat = 10
    /// Buttons and inner groups.
    public static let control: CGFloat = 14
    /// Panels and cards.
    public static let panel: CGFloat = 22
    /// The live video frame.
    public static let viewfinder: CGFloat = 26
    /// Sheets and the deck behind camera controls.
    public static let deck: CGFloat = 32
}

/// Fixed control sizes (all at least the 44 pt hit target).
public enum ControlSize {
    public static let tool: CGFloat = 44
    public static let toolLarge: CGFloat = 52
    public static let shutter: CGFloat = 76
    public static let thumbnail: CGFloat = 52
    /// Comfortable reading width for forms and lists on iPad.
    public static let readableWidth: CGFloat = 640
}

public extension Shape where Self == RoundedRectangle {
    static func continuous(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// Motion tokens: quick and mechanical, never bouncy.
public enum Motion {
    public static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
    public static let smooth = Animation.spring(response: 0.42, dampingFraction: 0.9)
    public static let fade = Animation.easeOut(duration: 0.2)
    /// LEDs and REC dots.
    public static let pulse = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
}
