import Foundation
import GRDB

/// What counts as a word, for the one index that has to answer in two languages.
///
/// FTS5 takes one tokenizer, and this app is read in English and in 繁體中文. The stock ones
/// answer only the first of those, which was measured rather than assumed — two posts, one in
/// each language, and every stock tokenizer asked for a word from inside them:
///
/// ```text
/// unicode61   伺服器=0  公開=0  貼文=0  emoji=1  server=1
/// porter      伺服器=0  公開=0  貼文=0  emoji=1  server=1
/// trigram     伺服器=1  公開=0  貼文=0  emoji=1  server=1
/// words       伺服器=1  公開=1  貼文=1  emoji=1  server=1
/// ```
///
/// `unicode61` — which is what "undecided" meant, because it is FTS5's default — splits on
/// Unicode word boundaries, and Chinese is written without them. A sentence of it becomes one
/// enormous token, and a reader searching their own language finds nothing at all. `porter` is
/// `unicode61` with English stemming on top and inherits the hole. `trigram` indexes every
/// three-character window, which reaches three-character Chinese and stops there — and most
/// Chinese words are two characters, which is the row above saying so.
///
/// So: everything that is not CJK goes to `unicode61`, which is the right answer for it and is
/// somebody else's careful work; CJK is split into single characters. A query is broken the
/// same way by the same tokenizer, so `公開` becomes `公` `開` on both sides and matches as the
/// phrase it is. One character is a word in Chinese often enough for that to be a fact about
/// the language rather than a convenience.
///
/// **The cost, said out loud.** A tokenizer of our own is a piece of the schema that is not in
/// the schema file: a connection that has not registered it cannot write a post at all, because
/// the triggers on `posts` write into `posts_fts` on every insert. `LocalStore` registers it on
/// every connection it opens, so nothing inside this app can meet that — but `sqlite3` at a
/// terminal will not open this store's index, and that is a real thing to have given up. It was
/// given up on purpose: the alternative is writing pre-split text from Swift instead, which
/// means dropping the three triggers, and `schema.sql` says in its second line that only
/// `posts_fts` may be rebuilt. Rebuilding it with a different tokenizer is the door that was
/// left open; dropping triggers is not.
final class Words: FTS5WrapperTokenizer {
    /// The name the schema spells in `tokenize=`. It is written down in two places, which is
    /// once more than anybody would like — SQL cannot ask Swift for a constant.
    static let name = "words"

    let wrappedTokenizer: any FTS5Tokenizer

    init(db: Database, arguments: [String]) throws {
        wrappedTokenizer = try db.makeTokenizer(.unicode61())
    }

    /// The CJK block, as one range rather than the dozen the standard cuts it into.
    ///
    /// It covers the punctuation and symbols at `3000`, the two kana, the Hangul compatibility
    /// jamo, and the whole of the unified ideographs. Splitting a run of it per character is
    /// right for all of them for the same reason: none is written with spaces between words.
    /// Deliberately not the extension planes — a character outside this that arrives inside a
    /// token is a character `unicode61` already had an answer for.
    private static let cjk: ClosedRange<UInt32> = 0x3000...0x9FFF

    func accept(token: String, flags: FTS5TokenFlags, for tokenization: FTS5Tokenization,
                tokenCallback: (String, FTS5TokenFlags) throws -> Void) throws {
        // A token arrives already cut by `unicode61`, so a mixed sentence has handed us its
        // Latin words separately and its Chinese in one piece. Only the piece is cut again.
        guard token.unicodeScalars.contains(where: { Self.cjk.contains($0.value) }) else {
            return try tokenCallback(token, flags)
        }
        for character in token {
            try tokenCallback(String(character), flags)
        }
    }
}
