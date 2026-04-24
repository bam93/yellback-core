import XCTest
@testable import YellBackCore

final class YellBackCoreTests: XCTestCase {
    /// Trivial smoke test: confirms the package builds, the module imports,
    /// and a public type can be instantiated. Real per-detector tests arrive
    /// as each detector is implemented.
    func testPackageCompilesAndImports() {
        let engine = YellBackEngine(config: EngineConfig())
        engine.stop()
    }
}
