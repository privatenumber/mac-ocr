import CoreGraphics
import CoreText
import Foundation

enum DocumentTestSupport {
	static func makeTableRaster() -> CGImage {
		let context = CGContext(
			data: nil,
			width: 800,
			height: 500,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		)!
		context.setFillColor(CGColor(gray: 1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
		context.setStrokeColor(CGColor(gray: 0, alpha: 1))
		context.setLineWidth(4)
		for x in [40, 400, 760] {
			context.move(to: CGPoint(x: x, y: 40))
			context.addLine(to: CGPoint(x: x, y: 460))
		}
		for y in [40, 250, 460] {
			context.move(to: CGPoint(x: 40, y: y))
			context.addLine(to: CGPoint(x: 760, y: y))
		}
		context.strokePath()
		drawText("ALPHA", at: CGPoint(x: 100, y: 330), in: context)
		drawText("BETA", at: CGPoint(x: 470, y: 330), in: context)
		drawText("GAMMA", at: CGPoint(x: 100, y: 120), in: context)
		drawText("DELTA", at: CGPoint(x: 470, y: 120), in: context)
		return context.makeImage()!
	}

	static func makeNumberedListRaster() -> CGImage {
		let context = CGContext(
			data: nil,
			width: 600,
			height: 500,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		)!
		context.setFillColor(CGColor(gray: 1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: 600, height: 500))
		drawText("1. ALPHA", at: CGPoint(x: 80, y: 360), in: context)
		drawText("2. BETA", at: CGPoint(x: 80, y: 250), in: context)
		drawText("3. GAMMA", at: CGPoint(x: 80, y: 140), in: context)
		return context.makeImage()!
	}

	private static func drawText(_ text: String, at point: CGPoint, in context: CGContext) {
		let font = CTFontCreateWithName("Helvetica" as CFString, 42, nil)
		let attributes: [NSAttributedString.Key: Any] = [
			NSAttributedString.Key(kCTFontAttributeName as String): font
		]
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
		context.textPosition = point
		CTLineDraw(line, context)
	}
}
