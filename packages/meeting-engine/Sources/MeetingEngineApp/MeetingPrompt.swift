// Notion-style "are you in a meeting?" floating prompt.
//
// When a meeting is detected while the app is in the background (you're in Zoom,
// not in this app), we show a small floating card over whatever you're doing -
// app icon, a line of context, and Start / Not now. It's a non-activating panel
// at status-bar level so it appears above other apps without stealing focus, and
// auto-dismisses after a while if you ignore it.

import AppKit
import SwiftUI

/// Owns the floating prompt window and its lifetime. Used only on the main thread
/// (driven by the detector's main-runloop callbacks and SwiftUI lifecycle).
final class MeetingPromptController {
	private var panel: NSPanel?
	private var dismissTimer: Timer?
	/// Seconds the card lingers before quietly dismissing itself.
	private let autoDismissAfter: TimeInterval = 30

	/// Show the prompt. `subtitle` carries the context (calendar event or generic).
	/// `onStart` / `onDismiss` fire on the respective button (or auto-dismiss).
	func show(subtitle: String, onStart: @escaping () -> Void, onDismiss: @escaping () -> Void) {
		hide()
		let card = MeetingPromptCard(
			subtitle: subtitle,
			onStart: { [weak self] in self?.hide(); onStart() },
			onDismiss: { [weak self] in self?.hide(); onDismiss() })

		let hosting = NSHostingView(rootView: card)
		hosting.layoutSubtreeIfNeeded()
		hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

		let panel = NSPanel(contentRect: hosting.frame,
			styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
		panel.isFloatingPanel = true
		panel.level = .statusBar
		panel.backgroundColor = .clear
		panel.isOpaque = false
		panel.hasShadow = true
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
		panel.contentView = hosting
		positionTopCenter(panel)
		panel.orderFrontRegardless()
		self.panel = panel

		dismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismissAfter, repeats: false) { [weak self] _ in
			self?.hide(); onDismiss()
		}
	}

	func hide() {
		dismissTimer?.invalidate(); dismissTimer = nil
		panel?.orderOut(nil); panel = nil
	}

	/// Top-center of the active screen, just below the menu bar.
	private func positionTopCenter(_ panel: NSPanel) {
		guard let screen = NSScreen.main else { return }
		let v = screen.visibleFrame
		let s = panel.frame.size
		let margin: CGFloat = 16
		panel.setFrameOrigin(NSPoint(x: v.midX - s.width / 2, y: v.maxY - s.height - margin))
	}
}

/// The card's contents. Fixed width; height follows the text.
private struct MeetingPromptCard: View {
	let subtitle: String
	let onStart: () -> Void
	let onDismiss: () -> Void

	var body: some View {
		HStack(alignment: .top, spacing: 12) {
			Image(systemName: "waveform.circle.fill")
				.font(.system(size: 30))
				.foregroundStyle(Color.accentColor)
			VStack(alignment: .leading, spacing: 3) {
				Text("Are you in a meeting?")
					.font(.subheadline.weight(.semibold))
				Text(subtitle)
					.font(.caption).foregroundStyle(.secondary)
					.lineLimit(2).fixedSize(horizontal: false, vertical: true)
				HStack(spacing: 8) {
					Button("Start meeting notes", action: onStart)
						.buttonStyle(.borderedProminent)
					Button("Not now", action: onDismiss)
						.buttonStyle(.bordered)
				}
				.controlSize(.small)
				.padding(.top, 4)
			}
		}
		.padding(14)
		.frame(width: 320, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
		.overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
	}
}