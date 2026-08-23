import AppKit
import LocalClipCore
import SwiftUI

/// Small AppKit-backed recorder so shortcut capture works on the app's macOS 13 target.
struct HotKeyRecorderView: NSViewRepresentable {
    let shortcut: HotKeyShortcut
    let onBegin: () -> Void
    let onCancel: () -> Void
    let onRecord: (HotKeyShortcut) -> Bool

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        button.configure(
            shortcut: shortcut,
            onBegin: onBegin,
            onCancel: onCancel,
            onRecord: onRecord
        )
        return button
    }

    func updateNSView(_ nsView: HotKeyRecorderButton, context: Context) {
        nsView.configure(
            shortcut: shortcut,
            onBegin: onBegin,
            onCancel: onCancel,
            onRecord: onRecord
        )
    }
}

@MainActor
final class HotKeyRecorderButton: NSButton {
    private var displayedShortcut = HotKeyShortcut.screenshotDefault
    private var isRecordingShortcut = false
    private var beginHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?
    private var recordHandler: ((HotKeyShortcut) -> Bool)?
    private var windowObservers: [NSObjectProtocol] = []

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        target = self
        action = #selector(beginRecording)
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        guard let window else { return }

        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.cancelRecordingIfNeeded()
                    }
                }
            )
        }
    }

    func configure(
        shortcut: HotKeyShortcut,
        onBegin: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onRecord: @escaping (HotKeyShortcut) -> Bool
    ) {
        beginHandler = onBegin
        cancelHandler = onCancel
        recordHandler = onRecord
        guard !isRecordingShortcut else { return }
        displayedShortcut = shortcut
        updateTitle()
    }

    @objc private func beginRecording() {
        guard !isRecordingShortcut, let window else { return }
        isRecordingShortcut = true
        guard window.makeFirstResponder(self) else {
            isRecordingShortcut = false
            return
        }
        beginHandler?()
        updateTitle()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }
        handleRecordingEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecordingShortcut, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        // Capture combinations such as ⌘W before the window treats them as commands.
        handleRecordingEvent(event)
        return true
    }

    private func handleRecordingEvent(_ event: NSEvent) {
        // Esc cancels recording without changing the current binding or showing an error.
        if event.keyCode == 53 {
            cancelRecording()
            return
        }

        let candidate = HotKeyShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: Self.modifiers(from: event.modifierFlags)
        )
        isRecordingShortcut = false
        if recordHandler?(candidate) == true {
            displayedShortcut = candidate
        }
        window?.makeFirstResponder(nil)
        updateTitle()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isRecordingShortcut {
            isRecordingShortcut = false
            cancelHandler?()
            updateTitle()
        }
        return resigned
    }

    private func cancelRecording() {
        isRecordingShortcut = false
        cancelHandler?()
        window?.makeFirstResponder(nil)
        updateTitle()
    }

    private func cancelRecordingIfNeeded() {
        guard isRecordingShortcut else { return }
        cancelRecording()
    }

    private func updateTitle() {
        if isRecordingShortcut {
            title = "按下快捷键（Esc 取消）"
            toolTip = "同时按下至少一个修饰键和一个普通按键"
            setAccessibilityLabel("正在录制快速截屏快捷键，按 Escape 取消")
        } else {
            title = displayedShortcut.displayLabel
            toolTip = "点击后按下新的快速截屏快捷键"
            setAccessibilityLabel("快速截屏快捷键：\(displayedShortcut.displayLabel)")
        }
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> HotKeyModifiers {
        var modifiers: HotKeyModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}
