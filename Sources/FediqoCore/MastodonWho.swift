import Foundation

/// Who a source's account check says a sign-in is (#347): the id it gives the account, and the
/// account's handle as `@user@host`.
///
/// **Who it is, is the id**: two sign-ins are one account only by the same id, never by a
/// handle. The handle is the source's word for a name, and is taken only where it can be this
/// source's own.
public struct MastodonWho: Equatable, Sendable {
    public let id: String?
    public let handle: String?
    /// How many people ask to follow the account (#313), where the check said: **the source's
    /// figure at that check, and nothing where it said none** — never a count of anything here.
    public let asking: Int?
    /// What the server's role lets the account do there (#380), as the check said: nothing
    /// where it named no role, or one it could not read. **The standing tending is drawn by** —
    /// never the words a sign-in holds.
    public let staff: MastodonStaff?

    public init(id: String?, handle: String?, asking: Int? = nil, staff: MastodonStaff? = nil) {
        self.id = id
        self.handle = handle
        self.asking = asking
        self.staff = staff
    }

    /// What the check's answer says through a sign-in at `host`: nobody, where it is no
    /// account at all. Each half stands without the other.
    ///
    /// An id that is nothing, or longer than an id may run (`MastodonOAuth.clientBytes`), is
    /// none.
    static func said(_ body: Data, at host: String) -> MastodonWho {
        struct Me: Decodable {
            let id: String?
            let acct: String?
            let source: Mine?
            let role: StatusDTO.Lenient<Role>?
        }
        /// The account's role, as far as its standing: the flags, a decimal string.
        struct Role: Decodable {
            let permissions: StatusDTO.Lenient<String>?
            let number: StatusDTO.Lenient<UInt64>?

            enum CodingKeys: String, CodingKey {
                case permissions
            }

            init(from decoder: any Decoder) throws {
                let keys = try decoder.container(keyedBy: CodingKeys.self)
                permissions = try? keys.decode(StatusDTO.Lenient<String>.self, forKey: .permissions)
                number = try? keys.decode(StatusDTO.Lenient<UInt64>.self, forKey: .permissions)
            }
        }
        /// What the check says of the account to its owner alone.
        struct Mine: Decodable {
            let followRequestsCount: Int?

            enum CodingKeys: String, CodingKey {
                case followRequestsCount = "follow_requests_count"
            }

            /// Lenient: a figure that is no number is no figure, and the rest of the check stands.
            init(from decoder: any Decoder) throws {
                followRequestsCount = try? decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .followRequestsCount)
            }
        }
        guard let me = try? JSONDecoder().decode(Me.self, from: body) else { return MastodonWho(id: nil, handle: nil) }
        let id = me.id.flatMap { $0.isEmpty || $0.utf8.count > MastodonOAuth.clientBytes ? nil : $0 }
        // Said only of an account the check named, and never a figure below nothing.
        let asking = id == nil ? nil : me.source?.followRequestsCount.flatMap { $0 >= 0 ? $0 : nil }
        // Said only of an account the check named.
        let staff = id == nil ? nil : (me.role?.value).flatMap { MastodonStaff.said($0.permissions, number: $0.number) }
        return MastodonWho(id: id, handle: me.acct.flatMap { ownHandle($0, at: host) }, asking: asking, staff: staff)
    }

    /// The handle of the account a sign-in at `host` signs in, from the name its check gave —
    /// or nothing, where that is not a name of this very source.
    ///
    /// **The reader's own account lives where they signed in**, so a name carrying another
    /// host is not theirs here: taken, it would open another server's account as "your page"
    /// and call its posts the reader's own. **And a name is taken as it was sent or not at
    /// all**: it is compared with the handle a post carries, so one this would have to mend —
    /// a control or format character, a space, a line break, more than a name may run
    /// (`LineText.nameLength`) — names nobody. **Nor does one not spelled as a name at a
    /// server is**: the marks a typed name may carry (`PersonAddress.isName`), and of letters
    /// and digits only the plain ones, so a letter that only looks like another names nobody.
    static func ownHandle(_ acct: String, at host: String) -> String? {
        let parts = acct.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let name = parts.first else { return nil }
        if parts.count == 2, parts[1].lowercased() != host.lowercased() { return nil }
        guard !name.isEmpty, !name.contains(where: \.isWhitespace), LineText.oneLine(name) == name else { return nil }
        guard PersonAddress.isName(name), name.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return StatusDTO.handle(name, host: host.lowercased())
    }

    /// A handle written beside a sign-in at `host`, as it is taken today: by the rule a
    /// check's answer is (`ownHandle`), under the mark it was written with. **A build before
    /// that rule wrote whatever its source sent**, so what is read back is held to it too.
    public static func kept(_ handle: String, at host: String) -> String? {
        guard handle.hasPrefix("@") else { return nil }
        return ownHandle(String(handle.dropFirst()), at: host)
    }
}
