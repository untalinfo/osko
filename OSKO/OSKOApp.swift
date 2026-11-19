//
//  OSKOApp.swift
//  OSKO
//
//  Created by Oscar Info Giraldo on 6/11/26.
//

import AppKit
import SwiftUI

final class OSKOAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var viewModel: OSKOViewModel?
    private(set) var panelController: OSKOPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let vm = OSKOViewModel()
        let controller = OSKOPanelController(viewModel: vm)
        self.viewModel = vm
        self.panelController = controller
        controller.showPanel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.showPanel()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.speechRecognizer.stopListening()
        viewModel?.voiceSynthesizer.stopSpeaking()
        panelController?.panel.close()
    }
}

@main
struct OSKOApp: App {
    @NSApplicationDelegateAdaptor(OSKOAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
