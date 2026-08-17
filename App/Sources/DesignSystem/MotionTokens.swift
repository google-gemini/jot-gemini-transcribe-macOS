import SwiftUI

/// M3 motion tokens mapped to SwiftUI springs (response ≈ 2π/√stiffness,
/// dampingFraction = M3 damping ratio). Contract: docs/design/experience.md §0.
///
/// Hard rules:
///  - SPATIAL springs move/resize/morph things (overshoot allowed).
///  - EFFECTS springs (damping 1.0) fade/recolor things — NEVER bounce opacity or color.
///  - Expressive springs are reserved for hero moments: pill appear, lock, success,
///    onboarding celebration.
enum GTMotion {
    // Standard spatial (damping 0.9 / stiffness 1400·700·300)
    static let fastSpatial = Animation.spring(response: 0.17, dampingFraction: 0.9)
    static let defaultSpatial = Animation.spring(response: 0.24, dampingFraction: 0.9)
    static let slowSpatial = Animation.spring(response: 0.36, dampingFraction: 0.9)

    // Effects (damping 1.0 / stiffness 3800·1600·800) — fades & color, no bounce
    static let fastEffects = Animation.spring(response: 0.10, dampingFraction: 1.0)
    static let defaultEffects = Animation.spring(response: 0.16, dampingFraction: 1.0)
    static let slowEffects = Animation.spring(response: 0.22, dampingFraction: 1.0)

    // M3 Expressive spatial (visible overshoot; hero moments only)
    static let expressiveFastSpatial = Animation.spring(response: 0.22, dampingFraction: 0.6)
    static let expressiveDefaultSpatial = Animation.spring(response: 0.32, dampingFraction: 0.8)
    static let expressiveSlowSpatial = Animation.spring(response: 0.44, dampingFraction: 0.8)

    // Bezier tokens for non-spring cases
    /// Enters: 250–400ms.
    static func emphasizedDecelerate(_ duration: Double = 0.3) -> Animation {
        .timingCurve(0.05, 0.7, 0.1, 1.0, duration: duration)
    }
    /// Exits: 150–200ms.
    static func emphasizedAccelerate(_ duration: Double = 0.15) -> Animation {
        .timingCurve(0.3, 0.0, 0.8, 0.15, duration: duration)
    }

    // Durations (md.sys.motion.duration)
    enum Duration {
        static let short1 = 0.05, short2 = 0.1, short3 = 0.15, short4 = 0.2
        static let medium1 = 0.25, medium2 = 0.3, medium3 = 0.35, medium4 = 0.4
        static let long1 = 0.45, long2 = 0.5, long3 = 0.55, long4 = 0.6
    }
}
