import CryptoKit
import Foundation
@testable import PaperKnifeCore

/// Single-page PDFs protected by the standard security handler (RC4, revision 2 or 3) with an
/// empty user password: they open without a password but carry the given permission flags.
/// Implements algorithms 1 to 5 of ISO 32000-1, section 7.6.3.
enum EncryptedPdf {
    private static let passwordPadding = bytes(hex: "28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A")

    private static let fileId = bytes(hex: "5061706572B46E69666554657374AA01")

    static func singlePage(_ content: String, _ permissions: Int32, _ revision: Int) throws -> PdfSnapshot {
        let keyLength = revision >= 3 ? 16 : 5
        let owner = ownerValue("owner", revision, keyLength)
        let key = fileKey(owner, permissions, revision, keyLength)
        let user = userValue(key, revision)
        let stream = rc4(objectKey(key, 4), Latin1.bytes(content))
        let encrypt = revision >= 3
            ? "<< /Filter /Standard /V 2 /R \(revision) /Length 128 /O <\(hex(owner))> /U <\(hex(user))> /P \(permissions) >>"
            : "<< /Filter /Standard /V 1 /R 2 /O <\(hex(owner))> /U <\(hex(user))> /P \(permissions) >>"

        var pdf: [UInt8] = []
        var offsets: [Int] = []
        func write(_ text: String) {
            pdf.append(contentsOf: Latin1.bytes(text))
        }

        func writeObject(_ number: Int, _ body: String) {
            offsets.append(pdf.count)
            write("\(number) 0 obj\n\(body)\nendobj\n")
        }

        write("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n")
        writeObject(1, "<< /Type /Catalog /Pages 2 0 R >>")
        writeObject(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        writeObject(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        offsets.append(pdf.count)
        write("4 0 obj\n<< /Length \(stream.count) >>\nstream\n")
        pdf.append(contentsOf: stream)
        write("\nendstream\nendobj\n")
        writeObject(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        writeObject(6, encrypt)

        let xref = pdf.count
        write("xref\n0 7\n0000000000 65535 f \n")
        for offset in offsets {
            write("\(PdfiumFixtures.d10(offset)) 00000 n \n")
        }

        let id = hex(fileId)
        write("trailer\n<< /Size 7 /Root 1 0 R /Encrypt 6 0 R /ID [<\(id)> <\(id)>] >>\nstartxref\n\(xref)\n%%EOF\n")
        return try PdfSnapshot.fromBytes(pdf)
    }

    // Algorithm 3: the O entry for the given owner password and an empty user password.
    private static func ownerValue(_ ownerPassword: String, _ revision: Int, _ keyLength: Int) -> [UInt8] {
        var hash = md5(pad(ownerPassword))
        if revision >= 3 {
            for _ in 0..<50 {
                hash = md5(hash)
            }
        }

        let rc4Key = Array(hash[0..<keyLength])
        var value = rc4(rc4Key, pad(""))
        if revision >= 3 {
            for i in 1...19 {
                value = rc4(xor(rc4Key, i), value)
            }
        }

        return value
    }

    // Algorithm 2: the file encryption key for the empty user password.
    private static func fileKey(_ owner: [UInt8], _ permissions: Int32, _ revision: Int, _ keyLength: Int) -> [UInt8] {
        let p = UInt32(bitPattern: permissions)
        let permissionBytes = [UInt8(p & 0xFF), UInt8((p >> 8) & 0xFF), UInt8((p >> 16) & 0xFF), UInt8(p >> 24)]
        var hash = md5(pad("") + owner + permissionBytes + fileId)
        if revision >= 3 {
            for _ in 0..<50 {
                hash = md5(Array(hash[0..<keyLength]))
            }
        }

        return Array(hash[0..<keyLength])
    }

    // Algorithms 4 (revision 2) and 5 (revision 3): the U entry.
    private static func userValue(_ key: [UInt8], _ revision: Int) -> [UInt8] {
        if revision < 3 {
            return rc4(key, passwordPadding)
        }

        var value = rc4(key, md5(passwordPadding + fileId))
        for i in 1...19 {
            value = rc4(xor(key, i), value)
        }

        return value + [UInt8](repeating: 0, count: 16)
    }

    // Algorithm 1: the key for the strings and streams of one object (generation 0).
    private static func objectKey(_ key: [UInt8], _ objectNumber: Int) -> [UInt8] {
        let suffix = [UInt8(objectNumber & 0xFF), UInt8((objectNumber >> 8) & 0xFF), UInt8((objectNumber >> 16) & 0xFF), 0, 0]
        return Array(md5(key + suffix)[0..<min(key.count + 5, 16)])
    }

    private static func pad(_ password: String) -> [UInt8] {
        let bytes = Latin1.bytes(password)
        let length = min(bytes.count, 32)
        return Array(bytes[0..<length]) + Array(passwordPadding[0..<(32 - length)])
    }

    private static func xor(_ key: [UInt8], _ value: Int) -> [UInt8] { key.map { $0 ^ UInt8(value) } }

    private static func md5(_ data: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: data)) }

    private static func rc4(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var s = (0..<256).map { UInt8($0) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xFF
            s.swapAt(i, j)
        }

        var output = [UInt8](repeating: 0, count: data.count)
        var i = 0
        j = 0
        for n in 0..<data.count {
            i = (i + 1) & 0xFF
            j = (j + Int(s[i])) & 0xFF
            s.swapAt(i, j)
            output[n] = data[n] ^ s[(Int(s[i]) + Int(s[j])) & 0xFF]
        }

        return output
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            let digits = String(byte, radix: 16, uppercase: true)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    private static func bytes(hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(decoding: digits[$0..<($0 + 2)], as: UTF8.self), radix: 16)! }
    }
}
