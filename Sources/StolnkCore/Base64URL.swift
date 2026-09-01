import Foundation

/// Unpadded base64url, the encoding every JSON field on the wire uses.
public enum Base64URL {
	public static func encode(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	public static func decode(_ text: String) -> Data? {
		var padded = text
			.replacingOccurrences(of: "-", with: "+")
			.replacingOccurrences(of: "_", with: "/")
		let remainder = padded.count % 4
		if remainder > 0 { padded += String(repeating: "=", count: 4 - remainder) }
		return Data(base64Encoded: padded)
	}
}

extension Data {
	public var hexString: String {
		map { String(format: "%02x", $0) }.joined()
	}
}

extension UInt32 {
	var bigEndianBytes: Data {
		var value = bigEndian
		return Data(bytes: &value, count: 4)
	}
}

extension UInt64 {
	var bigEndianBytes: Data {
		var value = bigEndian
		return Data(bytes: &value, count: 8)
	}
}
