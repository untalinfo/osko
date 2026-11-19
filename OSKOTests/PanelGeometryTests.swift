//
//  PanelGeometryTests.swift
//  OSKOTests
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OSKO

@Suite("PanelGeometryTests")
struct PanelGeometryTests {
    @Test("Non-notched display positions panel horizontally centered and anchored at top edge")
    func nonNotchedTopCenterGeometry() {
        let geometry = OSKOScreenGeometry(
            name: "Standard Display",
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875),
            safeAreaTop: 0
        )

        #expect(!geometry.hasHardwareNotch)
        #expect(geometry.notchRect == nil)

        let collapsed = OSKOPanelLayout.panelFrame(for: geometry, isExpanded: false)
        #expect(collapsed.size == OSKOPanelLayout.collapsedPanelSize)
        #expect(abs(collapsed.midX - geometry.frame.midX) <= 1.0)
        #expect(collapsed.maxY <= geometry.frame.maxY)
        #expect(collapsed.maxY >= geometry.visibleFrame.maxY - 2.0)
        #expect(geometry.frame.contains(collapsed))

        let expanded = OSKOPanelLayout.panelFrame(for: geometry, isExpanded: true)
        #expect(expanded.size == OSKOPanelLayout.expandedPanelSize)
        #expect(abs(expanded.midX - geometry.frame.midX) <= 1.0)
        #expect(abs(expanded.maxY - collapsed.maxY) <= 1.0)
        #expect(geometry.frame.contains(expanded))
    }

    @Test("Notched display positions panel centered on hardware notch using auxiliary areas")
    func notchedDisplayGeometry() {
        let geometry = OSKOScreenGeometry(
            name: "Built-in Liquid Retina XDR Display",
            frame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: NSRect(x: 0, y: 0, width: 1728, height: 1079),
            safeAreaTop: 38,
            auxiliaryTopLeft: NSRect(x: 0, y: 1079, width: 764, height: 38),
            auxiliaryTopRight: NSRect(x: 964, y: 1079, width: 764, height: 38),
            backingScaleFactor: 2.0
        )

        #expect(geometry.hasHardwareNotch)
        let notch = try! #require(geometry.notchRect)
        #expect(notch == NSRect(x: 764, y: 1079, width: 200, height: 38))

        let collapsed = OSKOPanelLayout.panelFrame(for: geometry, isExpanded: false)
        #expect(abs(collapsed.midX - notch.midX) <= 1.0)
        #expect(collapsed.maxY == geometry.frame.maxY)
        #expect(geometry.frame.contains(collapsed))

        let expanded = OSKOPanelLayout.panelFrame(for: geometry, isExpanded: true)
        #expect(abs(expanded.midX - notch.midX) <= 1.0)
        #expect(expanded.maxY == geometry.frame.maxY)
        #expect(geometry.frame.contains(expanded))
    }

    @Test("Multi-display negative and asymmetric screen coordinates stay contained inside screen frame")
    func multiDisplayNegativeCoordinates() {
        let secondaryGeometry = OSKOScreenGeometry(
            name: "Left Upper Monitor",
            frame: NSRect(x: -1920, y: 300, width: 1920, height: 1080),
            visibleFrame: NSRect(x: -1920, y: 300, width: 1920, height: 1055),
            safeAreaTop: 0
        )

        let collapsed = OSKOPanelLayout.panelFrame(for: secondaryGeometry, isExpanded: false)
        #expect(secondaryGeometry.frame.contains(collapsed))
        #expect(abs(collapsed.midX - secondaryGeometry.frame.midX) <= 1.0)

        let expanded = OSKOPanelLayout.panelFrame(for: secondaryGeometry, isExpanded: true)
        #expect(secondaryGeometry.frame.contains(expanded))
        #expect(abs(expanded.midX - secondaryGeometry.frame.midX) <= 1.0)
        #expect(abs(expanded.maxY - collapsed.maxY) <= 1.0)
    }

    @Test("Click-through hit-testing passes exterior margin clicks while capturing body and expanded card clicks")
    @MainActor
    func hitTestAndClickThroughRegions() {
        let collapsedBounds = NSRect(origin: .zero, size: OSKOPanelLayout.collapsedPanelSize)
        let bodyRect = OSKOPanelLayout.collapsedInteractiveBodyRect(in: collapsedBounds)
        let bodyCenter = NSPoint(x: bodyRect.midX, y: bodyRect.midY)

        // Inside collapsed body -> interactive
        #expect(OSKOPanelLayout.isInteractivePoint(bodyCenter, in: collapsedBounds, isExpanded: false))

        // Exterior corners and bottom margin of collapsed panel -> click-through (false)
        let exteriorPoints = [
            NSPoint(x: 4, y: 4),
            NSPoint(x: collapsedBounds.maxX - 4, y: 4),
            NSPoint(x: 4, y: collapsedBounds.maxY - 4),
            NSPoint(x: collapsedBounds.maxX - 4, y: collapsedBounds.maxY - 4),
            NSPoint(x: collapsedBounds.midX, y: 2),
        ]
        for pt in exteriorPoints {
            #expect(!OSKOPanelLayout.isInteractivePoint(pt, in: collapsedBounds, isExpanded: false))
        }

        // Expanded bounds: body and chat card are interactive, outer corners still click-through
        let expandedBounds = NSRect(origin: .zero, size: OSKOPanelLayout.expandedPanelSize)
        let expandedBodyRect = OSKOPanelLayout.collapsedInteractiveBodyRect(in: expandedBounds)
        let expandedCardRect = OSKOPanelLayout.expandedInteractiveCardRect(in: expandedBounds)

        #expect(OSKOPanelLayout.isInteractivePoint(
            NSPoint(x: expandedBodyRect.midX, y: expandedBodyRect.midY),
            in: expandedBounds,
            isExpanded: true
        ))
        #expect(OSKOPanelLayout.isInteractivePoint(
            NSPoint(x: expandedCardRect.midX, y: expandedCardRect.midY),
            in: expandedBounds,
            isExpanded: true
        ))
        #expect(!OSKOPanelLayout.isInteractivePoint(
            NSPoint(x: 2, y: expandedBounds.maxY - 2),
            in: expandedBounds,
            isExpanded: true
        ))

        // Verify OSKOHostingView hitTest returns nil in exterior click-through zone
        let host = OSKOHostingView(rootView: EmptyView())
        host.frame = collapsedBounds
        host.isExpanded = false
        #expect(host.hitTest(NSPoint(x: 3, y: 3)) == nil)
    }

    @Test("OSKOPanel configures non-activating, borderless, floating statusBar properties and key capability")
    @MainActor
    func panelConfigurationAndControllerSync() {
        let frame = NSRect(x: 500, y: 800, width: 180, height: 52)
        let panel = OSKOPanel(contentRect: frame)

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.fullSizeContentView))
        #expect(panel.isFloatingPanel)
        #expect(panel.level == .statusBar)
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == .clear)
        #expect(!panel.hasShadow)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.stationary))

        let vm = OSKOViewModel(autoLoad: false)
        let controller = OSKOPanelController(viewModel: vm)
        #expect(controller.hostingView.sizingOptions.isEmpty)
        #expect(controller.hostingView.intrinsicContentSize == NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric))

        let testGeometry = OSKOScreenGeometry(
            name: "Test Screen",
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875),
            safeAreaTop: 0
        )

        controller.updateExpansionState(isExpanded: false, geometry: testGeometry)
        controller.panel.layoutIfNeeded()
        #expect(controller.panel.frame.size == OSKOPanelLayout.collapsedPanelSize)
        #expect(controller.hostingView.frame.size == OSKOPanelLayout.collapsedPanelSize)

        vm.setPanelExpanded(true)
        controller.updateExpansionState(isExpanded: true, geometry: testGeometry)
        controller.panel.layoutIfNeeded()
        #expect(controller.panel.frame.size == OSKOPanelLayout.expandedPanelSize)
        #expect(controller.hostingView.frame.size == OSKOPanelLayout.expandedPanelSize)

        vm.setPanelExpanded(false)
        controller.updateExpansionState(isExpanded: false, geometry: testGeometry)
        controller.panel.layoutIfNeeded()
        #expect(controller.panel.frame.size == OSKOPanelLayout.collapsedPanelSize)
        #expect(controller.hostingView.frame.size == OSKOPanelLayout.collapsedPanelSize)
    }
}
