// Whatever Browser – Made by Humans from OpenPeeps
//
//     Copyright (C) 2026 George Lemon <georgelemon@protonmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import CryptoKit
import Foundation
import Security

/// What the site-information card shows about a page's TLS certificate.
///
/// Captured from the server-trust challenge during the handshake, which is
/// the only moment WebKit hands the host app the trust object — there is no
/// handle to ask for it later. Public Security APIs throughout: the issuer
/// reads as its subject (no OID parsing), and validity comes from the
/// standard validity OIDs.
struct SiteCertificateInfo: Equatable, Sendable {
    /// Lowercased host the handshake served this chain to.
    var host: String
    /// Leaf subject (who the certificate was issued to), if readable.
    var subject: String?
    /// Issuer, read as the parent certificate's subject, if the chain has one.
    var issuer: String?
    var validFrom: Date?
    var validUntil: Date?
    /// Leaf SHA-256 over the DER bytes, colon-separated uppercase hex.
    var sha256Fingerprint: String?
    /// Certificates in the served chain, leaf first.
    var chainDepth: Int

    /// Snapshots `trust` into plain values. The trust object itself is not
    /// kept: evaluating or retaining it past the challenge is the
    /// challenge handler's business, not the card's.
    static func make(trust: SecTrust, host: String) -> SiteCertificateInfo? {
        let depth = SecTrustGetCertificateCount(trust)
        guard depth > 0, let leaf = SecTrustGetCertificateAtIndex(trust, 0) else {
            return nil
        }
        var issuer: String?
        if depth > 1, let parent = SecTrustGetCertificateAtIndex(trust, 1) {
            issuer = SecCertificateCopySubjectSummary(parent) as String?
        }
        let (from, until) = validity(of: leaf)
        return SiteCertificateInfo(
            host: host,
            subject: SecCertificateCopySubjectSummary(leaf) as String?,
            issuer: issuer,
            validFrom: from,
            validUntil: until,
            sha256Fingerprint: fingerprint(of: leaf),
            chainDepth: depth
        )
    }

    /// Not-before / not-after from the leaf, as calendar dates. Missing or
    /// unreadable values stay nil rather than guessing.
    static func validity(of certificate: SecCertificate) -> (from: Date?, until: Date?) {
        let oids = [
            kSecOIDX509V1ValidityNotBefore as String,
            kSecOIDX509V1ValidityNotAfter as String,
        ] as CFArray
        guard let values = SecCertificateCopyValues(certificate, oids, nil) as? [String: Any] else {
            return (nil, nil)
        }
        func date(for oid: String) -> Date? {
            guard let entry = values[oid] as? [String: Any],
                  let absolute = entry[kSecPropertyKeyValue as String] as? Double
            else {
                return nil
            }
            return Date(timeIntervalSinceReferenceDate: absolute)
        }
        return (
            date(for: kSecOIDX509V1ValidityNotBefore as String),
            date(for: kSecOIDX509V1ValidityNotAfter as String)
        )
    }

    /// Uppercase colon-separated SHA-256 over the leaf's DER bytes, the
    /// shape certificate viewers print. Static so the formatting is
    /// testable without minting certificates.
    static func fingerprintHex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Short calendar date, locale-independent so tests and screenshots
    /// agree: 2026-10-10, never "10/10/26" in one locale and "10.10."
    /// in another.
    static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func fingerprint(of certificate: SecCertificate) -> String? {
        guard let der = SecCertificateCopyData(certificate) as Data? else {
            return nil
        }
        return fingerprintHex(SHA256.hash(data: der))
    }
}
