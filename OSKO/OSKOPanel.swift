//
//  OSKOPanel.swift
//  OSKO
//

import AppKit
import Foundation
import SwiftUI

/// Screen geometry snapshot for deterministic, pure notch and top-center frame calculations.
nonisolated struct OSKOScreenGeometry: Sendable, Equatable {
    let name: String
    let frame: NSRect
    let visibleFrame: NSRect
    let safeAreaTop: CGFloat
    let auxiliaryTopLeft: NSRect?
    let auxiliaryTopRight: NSRect?
    let backingScaleFactor: CGFloat

    init(
        name: String = "Main Display",
        frame: NSRect,
        visibleFrame: NSRect,
        safeAreaTop: CGFloat = 0,
        auxiliaryTopLeft: NSRect? = nil,
        auxiliaryTopRight: NSRect? = nil,
        backingScaleFactor: CGFloat = 2.0
    ) {
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.backingScaleFactor = backingScaleFactor
    }

    init(screen: NSScreen) {
        self.name = screen.localizedName
        self.frame = screen.frame
        self.visibleFrame = screen.visibleFrame
        self.safeAreaTop = screen.safeAreaInsets.top
        self.auxiliaryTopLeft = screen.auxiliaryTopLeftArea
        self.auxiliaryTopRight = screen.auxiliaryTopRightArea
        self.backingScaleFactor = screen.backingScaleFactor
    }

    var hasHardwareNotch: Bool {
        guard safeAreaTop > 0 else { return false }
        if let left = auxiliaryTopLeft, let right = auxiliaryTopRight {
            return right.minX > left.maxX
        }
        return true
    }

    var notchRect: NSRect? {
        guard hasHardwareNotch else { return nil }
        if let left = auxiliaryTopLeft, let right = auxiliaryTopRight, right.minX > left.maxX {
            let x = left.maxX
            let width = right.minX - left.maxX
            let y = frame.maxY - safeAreaTop
            return NSRect(x: x, y: y, width: width, height: safeAreaTop)
        }
        let defaultNotchWidth: CGFloat = 180
        let x = frame.midX - (defaultNotchWidth / 2)
        let y = frame.maxY - safeAreaTop
        return NSRect(x: x, y: y, width: defaultNotchWidth, height: safeAreaTop)
    }
}

