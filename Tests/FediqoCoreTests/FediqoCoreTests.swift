import Testing
@testable import FediqoCore

@Suite("Fediqo")
struct FediqoCoreTests {
    @Test("The package still answers to its name")
    func name() {
        #expect(Fediqo.name == "Fediqo")
        #expect(Fediqo.isNamed("Fediqo"))
        #expect(!Fediqo.isNamed("not"))
    }
}
