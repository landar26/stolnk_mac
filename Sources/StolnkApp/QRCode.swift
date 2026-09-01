import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/**
 PRD 10.2 — the QR code is what turns "how do I try this on my own?" into
 looking up and scanning. It is the whole first-run demo, so it ships in the
 completion step rather than being buried in a menu.

 CoreImage generates it; no dependency required.
 */
enum QRCode {
	static func image(for string: String, size: CGFloat = 220) -> NSImage? {
		let filter = CIFilter.qrCodeGenerator()
		filter.message = Data(string.utf8)
		// Medium correction: enough to survive a phone camera at an angle without
		// making the modules too dense to read from across a desk.
		filter.correctionLevel = "M"

		guard let output = filter.outputImage else { return nil }
		let scale = size / output.extent.width
		let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

		let context = CIContext()
		guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
		return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
	}
}
