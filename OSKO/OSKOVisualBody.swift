//
//  OSKOVisualBody.swift
//  OSKO
//

import AppKit
import Foundation
import SwiftUI

/// Slightly asymmetric organic-technological silhouette for OSKO (Character Bible §4 & §9).
/// Keeps a single compact, rounded volume with subtle asymmetry and high fill solidity,
/// maintaining the exact same silhouette across all emotional states.
nonisolated struct OSKOBodyShape: Shape, Sendable, Equatable {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        let w = rect.width
        let h = rect.height
        let minX = rect.minX
        let minY = rect.minY

        func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: minX + nx * w, y: minY + ny * h)
        }

        // Start at top-center-left and trace a smooth, slightly asymmetric organic contour clockwise.
        // Right side has a slightly higher shoulder / fuller curve than the left side, producing
        // a subtle horizontal mirror asymmetry ratio around ~0.07–0.11 while keeping solidity > 0.78.
        path.move(to: pt(0.46, 0.03))

        // Top-right shoulder
        path.addCurve(
            to: pt(0.97, 0.44),
            control1: pt(0.77, 0.01),
            control2: pt(0.98, 0.16)
        )

        // Bottom-right lobe
        path.addCurve(
            to: pt(0.53, 0.97),
            control1: pt(0.96, 0.77),
            control2: pt(0.81, 0.98)
        )

        // Bottom-left base (slightly tucked inward for organic asymmetry)
        path.addCurve(
            to: pt(0.04, 0.56),
            control1: pt(0.24, 0.96),
            control2: pt(0.05, 0.84)
        )

        // Top-left curve back to start
        path.addCurve(
            to: pt(0.46, 0.03),
            control1: pt(0.03, 0.25),
            control2: pt(0.18, 0.05)
        )

        path.closeSubpath()
        return path
    }
}

/// Pure coordinate math and state tracker for OSKO's global cursor gaze and subtle floating motion.
nonisolated enum OSKOGazeMath {
    static let maxHorizontalOffset: CGFloat = 3.2
    static let maxVerticalOffset: CGFloat = 2.0
    static let fullDeflectionDistance: CGFloat = 360.0

    /// Returns the emotion-specific gaze amplitude scale (still/restrained during rest or deep concentration).
    static func emotionAmplitudeScale(for emotion: OSKOEmotion, isThinking: Bool) -> CGFloat {
        if isThinking {
            return 0.35
        }
        switch emotion {
        case .sleepy:
            return 0.22
        case .concentration:
            return 0.45
        case .idle, .empathy:
            return 0.85
        case .curious, .enthusiasm, .mischief, .surprise, .annoyed:
            return 1.0
        }
    }

    /// Maps a global screen cursor position (`NSEvent.mouseLocation`, bottom-left AppKit screen coordinates)
    /// relative to OSKO's body center in screen coordinates into a smooth, bounded SwiftUI eye offset (`CGSize`).
    /// Note: In AppKit screen coordinates, `+Y` is up; in SwiftUI view offsets, `+height` is down.
    static func targetEyeOffset(
        cursorScreenPoint: NSPoint,
        bodyScreenCenter: NSPoint,
        emotion: OSKOEmotion = .idle,
        isThinking: Bool = false
    ) -> CGSize {
        let dx = cursorScreenPoint.x - bodyScreenCenter.x
        let dy = cursorScreenPoint.y - bodyScreenCenter.y
        let distance = hypot(dx, dy)
        guard distance > 0.0001 else {
            return .zero
        }

        let unitX = dx / distance
        // Invert Y from AppKit screen space (+Y up) to SwiftUI offset space (+Y down)
        let unitY = -dy / distance

        // Smooth non-linear saturation curve (`tanh`-like response)
        let normalizedMagnitude = min(1.0, distance / fullDeflectionDistance)
        let curvedMagnitude = normalizedMagnitude * (2.0 - normalizedMagnitude)
        let scale = emotionAmplitudeScale(for: emotion, isThinking: isThinking)

        let rawWidth = unitX * curvedMagnitude * maxHorizontalOffset * scale
        let rawHeight = unitY * curvedMagnitude * maxVerticalOffset * scale

        let clampedWidth = min(max(rawWidth, -maxHorizontalOffset), maxHorizontalOffset)
        let clampedHeight = min(max(rawHeight, -maxVerticalOffset), maxVerticalOffset)

        return CGSize(width: clampedWidth, height: clampedHeight)
    }

    /// Linearly interpolates between current and target eye offsets for smooth, jitter-free tracking.
    static func interpolateOffset(
        current: CGSize,
        target: CGSize,
        smoothingFactor: CGFloat = 0.28,
        deadband: CGFloat = 0.02
    ) -> CGSize {
        let clampedFactor = min(max(smoothingFactor, 0.01), 1.0)
        let nextWidth = current.width + (target.width - current.width) * clampedFactor
        let nextHeight = current.height + (target.height - current.height) * clampedFactor

        let finalWidth = abs(target.width - nextWidth) < deadband ? target.width : nextWidth
        let finalHeight = abs(target.height - nextHeight) < deadband ? target.height : nextHeight

        return CGSize(
            width: min(max(finalWidth, -maxHorizontalOffset), maxHorizontalOffset),
            height: min(max(finalHeight, -maxVerticalOffset), maxVerticalOffset)
        )
    }

    /// Computes a subtle, irregular floating offset and slight body tilt for a given elapsed time (`TimeInterval`).
    /// Respects Character Bible §4–5 stillness restraint during concentration and rest.
    static func floatingPose(
        at time: TimeInterval,
        emotion: OSKOEmotion,
        isThinking: Bool
    ) -> (offset: CGSize, tiltDegrees: Double) {
        let amplitude: CGFloat
        let tiltScale: Double

        if isThinking {
            amplitude = 0.25
            tiltScale = 0.3
        } else {
            switch emotion {
            case .sleepy:
                amplitude = 0.15
                tiltScale = 0.15
            case .concentration:
                amplitude = 0.30
                tiltScale = 0.35
            case .enthusiasm:
                amplitude = 1.65
                tiltScale = 1.25
            case .curious, .mischief:
                amplitude = 1.25
                tiltScale = 1.35
            case .surprise:
                amplitude = 1.40
                tiltScale = 1.0
            case .idle, .empathy, .annoyed:
                amplitude = 1.15
                tiltScale = 0.85
            }
        }

        // Superposition of two incommensurate low-frequency waves for organic, non-mechanical motion
        let vertical = (sin(time * 1.9) * 0.7 + sin(time * 3.1 + 0.8) * 0.3) * Double(amplitude)
        let horizontal = (cos(time * 1.3 + 0.4) * 0.65 + sin(time * 2.3) * 0.35) * Double(amplitude * 0.55)
        let tilt = (sin(time * 1.45 + 0.2) * 1.1) * tiltScale

        return (
            offset: CGSize(width: horizontal, height: vertical),
            tiltDegrees: tilt
        )
    }
}
