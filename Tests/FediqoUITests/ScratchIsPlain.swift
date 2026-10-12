import FediqoCore
import Testing

/// **Every scratch folder this target's tests make is a plain one** (#344): the process is told,
/// once, to ask for no protection class. A Mac opens no protected file again while its screen
/// is locked, and a suite must not pass or fail by whether somebody is at the machine.
///
/// Told here and nowhere else in the target. A trait is made when the tests are listed, which
/// is before any of them runs — whichever are then run, and in whatever order — so no test
/// makes a folder before this. **That order is argued, and seen, and not held by anything**:
/// the testing library promises nowhere that every trait is made before the first test runs.
/// Were it to stop being so, the test below would fail in a run where it lost the race, and
/// the rest would go back to passing or failing by the lock. The suites that hold the class
/// to the disk hand in `Guarded.Device.real` and are not touched by it.
struct ScratchIsPlain: SuiteTrait {
    init() {
        Guarded.askForNoClass()
    }
}

@Suite("This target's scratch folders are plain", ScratchIsPlain())
struct ScratchIsPlainTests {
    @Test("The process asks for no class")
    func asksForNone() {
        #expect(Guarded.Device.this.asks == nil)
    }
}
