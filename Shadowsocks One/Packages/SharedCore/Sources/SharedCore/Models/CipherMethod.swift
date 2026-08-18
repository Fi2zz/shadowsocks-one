public enum CipherMethod: String, Codable, Sendable, Hashable {
    case aes128GCM = "aes-128-gcm"
    case aes256GCM = "aes-256-gcm"
    case chacha20IETFPoly1305 = "chacha20-ietf-poly1305"
}
