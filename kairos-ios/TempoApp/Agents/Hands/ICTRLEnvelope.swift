import CryptoKit
import Foundation
import Security

/// iCTRL protocol v1, client side: the sealed envelope every `/rpc` call travels in, and the X25519 key
/// unwrap done once at pairing. Byte-for-byte the construction of iCTRL's server (iCTRLKit/SecureEnvelope.swift
/// and JSONRPCServer.handlePair) and its reference client (Scripts/ictrl_rpc.py):
///
///     K          32-byte key handed out at pairing (the only secret we hold)
///     tok        hex of SHA256(K)[0..<4]  (a lookup id, not a secret)
///     nonce      16 random bytes per request;  ts = unix seconds (server allows ±120 s)
///     K_enc_req  = HMAC(K, "ictrl-v1|enc-req"  || nonce)
///     K_enc_resp = HMAC(K, "ictrl-v1|enc-resp" || nonce)
///     K_mac      = HMAC(K, "ictrl-v1|mac"      || nonce)
///     keystream  = HMAC(Kx, nonce || be32(0)) || HMAC(Kx, nonce || be32(1)) || …
///     request    ct = body XOR keystream(K_enc_req);  tag = HMAC(K_mac, "v1" || tok4 || be64(ts) || nonce || ct)
///     response   ct = body XOR keystream(K_enc_resp); tag = HMAC(K_mac, "resp" || nonce || ct)
///
/// Pairing (mode A): K_wrap = HMAC(X25519(client, device), "ictrl-pair" || clientPub || devicePub),
/// pad = HMAC(K_wrap, "ictrl-wrap"), K = token_ct XOR pad. No HKDF, no AEAD: HMAC-SHA256 only.
enum ICTRLEnvelope {
    static let labelMac = Data("ictrl-v1|mac".utf8)
    static let labelEncRequest = Data("ictrl-v1|enc-req".utf8)
    static let labelEncResponse = Data("ictrl-v1|enc-resp".utf8)
    static let labelPair = Data("ictrl-pair".utf8)
    static let labelWrap = Data("ictrl-wrap".utf8)

    enum Failure: Error, Equatable {
        case malformed  // not an envelope, or a field of the wrong shape
        case badTag     // the MAC doesn't match: tampered, wrong key, or not the reply to our request
        case badKey     // pairing produced something that isn't a 32-byte key
    }

    /// A request ready to POST to /rpc, plus the nonce its reply will be sealed under.
    struct Sealed {
        let body: Data
        let nonce: Data
    }

    // MARK: - Primitives

    static func hmac(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// PRF-CTR stream cipher: block i = HMAC-SHA256(key, nonce || be32(i)). The keyed HMAC state is built once
    /// and copied per block (CryptoKit's HMAC is a value type), so a large reply (a screenshot) stays cheap.
    static func keystreamXOR(key: Data, nonce: Data, data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let keyed = HMAC<SHA256>(key: SymmetricKey(data: key))
        let nonceBytes = [UInt8](nonce)
        var out = [UInt8](data)
        out.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let total = buffer.count
            var counter: UInt32 = 0
            var offset = 0
            while offset < total {
                var block = keyed
                block.update(data: nonceBytes)
                block.update(data: [UInt8(truncatingIfNeeded: counter >> 24), UInt8(truncatingIfNeeded: counter >> 16),
                                    UInt8(truncatingIfNeeded: counter >> 8), UInt8(truncatingIfNeeded: counter)])
                let mac = block.finalize()
                let n = min(32, total - offset)
                mac.withUnsafeBytes { stream in
                    guard let s = stream.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    let dst = base + offset
                    for i in 0..<n { dst[i] ^= s[i] }
                }
                offset += 32
                counter &+= 1
            }
        }
        return Data(out)
    }

