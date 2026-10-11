import Foundation

/// One part of a body of several parts: a field of text, or a file's bytes.
///
/// Nothing is refused here. A name that will not do is refused where the body is made
/// (`MultipartBody`), which is before anything is sent.
///
/// **Prints as its kind and its size**, and reflects as nothing more: a field's text is what
/// the person typed and a file's name is what they called it, and neither belongs in a log.
public struct MultipartPart: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    /// The most of a file's name that is kept, in bytes: what a file system allows one.
    static let fileNameBytes = 255

    let name: String
    /// A file's name — the last piece of the path handed in, and never the path — and what
    /// kind of bytes it holds. Both nil for a field.
    let fileName: String?
    let type: String?
    let data: Data

    public var description: String {
        "MultipartPart(\(fileName == nil ? "field" : "file"), \(data.count) bytes)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["bytes": data.count]) }

    /// A field of text, sent as its UTF-8.
    public static func field(_ name: String, _ value: String) -> MultipartPart {
        MultipartPart(name: name, fileName: nil, type: nil, data: Data(value.utf8))
    }

    /// A file's bytes, sent untouched. `type` is one plain type and subtype: `image/png`.
    ///
    /// `fileName` may be a whole path, where that is what the caller has: only its last piece
    /// is kept, here, so where the file stood on this device goes no further than this call.
    public static func file(_ name: String, named fileName: String, type: String, _ data: Data) -> MultipartPart {
        MultipartPart(name: name, fileName: lastPiece(of: fileName), type: type, data: data)
    }

    /// The last piece of a path — by either slash, since the name may come from anywhere — and
    /// no more of it than `fileNameBytes`: cut at a whole character, from the end of what
    /// stands before its extension, so a long name is still the kind of file it was. Empty
    /// where nothing is left.
    static func lastPiece(of path: String) -> String {
        guard let last = path.unicodeScalars.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last else {
            return ""
        }
        let piece = String(String.UnicodeScalarView(last))
        var stem = Substring(piece)
        var ending = Substring()
        // An ending longer than this is not an extension, and is cut like the rest.
        if let dot = piece.lastIndex(of: "."), dot != piece.startIndex, piece[dot...].utf8.count <= 16 {
            stem = piece[..<dot]
            ending = piece[dot...]
        }
        while stem.utf8.count + ending.utf8.count > fileNameBytes { stem.removeLast() }
        return String(stem + ending)
    }
}

/// Why a body of several parts was not made. **None of them carries what was refused**: a
/// name, a file's name and a typed text are the person's, and an error is something that gets
/// logged.
public enum MultipartError: Error, Equatable, Sendable {
    /// A part's name that is empty, or holds anything but ASCII letters, digits and `_-.[]`.
    case name
    /// A file with no name left once its path is taken off.
    case fileName
    /// A kind of bytes that is not one plain type and subtype.
    case type
    /// The whole body would be over `limit` bytes.
    case tooLarge(limit: Int)
    /// Every boundary drawn stood somewhere in a part.
    case boundary
}

