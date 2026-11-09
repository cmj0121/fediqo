/// Why a merge did not happen. Each one is its own sentence on screen.
public enum SyncRefusal: Error, Sendable, Equatable, Codable {
    case peerOlder                         // "<name> runs an older Fediqo: update it to merge"
    case peerNewer                         // "Fediqo here is older than on <name>: update it"
    case otherVersion(UInt8)               // internal; becomes peerOlder/peerNewer
    case notPaired                         // the device that answered is not the one paired
    case declined                          // a no, or no answer within answerWait: pair stays unmerged
    case unreadableHere                    // timelines here cannot be read: nothing written
    case unreadableThere
    case clockAhead                        // a stamp more than ten minutes past this clock
    case busy                              // a merge with that device is already under way
    case tooLarge
    case malformed
    case notAllowed                        // local-network permission refused
    case lost                              // the link dropped before both said applied
}
