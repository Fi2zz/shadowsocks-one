extension CipherMethod {
    var keySize: Int {
        switch self {
        case .aes128GCM:
            16
        case .aes256GCM, .chacha20IETFPoly1305:
            32
        }
    }

    var saltSize: Int {
        keySize
    }

    var nonceSize: Int {
        12
    }

    var tagSize: Int {
        16
    }
}
