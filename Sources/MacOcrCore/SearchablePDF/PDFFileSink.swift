import CoreGraphics
import Darwin
import Foundation

/// A PDF consumer that reports failures, including writes made by closePDF().
final class PDFFileSink {
	typealias Write = (Int32, UnsafeRawPointer, Int) -> Int

	private final class State {
		var descriptor: Int32
		let writeBytes: Write
		var error: POSIXError?

		init(descriptor: Int32, writeBytes: @escaping Write) {
			self.descriptor = descriptor
			self.writeBytes = writeBytes
		}

		func append(_ buffer: UnsafeRawPointer, count: Int) -> Int {
			guard error == nil else { return 0 }
			var written = 0
			while written < count {
				let result = writeBytes(descriptor, buffer.advanced(by: written), count - written)
				if result < 0, errno == EINTR { continue }
				guard result > 0 else {
					error = POSIXError(result == 0 ? .EIO : POSIXErrorCode(rawValue: errno) ?? .EIO)
					return written
				}
				written += result
			}
			return written
		}

		func close() throws {
			guard descriptor >= 0 else { return }
			let fd = descriptor
			descriptor = -1
			let result = Darwin.close(fd)
			if let error { throw error }
			if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		}

		deinit {
			if descriptor >= 0 { Darwin.close(descriptor) }
		}
	}

	private let state: State
	let consumer: CGDataConsumer

	init(url: URL, writeBytes: @escaping Write = Darwin.write) throws {
		let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
		guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		let state = State(descriptor: descriptor, writeBytes: writeBytes)
		self.state = state
		var callbacks = CGDataConsumerCallbacks(
			putBytes: { info, buffer, count in
				guard let info else { return 0 }
				return Unmanaged<State>.fromOpaque(info).takeUnretainedValue().append(buffer, count: count)
			},
			releaseConsumer: { info in
				if let info { Unmanaged<State>.fromOpaque(info).release() }
			}
		)
		let info = Unmanaged.passRetained(state).toOpaque()
		guard let consumer = CGDataConsumer(info: info, cbks: &callbacks) else {
			Unmanaged<State>.fromOpaque(info).release()
			throw MessageError("Could not create PDF file consumer")
		}
		self.consumer = consumer
	}

	func checkError() throws {
		if let error = state.error { throw error }
	}

	/// The caller must finalize and release the PDF context before closing.
	func close() throws {
		try state.close()
	}
}
