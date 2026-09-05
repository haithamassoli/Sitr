import Testing
@testable import SitrCore

@Test func versionIsSet() {
    #expect(!SitrCore.version.isEmpty)
}
