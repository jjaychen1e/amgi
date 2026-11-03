//
//  SyncEndpointTests.swift
//  AnkiSyncTests
//
//  Created by Junjie Chen on 03.11.2026.
//

import Testing
@testable import AnkiSync

/// `http://` is kept only for LAN and Tailscale hosts: sync goes through the
/// Rust client, outside ATS, so this check is the only thing standing between
/// the user's credentials and a cleartext connection to a public server.
@Suite("SyncEndpoint")
struct SyncEndpointTests {

    @Test("keeps http:// as typed for a private host", arguments: [
        "http://100.120.229.53:18765/",
        "http://mymac.local:18765/",
        "http://192.168.1.5/",
        "http://localhost:8080/",
        "http://10.0.0.2/",
        "http://172.16.0.1/",
        "http://172.31.255.255/",
        "http://127.0.0.1:27701/",
        "http://100.64.0.1/",
        "http://100.127.255.254/",
        "http://my-mac.tail1234.ts.net:8080/sync",
        "HTTP://MyMac.local:18765/",
    ])
    func acceptsPrivateHTTP(_ raw: String) throws {
        #expect(try SyncEndpoint.normalized(raw) == raw)
    }

    @Test("rejects http:// for a public host", arguments: [
        "http://example.com/",
        "http://8.8.8.8/",
        "http://172.15.0.1/",
        "http://172.32.0.1/",
        "http://100.63.255.255/",
        "http://100.128.0.1/",
        "http://192.169.0.1/",
        "http://10.0.0.1.example.com/",
        "http://local/",
        "http://evil-local/",
        "http://ts.net/",
    ])
    func rejectsPublicHTTP(_ raw: String) {
        #expect(throws: SyncEndpoint.ValidationError.insecureScheme) {
            try SyncEndpoint.normalized(raw)
        }
    }

    /// Foundation and the Rust `url` crate read these hosts differently, so a
    /// check through `URL` would pass them while Rust connects elsewhere.
    @Test("rejects http:// a URL parser could misread as private", arguments: [
        #"http://example.com\@10.0.0.1/"#,  // Rust: host example.com
        "http://10.0.0.1@example.com/",      // userinfo, host example.com
        "http://010.0.0.1/",                 // Rust: octal, 8.0.0.1
        "http://10.0.0.1:/",
        "http://[::1]/",
    ])
    func rejectsAmbiguousHTTP(_ raw: String) {
        #expect(throws: SyncEndpoint.ValidationError.insecureScheme) {
            try SyncEndpoint.normalized(raw)
        }
    }

    @Test func keepsHTTPS() throws {
        #expect(try SyncEndpoint.normalized("https://example.com/") == "https://example.com/")
    }

    @Test func defaultsMissingSchemeToHTTPS() throws {
        #expect(try SyncEndpoint.normalized("example.com") == "https://example.com")
        #expect(try SyncEndpoint.normalized("  192.168.1.5:8080 ") == "https://192.168.1.5:8080")
    }

    @Test func rejectsEmpty() {
        #expect(throws: SyncEndpoint.ValidationError.empty) {
            try SyncEndpoint.normalized("   ")
        }
    }
}
