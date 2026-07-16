import AVFoundation
import Accelerate
import SwiftUI

/// Loudness envelope of a meeting's audio for the Trim window: the tracks are
/// decoded once into a fixed number of RMS buckets (combined across tracks by
/// max, normalized to the loudest bucket) so the view can show at a glance
/// where the recording goes quiet - typically where the meeting really ended.
enum TrimWaveform {
	/// Quiet-bucket threshold on the normalized (square-root-compressed) envelope.
	/// 0.15 here is ~0.02 of the peak RMS (roughly -34 dB) - room noise after
	/// everyone left, well below even distant speech.
	static let quietLevel: Float = 0.15

	/// Compute the normalized envelope off the main thread. Returns an empty
	/// array when nothing could be read (the view then just doesn't render).
	static func levels(for urls: [URL], buckets: Int) async -> [Float] {
		await Task.detached(priority: .userInitiated) {
			computeLevels(for: urls, buckets: buckets)
		}.value
	}

	private static func computeLevels(for urls: [URL], buckets: Int) -> [Float] {
		guard buckets > 0 else { return [] }
		var combined = [Float](repeating: 0, count: buckets)
		var any = false
		for url in urls {
			guard let levels = trackLevels(url: url, buckets: buckets) else { continue }
			any = true
			// Tracks play mixed, so the envelope keeps whichever side is louder.
			for i in 0..<buckets { combined[i] = max(combined[i], levels[i]) }
		}
		guard any, let peak = combined.max(), peak > 0 else { return [] }
		// Square root compresses the range a bit so normal speech doesn't make
		// everything but the single loudest moment look near-silent.
		return combined.map { ($0 / peak).squareRoot() }
	}

	/// Per-bucket RMS of one track. AVAudioFile decodes WAV and M4A alike.
	private static func trackLevels(url: URL, buckets: Int) -> [Float]? {
		guard let file = try? AVAudioFile(forReading: url), file.length > 0,
			let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16)
		else { return nil }
		let total = file.length
		var sumSquares = [Double](repeating: 0, count: buckets)
		var counts = [Double](repeating: 0, count: buckets)
		var frame: AVAudioFramePosition = 0
		while frame < total {
			do { try file.read(into: buf) } catch { return nil }
			guard buf.frameLength > 0, let channels = buf.floatChannelData else { break }
			// Loudness only needs one channel - a meeting track carries the same
			// voice on all of them. Sum-of-squares per bucket slice via vDSP keeps
			// this fast enough to run on every open of the Trim window.
			let samples = channels[0]
			let n = Int(buf.frameLength)
			var i = 0
			while i < n {
				let pos = frame + AVAudioFramePosition(i)
				let bucket = min(Int(pos * AVAudioFramePosition(buckets) / total), buckets - 1)
				let bucketEnd = AVAudioFramePosition(bucket + 1) * total / AVAudioFramePosition(buckets)
				let count = min(n - i, max(Int(bucketEnd - pos), 1))
				var ss: Float = 0
				vDSP_svesq(samples + i, 1, &ss, vDSP_Length(count))
				sumSquares[bucket] += Double(ss)
				counts[bucket] += Double(count)
				i += count
			}
			frame += AVAudioFramePosition(buf.frameLength)
		}
		return (0..<buckets).map { counts[$0] > 0 ? Float((sumSquares[$0] / counts[$0]).squareRoot()) : 0 }
	}
}

/// Compact loudness strip for the Trim window: one bar per bucket, quiet
/// stretches dimmed so the spot where the meeting ended stands out, and the part
/// that would be cut tinted red. A moving playhead ties the diagram to playback:
/// a plain click seeks the audio there, while the red cut marker is moved by
/// dragging it.
struct TrimWaveformView: View {
	let levels: [Float]
	let duration: Double
	@Binding var cutTime: Double
	/// Current playback position, drawn as the playhead.
	let currentTime: Double
	/// Seek playback to a time (seconds), called when the user clicks the diagram.
	let onSeek: (Double) -> Void

	/// Half-width (points) of the grab zone around the cut marker.
	private static let handleGrab: CGFloat = 12

	/// What the in-flight drag manipulates, decided when the press lands.
	@State private var dragMode: DragMode?
	private enum DragMode { case cut, seek }

	var body: some View {
		GeometryReader { geo in
			Canvas { context, size in
				guard !levels.isEmpty else { return }
				let barWidth = size.width / CGFloat(levels.count)
				let cutX = duration > 0 ? size.width * CGFloat(cutTime / duration) : size.width
				for (i, level) in levels.enumerated() {
					let x = CGFloat(i) * barWidth
					let h = max(2, CGFloat(level) * size.height)
					let bar = CGRect(x: x, y: (size.height - h) / 2,
						width: max(barWidth - 1, 0.5), height: h)
					let removed = x + barWidth / 2 > cutX
					let quiet = level < TrimWaveform.quietLevel
					let color: Color = removed
						? (quiet ? .red.opacity(0.2) : .red.opacity(0.45))
						: (quiet ? .secondary.opacity(0.3) : .accentColor)
					context.fill(Path(roundedRect: bar, cornerRadius: barWidth / 3), with: .color(color))
				}
				// Playhead (below the cut marker so the cut point always stays visible).
				if duration > 0 {
					let playX = size.width * CGFloat(min(max(currentTime / duration, 0), 1))
					context.fill(Path(CGRect(x: playX - 0.75, y: 0, width: 1.5, height: size.height)),
						with: .color(.primary.opacity(0.7)))
				}
				// Cut marker on top of the bars.
				context.fill(Path(CGRect(x: cutX - 0.75, y: 0, width: 1.5, height: size.height)),
					with: .color(.red))
			}
			.contentShape(Rectangle())
			.gesture(
				DragGesture(minimumDistance: 0)
					.onChanged { value in
						guard duration > 0, geo.size.width > 0 else { return }
						let cutX = geo.size.width * CGFloat(cutTime / duration)
						// Grabbing on (or very near) the cut marker moves the cut point;
						// pressing anywhere else scrubs playback.
						if dragMode == nil {
							dragMode = abs(value.startLocation.x - cutX) <= Self.handleGrab ? .cut : .seek
						}
						let t = min(max(value.location.x / geo.size.width, 0), 1) * duration
						if dragMode == .cut { cutTime = t } else { onSeek(t) }
					}
					.onEnded { _ in dragMode = nil }
			)
		}
		.frame(height: 44)
		.help("Loudness over time - dim bars are quiet. Click to seek playback here; drag the red marker to place the cut point.")
	}
}