    static func be64(_ value: UInt64) -> Data {
        Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> (UInt64($0) * 8)) })
    }

    /// The lookup id the server files a key under: hex of the first 4 bytes of SHA256(K).
    static func tokenID(for key: Data) -> String {
        hex(Data(SHA256.hash(data: key)).prefix(4))
    }

    /// Cryptographically random bytes (nonces).
    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess { return Data(bytes) }
        // SecRandomCopyBytes does not fail in practice; CryptoKit's generator is the fallback.
        return SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    // MARK: - Request / response

    /// Seals one JSON-RPC body. `ts` and `nonce` are parameters only so tests can use fixed vectors.
    static func sealRequest(_ plaintext: Data, key: Data, ts: Int? = nil, nonce: Data? = nil) throws -> Sealed {
        guard key.count == 32 else { throw Failure.badKey }
        let nonce = nonce ?? randomBytes(16)
        guard nonce.count == 16 else { throw Failure.malformed }
        let ts = ts ?? Int(Date().timeIntervalSince1970)
        let tokHex = tokenID(for: key)
        let tok4 = Data(SHA256.hash(data: key)).prefix(4)

        let kEnc = hmac(key, labelEncRequest + nonce)
        let kMac = hmac(key, labelMac + nonce)
        let ct = keystreamXOR(key: kEnc, nonce: nonce, data: plaintext)
        let signed = Data("v1".utf8) + tok4 + be64(UInt64(max(ts, 0))) + nonce + ct
        let tag = hmac(kMac, signed)

        let envelope: [String: Any] = [
            "v": 1,
            "tok": tokHex,
            "ts": ts,
            "nonce": hex(nonce),
            "ct": ct.base64EncodedString(),
            "tag": hex(tag),
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return Sealed(body: body, nonce: nonce)
    }

    /// Verifies (before decrypting) and decrypts the server's reply to the request sealed with `nonce`.
    static func openResponse(_ body: Data, key: Data, nonce: Data) throws -> Data {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let ctB64 = obj["ct"] as? String, let ct = Data(base64Encoded: ctB64),
              let tagHex = obj["tag"] as? String, let tag = data(hex: tagHex), tag.count == 32 else {
            throw Failure.malformed
        }
        // The reply must be sealed under OUR nonce; the MAC below binds it anyway.
        if let echoed = obj["nonce"] as? String, echoed.lowercased() != hex(nonce) { throw Failure.badTag }
        let kMac = hmac(key, labelMac + nonce)
        let signed = Data("resp".utf8) + nonce + ct
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: signed, using: SymmetricKey(data: kMac)) else {
            throw Failure.badTag
        }
        let kEncResp = hmac(key, labelEncResponse + nonce)
        return keystreamXOR(key: kEncResp, nonce: nonce, data: ct)
    }

    // MARK: - Pairing (X25519, mode A)

    /// What the phone shows on its Allow prompt: hex of SHA256(our public key)[0..<4].
    static func fingerprint(publicKey: Data) -> String {
        hex(Data(SHA256.hash(data: publicKey)).prefix(4))
    }

    /// Recovers K from the /pair reply ({tok, pub, token_ct}) with our one-time private key.
    static func unwrapPairedKey(tokenCiphertextHex: String, devicePublicKeyBase64: String,
                                clientPrivateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard let tokenCT = data(hex: tokenCiphertextHex), tokenCT.count == 32,
              let devicePub = Data(base64Encoded: devicePublicKeyBase64), devicePub.count == 32 else {
            throw Failure.malformed
        }
        let peer: Curve25519.KeyAgreement.PublicKey
        let shared: SharedSecret
        do {
            peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePub)
            shared = try clientPrivateKey.sharedSecretFromKeyAgreement(with: peer)
        } catch {
            throw Failure.badKey
        }
        let sharedData = shared.withUnsafeBytes { Data($0) }
        let clientPub = clientPrivateKey.publicKey.rawRepresentation
        let kWrap = hmac(sharedData, labelPair + clientPub + devicePub)
        let pad = hmac(kWrap, labelWrap)
        return Data(zip(tokenCT, pad).map { $0 ^ $1 })
    }

    // MARK: - Hex (own names, so nothing clashes with a Data extension elsewhere in the app)

    static func hex<D: DataProtocol>(_ bytes: D) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func data(hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return Data(out)
    }
}
