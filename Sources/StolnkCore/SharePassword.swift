import CryptoKit
import Foundation

/// PBKDF2-HMAC-SHA256 compatible with the browser share page. The derived
/// verifier, not the password, is sent when a share is created.
public enum SharePassword {
	public static func derive(
		_ password: String, salt: String, iterations: Int, keyLength: Int = 32
	) async throws -> String {
		guard let saltData = Base64URL.decode(salt), iterations > 0 else {
			throw APIError(status: 0, code: "bad_salt", message: "The password salt is invalid.")
		}
		return await Task.detached(priority: .userInitiated) {
			let key = SymmetricKey(data: Data(password.utf8))
			var block = saltData
			var index = UInt32(1).bigEndian
			block.append(Data(bytes: &index, count: 4))
			var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
			var output = u
			if iterations > 1 {
				for _ in 2...iterations {
					u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
					for position in output.indices { output[position] ^= u[position] }
				}
			}
			return Data(output.prefix(keyLength)).hexString
		}.value
	}
}
