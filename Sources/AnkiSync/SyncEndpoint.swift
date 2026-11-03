//
//  SyncEndpoint.swift
//  AnkiSync
//
//  Created by Vladimir Gusev on 20.08.2026.
//

public import Foundation

/// Normalization for the user-configured sync server URL.
///
/// Three screens let the user set this — onboarding, the sync sheet, and
/// sync settings — and each carried its own copy of the scheme handling,
/// so a fix to one never reached the other two.
public enum SyncEndpoint: Sendable {
    public enum ValidationError: LocalizedError, Sendable {
        case empty
        case insecureScheme
        case malformed

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter a server address."
            case .insecureScheme:
                return """
                    http:// sends your username, password, and sync key in \
                    cleartext, so it is allowed only for LAN or Tailscale \
                    addresses. Use https:// for any other server.
                    """
            case .malformed:
                return "That doesn't look like a valid server address."
            }
        }
    }

    /// Trims, defaults a missing scheme to https, and rejects cleartext to
    /// anything but a private host.
    ///
    /// The `http://` rule matters more than it looks: App Transport
    /// Security does not cover this traffic. ATS governs
    /// NSURLSession/CFNetwork, but sync goes out through the Rust HTTP
    /// client inside AnkiRustLib, so the platform provides no backstop
    /// here — credentials really would travel in the clear. They are let
    /// through only to a LAN or tailnet host (`isPrivateHost`), where a
    /// self-hosted server rarely has a certificate.
    public static func normalized(_ raw: String) throws(ValidationError) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }

        let lowered = trimmed.lowercased()
        let withScheme: String
        if lowered.hasPrefix("http://") {
            guard isPrivateHost(authority: lowered.dropFirst("http://".count)) else {
                throw .insecureScheme
            }
            withScheme = trimmed
        } else {
            withScheme = lowered.hasPrefix("https://") ? trimmed : "https://" + trimmed
        }
        guard let url = URL(string: withScheme), url.host?.isEmpty == false else {
            throw .malformed
        }
        return withScheme
    }

    /// Whether the authority of a lowercased `http://` URL names a host on
    /// the LAN or the tailnet: `localhost`, `*.local`, `*.ts.net`, or an
    /// IPv4 address in 127/8, 10/8, 172.16/12, 192.168/16 or 100.64/10 (the
    /// CGNAT range Tailscale assigns from).
    ///
    /// Reads the authority off the string, not through `URL`, and admits
    /// nothing but `host[:port]`. Foundation and the Rust `url` crate that
    /// actually connects disagree on some inputs: `example.com\@10.0.0.1` is
    /// host `10.0.0.1` to Foundation but `example.com` to Rust, and Rust
    /// reads `010.0.0.1` as octal, `8.0.0.1`. Letters, digits, dots and
    /// hyphens without leading zeros leave the two nothing to disagree about.
    static func isPrivateHost(authority: Substring) -> Bool {
        let authority = authority.prefix { !"/?#".contains($0) }
        let hostAndPort = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard hostAndPort.count <= 2 else { return false }
        if hostAndPort.count == 2 {
            let port = hostAndPort[1]
            guard !port.isEmpty, port.allSatisfy({ ("0"..."9").contains($0) }) else {
                return false
            }
        }

        let host = hostAndPort[0]
        let hostCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !host.isEmpty, host.allSatisfy(hostCharacters.contains) else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") {
            return true
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = labels.compactMap { label -> UInt8? in
            guard label.allSatisfy({ ("0"..."9").contains($0) }),
                  label == "0" || !label.hasPrefix("0")
            else { return nil }
            return UInt8(label)
        }
        guard labels.count == 4, octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (172, 16...31), (192, 168), (100, 64...127):
            return true
        default:
            return false
        }
    }
}