/// Pure geometry and hit-testing rules for OSKO's floating desktop presence.
nonisolated enum OSKOPanelLayout {
    static let collapsedPanelSize = NSSize(width: 180, height: 52)
    static let expandedPanelSize = NSSize(width: 380, height: 500)
    static let collapsedBodySize = NSSize(width: 68, height: 28)
    static let topPadding: CGFloat = 8
    static let expandedCardWidth: CGFloat = 350

    /// Computes the panel frame in AppKit screen coordinates anchored to the hardware notch or top-center screen edge.
    static func panelFrame(for geometry: OSKOScreenGeometry, isExpanded: Bool) -> NSRect {
        let targetSize = isExpanded ? expandedPanelSize : collapsedPanelSize
        let centerX: CGFloat
        if let notch = geometry.notchRect {
            centerX = notch.midX
        } else {
            centerX = geometry.frame.midX
        }

        let unclampedX = round(centerX - (targetSize.width / 2))
        let minX = geometry.frame.minX
        let maxX = max(minX, geometry.frame.maxX - targetSize.width)
        let originX = min(max(unclampedX, minX), maxX)

        let topAnchorY: CGFloat
        if geometry.hasHardwareNotch {
            topAnchorY = geometry.frame.maxY
        } else {
            // Anchor near the top edge / menu bar while staying within screen bounds.
            let menuBarCandidate = min(geometry.frame.maxY, max(geometry.visibleFrame.maxY, geometry.frame.maxY - 28))
            topAnchorY = menuBarCandidate
        }

        let unclampedY = round(topAnchorY - targetSize.height)
        let minY = geometry.frame.minY
        let maxY = max(minY, geometry.frame.maxY - targetSize.height)
        let originY = min(max(unclampedY, minY), maxY)

        return NSRect(x: originX, y: originY, width: targetSize.width, height: targetSize.height)
    }

    /// Computes the interactive OSKO body rect in local view coordinates (bottom-left AppKit origin).
    static func collapsedInteractiveBodyRect(in panelBounds: NSRect) -> NSRect {
        let width = collapsedBodySize.width
        let height = collapsedBodySize.height
        let x = round(panelBounds.midX - (width / 2))
        let y = round(panelBounds.maxY - topPadding - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Computes the interactive card rect when expanded in local view coordinates (bottom-left AppKit origin).
    static func expandedInteractiveCardRect(in panelBounds: NSRect) -> NSRect {
        let width = min(expandedCardWidth, panelBounds.width - 16)
        let topY = panelBounds.maxY - topPadding - collapsedBodySize.height - 6
        let height = max(120, topY - 8)
        let x = round(panelBounds.midX - (width / 2))
        let y = round(topY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Determines whether a local point (bottom-left AppKit origin) should be handled by OSKO or pass through to windows below.
    static func isInteractivePoint(_ point: NSPoint, in panelBounds: NSRect, isExpanded: Bool) -> Bool {
        guard panelBounds.contains(point) else { return false }
        let bodyRect = collapsedInteractiveBodyRect(in: panelBounds).insetBy(dx: -4, dy: -4)
        if bodyRect.contains(point) {
            return true
        }
        if isExpanded {
            let cardRect = expandedInteractiveCardRect(in: panelBounds)
            return cardRect.contains(point)
        }
        return false
    }

    /// Returns the screen-space center of OSKO's body for global cursor gaze tracking.
    static func bodyScreenCenter(panelFrame: NSRect) -> NSPoint {
        let localBody = collapsedInteractiveBodyRect(
            in: NSRect(origin: .zero, size: panelFrame.size)
        )
        return NSPoint(
            x: panelFrame.origin.x + localBody.midX,
            y: panelFrame.origin.y + localBody.midY
        )
    }
}

/// Custom NSHostingView that allows mouse clicks in transparent exterior margins to pass through.
final class OSKOHostingView<Content: View>: NSHostingView<Content> {
    var isExpanded: Bool = false

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        sizingOptions = []
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in superview coordinates; convert to local bounds if needed.
        let localPoint = superview != nil ? convert(point, from: superview) : point
        guard OSKOPanelLayout.isInteractivePoint(localPoint, in: bounds, isExpanded: isExpanded) else {
            return nil
        }
        return super.hitTest(point)
    }
}

/// Non-activating, transparent, borderless floating NSPanel for OSKO's desktop presence.
final class OSKOPanel: NSPanel {
    static let requiredStyleMask: NSWindow.StyleMask = [
        .nonactivatingPanel,
        .borderless,
        .fullSizeContentView,
    ]

    static let requiredCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle,
    ]

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: Self.requiredStyleMask,
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }

    private func configurePanel() {
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = Self.requiredCollectionBehavior
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// Manages OSKOPanel positioning, screen-change adaptation, and collapsed/expanded state synchronization.
final class OSKOPanelController {
    let panel: OSKOPanel
    let viewModel: OSKOViewModel
    let hostingView: OSKOHostingView<NotchView>
    private var screenObserver: NSObjectProtocol?

    init(viewModel: OSKOViewModel) {
        self.viewModel = viewModel
        let initialGeometry = Self.activeScreenGeometry()
        let initialFrame = OSKOPanelLayout.panelFrame(
            for: initialGeometry,
            isExpanded: viewModel.isPanelExpanded
        )
        let createdPanel = OSKOPanel(contentRect: initialFrame)
        let rootView = NotchView(viewModel: viewModel)
        let host = OSKOHostingView(rootView: rootView)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: initialFrame.size)
        host.autoresizingMask = [.width, .height]
        host.isExpanded = viewModel.isPanelExpanded

        createdPanel.contentView = host
        createdPanel.setFrame(initialFrame, display: true)

        self.panel = createdPanel
        self.hostingView = host

        viewModel.onPanelExpandedChanged = { [weak self] isExpanded in
            self?.updateExpansionState(isExpanded: isExpanded)
        }
        viewModel.bodyScreenCenterProvider = { [weak self] in
            guard let self else {
                return OSKOPanelLayout.bodyScreenCenter(panelFrame: initialFrame)
            }
            return OSKOPanelLayout.bodyScreenCenter(panelFrame: self.panel.frame)
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionPanel()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func showPanel() {
        repositionPanel()
        panel.orderFrontRegardless()
    }

    func repositionPanel(for geometry: OSKOScreenGeometry? = nil) {
        let resolvedGeometry = geometry ?? Self.activeScreenGeometry()
        let frame = OSKOPanelLayout.panelFrame(
            for: resolvedGeometry,
            isExpanded: viewModel.isPanelExpanded
        )
        hostingView.isExpanded = viewModel.isPanelExpanded
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        panel.setFrame(frame, display: true)
    }

    func updateExpansionState(isExpanded: Bool, geometry: OSKOScreenGeometry? = nil) {
        hostingView.isExpanded = isExpanded
        let resolvedGeometry = geometry ?? Self.activeScreenGeometry()
        let targetFrame = OSKOPanelLayout.panelFrame(for: resolvedGeometry, isExpanded: isExpanded)
        hostingView.frame = NSRect(origin: .zero, size: targetFrame.size)
        panel.setFrame(targetFrame, display: true)
        if !isExpanded && panel.isKeyWindow {
            panel.resignKey()
        }
    }

    static func activeScreenGeometry() -> OSKOScreenGeometry {
        if let mainScreen = NSScreen.main ?? NSScreen.screens.first {
            return OSKOScreenGeometry(screen: mainScreen)
        }
        return OSKOScreenGeometry(
            name: "Fallback Headless Display",
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875),
            safeAreaTop: 0
        )
    }
}
