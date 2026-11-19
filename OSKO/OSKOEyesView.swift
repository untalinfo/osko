//
//  OSKOEyesView.swift
//  OSKO
//
//  Created by Oscar Info Giraldo on 6/11/26.
//

import AppKit
import Foundation
import SwiftUI

struct OSKOEyesView: View {
    @ObservedObject var viewModel: OSKOViewModel
    @State private var isBlinking = false

    private struct EyeStyle: Equatable {
        let leftSize: CGSize
        let rightSize: CGSize
        let leftCornerRadius: CGFloat
        let rightCornerRadius: CGFloat
        let leftRotation: Angle
        let rightRotation: Angle
        let leftOffsetY: CGFloat
        let rightOffsetY: CGFloat
        let spacing: CGFloat
        let opacity: Double
        let groupRotation: Angle
    }

    var body: some View {
        let style = eyeStyle(for: viewModel.currentEmotion)
        let blinkFactor: CGFloat = isBlinking ? 0.15 : 1.0

        HStack(spacing: style.spacing) {
            RoundedRectangle(cornerRadius: style.leftCornerRadius, style: .continuous)
                .fill(Color.oskoAmber.opacity(style.opacity))
                .frame(
                    width: style.leftSize.width,
                    height: max(1.0, style.leftSize.height * blinkFactor)
                )
                .rotationEffect(style.leftRotation)
                .offset(y: style.leftOffsetY)

            RoundedRectangle(cornerRadius: style.rightCornerRadius, style: .continuous)
                .fill(Color.oskoAmber.opacity(style.opacity))
                .frame(
                    width: style.rightSize.width,
                    height: max(1.0, style.rightSize.height * blinkFactor)
                )
                .rotationEffect(style.rightRotation)
                .offset(y: style.rightOffsetY)
        }
        .rotationEffect(style.groupRotation)
        .offset(viewModel.eyeGazeOffset)
        .frame(width: 26, height: 14)
        .scaleEffect(viewModel.isThinking ? 0.85 : 1.0)
        .animation(.easeInOut(duration: 0.25), value: viewModel.currentEmotion)
        .animation(.easeInOut(duration: 0.22), value: viewModel.isThinking)
        .task {
            while !Task.isCancelled {
                let interval = Double.random(in: 2.8...4.5)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }

                withAnimation(.easeInOut(duration: 0.08)) {
                    isBlinking = true
                }
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { break }

                withAnimation(.easeInOut(duration: 0.1)) {
                    isBlinking = false
                }
            }
        }
        .task {
            while !Task.isCancelled {
                viewModel.updateGaze(forCursorScreenPoint: NSEvent.mouseLocation)
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }

    private func eyeStyle(for emotion: OSKOEmotion) -> EyeStyle {
        switch emotion {
        case .idle:
            return EyeStyle(
                leftSize: CGSize(width: 4.5, height: 4.5),
                rightSize: CGSize(width: 4.5, height: 4.5),
                leftCornerRadius: 2.25,
                rightCornerRadius: 2.25,
                leftRotation: .zero,
                rightRotation: .zero,
                leftOffsetY: 0,
                rightOffsetY: 0,
                spacing: 4.5,
                opacity: 0.96,
                groupRotation: .zero
            )

        case .curious:
            return EyeStyle(
                leftSize: CGSize(width: 4.5, height: 5.0),
                rightSize: CGSize(width: 5.5, height: 6.0),
                leftCornerRadius: 2.5,
                rightCornerRadius: 3.0,
                leftRotation: .zero,
                rightRotation: .zero,
                leftOffsetY: 0.5,
                rightOffsetY: -0.5,
                spacing: 4.5,
                opacity: 1.0,
                groupRotation: .degrees(-6)
            )

        case .concentration:
            return EyeStyle(
                leftSize: CGSize(width: 4.5, height: 2.2),
                rightSize: CGSize(width: 4.5, height: 2.2),
                leftCornerRadius: 1.1,
                rightCornerRadius: 1.1,
                leftRotation: .zero,
                rightRotation: .zero,
                leftOffsetY: 0,
                rightOffsetY: 0,
                spacing: 4.0,
                opacity: 0.76,
                groupRotation: .zero
            )

        case .enthusiasm:
            return EyeStyle(
                leftSize: CGSize(width: 5.6, height: 5.6),
                rightSize: CGSize(width: 5.6, height: 5.6),
                leftCornerRadius: 2.8,
                rightCornerRadius: 2.8,
                leftRotation: .zero,
                rightRotation: .zero,
                leftOffsetY: -0.5,
                rightOffsetY: -0.5,
                spacing: 4.5,
                opacity: 1.0,
                groupRotation: .zero
            )

        case .empathy:
            return EyeStyle(
                leftSize: CGSize(width: 4.8, height: 3.6),
                rightSize: CGSize(width: 4.8, height: 3.6),
                leftCornerRadius: 1.8,
                rightCornerRadius: 1.8,
                leftRotation: .degrees(-8),
                rightRotation: .degrees(8),
                leftOffsetY: 0.5,
                rightOffsetY: 0.5,
                spacing: 4.5,
                opacity: 0.90,
                groupRotation: .zero
            )

        case .mischief:
            return EyeStyle(
                leftSize: CGSize(width: 4.8, height: 2.0),
                rightSize: CGSize(width: 5.0, height: 4.8),
                leftCornerRadius: 1.0,
                rightCornerRadius: 2.4,
                leftRotation: .degrees(6),
                rightRotation: .degrees(-6),
                leftOffsetY: 0.3,
                rightOffsetY: -0.3,
                spacing: 4.5,
                opacity: 1.0,
                groupRotation: .degrees(4)
            )

        case .surprise:
            return EyeStyle(
                leftSize: CGSize(width: 5.4, height: 6.8),
                rightSize: CGSize(width: 5.4, height: 6.8),
                leftCornerRadius: 2.7,
                rightCornerRadius: 2.7,
                leftRotation: .zero,
                rightRotation: .zero,
                leftOffsetY: -0.6,
                rightOffsetY: -0.6,
                spacing: 5.0,
                opacity: 1.0,
                groupRotation: .zero
            )

        case .sleepy:
            return EyeStyle(
                leftSize: CGSize(width: 6.2, height: 1.5),
                rightSize: CGSize(width: 6.2, height: 1.5),
                leftCornerRadius: 0.75,
                rightCornerRadius: 0.75,
                leftRotation: .zero,
                rightRotation: .zero,
                leftOffsetY: 1.0,
                rightOffsetY: 1.0,
                spacing: 4.0,
                opacity: 0.65,
                groupRotation: .zero
            )

        case .annoyed:
            return EyeStyle(
                leftSize: CGSize(width: 5.0, height: 2.0),
                rightSize: CGSize(width: 5.0, height: 2.0),
                leftCornerRadius: 0.8,
                rightCornerRadius: 0.8,
                leftRotation: .degrees(14),
                rightRotation: .degrees(-14),
                leftOffsetY: 0,
                rightOffsetY: 0,
                spacing: 4.0,
                opacity: 0.92,
                groupRotation: .zero
            )
        }
    }
}
