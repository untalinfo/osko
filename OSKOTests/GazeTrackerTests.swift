//
//  GazeTrackerTests.swift
//  OSKOTests
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OSKO

@Suite("GazeTrackerTests")
struct GazeTrackerTests {
    @Test("Zero-distance cursor singularity at body center yields zero gaze offset without NaN")
    func zeroVectorSingularityAtBodyCenter() {
        let center = NSPoint(x: 720, y: 880)
        let offset = OSKOGazeMath.targetEyeOffset(
            cursorScreenPoint: center,
            bodyScreenCenter: center,
            emotion: .idle,
            isThinking: false
        )
        #expect(offset == .zero)
        #expect(!offset.width.isNaN)
        #expect(!offset.height.isNaN)
    }

    @Test("Horizontal and vertical cursor coordinates map to clamped SwiftUI eye offsets")
    func directionalMappingAndClamping() {
        let bodyCenter = NSPoint(x: 720, y: 880)

        let farLeft = OSKOGazeMath.targetEyeOffset(
            cursorScreenPoint: NSPoint(x: 0, y: 880),
            bodyScreenCenter: bodyCenter,
            emotion: .curious
        )
        let farRight = OSKOGazeMath.targetEyeOffset(
            cursorScreenPoint: NSPoint(x: 1440, y: 880),
            bodyScreenCenter: bodyCenter,
            emotion: .curious
        )
        #expect(farLeft.width < -2.5)
        #expect(farRight.width > 2.5)
        #expect(abs(farLeft.width) <= OSKOGazeMath.maxHorizontalOffset)
        #expect(abs(farRight.width) <= OSKOGazeMath.maxHorizontalOffset)

        // In AppKit screen coordinates, lower Y is toward the bottom of the screen,
        // which should map to a positive (+height downward) SwiftUI offset.
        let bottomCursor = OSKOGazeMath.targetEyeOffset(
            cursorScreenPoint: NSPoint(x: 720, y: 100),
            bodyScreenCenter: bodyCenter,
            emotion: .curious
        )
        // Upper monitor (greater AppKit Y) maps to a negative (-height upward) SwiftUI offset.
        let topCursor = OSKOGazeMath.targetEyeOffset(
            cursorScreenPoint: NSPoint(x: 720, y: 1400),
            bodyScreenCenter: bodyCenter,
            emotion: .curious
        )
        #expect(bottomCursor.height > 1.2)
        #expect(topCursor.height < -1.2)
        #expect(abs(bottomCursor.height) <= OSKOGazeMath.maxVerticalOffset)
        #expect(abs(topCursor.height) <= OSKOGazeMath.maxVerticalOffset)
    }

    @Test("Rest/sleepy and concentration states restrain gaze amplitude compared to active curiosity")
    func restingAndSleepyGazeRestraint() {
        let bodyCenter = NSPoint(x: 720, y: 880)
        let cursor = NSPoint(x: 1400, y: 200)

        let activeOffset = OSKOGazeMath.targetEyeOffset(
            cursorScreenPoint: cursor,
            bodyScreenCenter: bodyCenter,
            emotion: .curious,
            isThinking: false
        )
        let sleepyOffset = OSKOGazeMath.targetEyeOffset(
            cursorScreenPoint: cursor,
            bodyScreenCenter: bodyCenter,
            emotion: .sleepy,
            isThinking: false
        )
        let thinkingOffset = OSKOGazeMath.targetEyeOffset(
            cursorScreenPoint: cursor,
            bodyScreenCenter: bodyCenter,
            emotion: .concentration,
            isThinking: true
        )

        #expect(abs(sleepyOffset.width) < abs(activeOffset.width) * 0.4)
        #expect(abs(sleepyOffset.height) < abs(activeOffset.height) * 0.4)
        #expect(abs(thinkingOffset.width) < abs(activeOffset.width) * 0.5)
    }

    @Test("Smooth gaze interpolation converges toward target without overshoot")
    func smoothGazeInterpolation() {
        var current = CGSize.zero
        let target = CGSize(width: 3.0, height: -1.8)

        for _ in 0..<25 {
            let next = OSKOGazeMath.interpolateOffset(current: current, target: target, smoothingFactor: 0.3)
            #expect(next.width >= current.width)
            #expect(next.width <= target.width)
            #expect(next.height <= current.height)
            #expect(next.height >= target.height)
            current = next
        }

        #expect(abs(current.width - target.width) <= 0.05)
        #expect(abs(current.height - target.height) <= 0.05)
    }

    @Test("OSKOBodyShape generates a single asymmetric organic-tech contour and floatingPose respects stillness")
    func bodyShapeAsymmetryAndFloatingMotion() {
        let rect = CGRect(x: 0, y: 0, width: 68, height: 28)
        let path = OSKOBodyShape().path(in: rect)
        #expect(!path.isEmpty)
        let bounds = path.boundingRect
        #expect(bounds.width > 55 && bounds.width <= 68)
        #expect(bounds.height > 22 && bounds.height <= 28)

        // Verify horizontal asymmetry by sampling left vs right half coverage
        let cgPath = path.cgPath
        var leftCount = 0
        var rightCount = 0
        var xorCount = 0
        let w = Int(rect.width)
        let h = Int(rect.height)
        for y in 0..<h {
            for x in 0..<w {
                let inA = cgPath.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                let inB = cgPath.contains(CGPoint(x: CGFloat(w - 1 - x) + 0.5, y: CGFloat(y) + 0.5))
                if inA {
                    if x < w / 2 { leftCount += 1 } else { rightCount += 1 }
                }
                if inA != inB {
                    xorCount += 1
                }
            }
        }
        let totalArea = leftCount + rightCount
        let asymRatio = Double(xorCount) / Double(max(1, totalArea))
        #expect(asymRatio >= 0.02 && asymRatio <= 0.25)

        // Floating pose amplitude check
        let activePose = OSKOGazeMath.floatingPose(at: 1.2, emotion: .enthusiasm, isThinking: false)
        let restPose = OSKOGazeMath.floatingPose(at: 1.2, emotion: .sleepy, isThinking: false)
        #expect(abs(restPose.offset.height) < abs(activePose.offset.height))
    }
}