/// A body of several parts — `multipart/form-data`, RFC 7578 — and the header that says so:
/// what a source wants where a file's bytes travel beside fields of text (#312).
///
/// **What comes from the person cannot write a header.** A part's lines are built from its
/// name, a file's name and its kind, and a line end or a quote in any of them would end the
/// line or the quotes and start one of the sender's choosing. So:
///
/// - a part's **name** is this app's own word for a setting, never the person's, and is refused
///   outright unless it is ASCII letters, digits and `_-.[]`;
/// - a **file's name** is the person's, and a picture named in Chinese is an ordinary one, so
///   it is not refused but written as RFC 7578 allows (§2): the last piece of its path alone,
///   and every byte of that outside letters, digits and `-._~` as `%XX`. That is more than a
///   browser escapes — it sends the name's UTF-8 as it is, and only `"` and the two line ends
///   as `%XX` — so a server that does not decode shows the literal `%XX`; Mastodon 4.6.6 took
///   such a name (`MastodonPartsCaptures`), and uses a file's name nowhere;
/// - a file's **kind** is refused unless it is one plain type and subtype, with no parameter.
///
/// A field's text and a file's bytes are the part's body, where nothing is read as a line —
/// but where the boundary must not stand. It is drawn at random for every body, and one a part
/// holds is not used.
///
/// **Prints as its size.** Its bytes are the parts'.
public struct MultipartBody: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// 32 MiB, on the whole body. A last line and not a working size: Mastodon takes a picture
    /// and a header of 8 MB each, so nothing a source accepts comes near it, and a caller that
    /// knows its source's own limit says that one first.
    public static let byteLimit = 32 << 20

    /// How many boundaries are drawn before giving up. A random one stands in a part by chance
    /// about never; several in a row means the draw is not random.
    static let draws = 4

    /// The `Content-Type` this body is sent under: it names the boundary.
    let contentType: String
    let data: Data

    public var description: String { "MultipartBody(\(data.count) bytes)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["bytes": data.count]) }

    init(_ parts: [MultipartPart], limit: Int = MultipartBody.byteLimit) throws {
        try self.init(parts, limit: limit, boundary: Self.randomBoundary)
    }

    /// `boundary` is the draw, handed in so a test can read exact bytes.
    ///
    /// The size is counted before a byte is copied, and each part's bytes are then copied once,
    /// into a body allotted whole.
    init(_ parts: [MultipartPart], limit: Int, boundary draw: () -> String) throws {
        let heads = try parts.map(Self.head)
        let inside = zip(heads, parts).reduce(0) { $0 + $1.0.count + $1.1.data.count + Self.lineEnd.count }
        for _ in 0..<Self.draws {
            let boundary = draw()
            let opening = Data("--\(boundary)\r\n".utf8)
            let closing = Data("--\(boundary)--\r\n".utf8)
            let size = inside + opening.count * parts.count + closing.count
            // Before the search below, which reads every byte: a body that will not be sent is
            // not worth reading through.
            guard size <= limit else { throw MultipartError.tooLarge(limit: limit) }
            let mark = Data(boundary.utf8)
            let taken = zip(heads, parts).contains { $0.range(of: mark) != nil || $1.data.range(of: mark) != nil }
            if taken { continue }

            var data = Data(capacity: size)
            for (head, part) in zip(heads, parts) {
                data.append(opening)
                data.append(head)
                data.append(part.data)
                data.append(Self.lineEnd)
            }
            data.append(closing)
            contentType = "multipart/form-data; boundary=\(boundary)"
            self.data = data
            return
        }
        throw MultipartError.boundary
    }

    private static let lineEnd = Data("\r\n".utf8)

    /// 122 random bits, as the system makes a UUID: letters, digits and hyphens, which a
    /// boundary may be without quoting.
    private static func randomBoundary() -> String {
        "fediqo-" + UUID().uuidString.lowercased()
    }

    /// A part's own lines, down to the empty one its body starts after.
    private static func head(_ part: MultipartPart) throws -> Data {
        guard !part.name.isEmpty, part.name.utf8.allSatisfy(inName.contains) else {
            throw MultipartError.name
        }
        var lines = "Content-Disposition: form-data; name=\"\(part.name)\""
        if let fileName = part.fileName, let type = part.type {
            guard !fileName.isEmpty else { throw MultipartError.fileName }
            let shown = shown(fileName: fileName)
            let pieces = type.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(inType.contains) }) else {
                throw MultipartError.type
            }
            lines += "; filename=\"\(shown)\"\r\nContent-Type: \(type)"
        }
        return Data((lines + "\r\n\r\n").utf8)
    }

    /// A file's name with every byte outside letters, digits and `-._~` as `%XX`.
    private static func shown(fileName: String) -> String {
        fileName.utf8.reduce(into: "") { shown, byte in
            if inFileName.contains(byte) {
                shown.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                shown += String(format: "%%%02X", byte)
            }
        }
    }

    private static let plain = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
    private static let inName = plain.union("_-.[]".utf8)
    private static let inFileName = plain.union("-._~".utf8)
    /// RFC 7230's `tchar`: what a type and a subtype are made of.
    private static let inType = plain.union("!#$%&'*+-.^_`|~".utf8)
}
