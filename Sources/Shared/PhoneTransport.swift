import Foundation
import Network

/// A TLS pre-shared key and the identity that selects it.
struct PhoneCredential: Equatable {
    let id: String
    let key: Data
}

/// The encrypted channel between the Mac and the phone: TLS 1.2 with a pre-shared key and ECDHE
/// (TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256). Both ends prove they hold the key in the handshake, so there is no
/// certificate to trust, and the ECDHE part keeps recorded traffic unreadable if a key leaks later.
enum PhoneTransport {
    static let ciphersuite = tls_ciphersuite_t(rawValue: 0xCCAC)!

    /// A server accepts any of the credentials; a client gives exactly one.
    static func parameters(_ credentials: [PhoneCredential]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for credential in credentials {
            sec_protocol_options_add_pre_shared_key(options, data(credential.key) as __DispatchData,
                                                    data(Data(credential.id.utf8)) as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(options, ciphersuite)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private static func data(_ bytes: Data) -> DispatchData {
        bytes.withUnsafeBytes { DispatchData(bytes: $0) }
    }
}
