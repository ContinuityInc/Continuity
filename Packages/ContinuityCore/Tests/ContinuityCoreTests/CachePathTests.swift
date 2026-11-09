import XCTest
@testable import ContinuityCore

final class CachePathTests: XCTestCase {
    func testSafeFileNames() {
        XCTAssertTrue(CachePath.isSafeFileName("abcd1234.m4a"))
        XCTAssertTrue(CachePath.isSafeFileName("uuid-artwork.jpg"))
        XCTAssertFalse(CachePath.isSafeFileName("../escape.m4a"))
        XCTAssertFalse(CachePath.isSafeFileName("foo/bar.m4a"))
        XCTAssertFalse(CachePath.isSafeFileName("foo\\bar.m4a"))
        XCTAssertFalse(CachePath.isSafeFileName(""))
        XCTAssertFalse(CachePath.isSafeFileName(".."))
        XCTAssertFalse(CachePath.isSafeFileName("."))
    }

    func testContainerAllowlist() {
        XCTAssertEqual(CachePath.sanitizedContainer("M4A"), "m4a")
        XCTAssertEqual(CachePath.sanitizedContainer("webm"), "webm")
        XCTAssertNil(CachePath.sanitizedContainer("../x"))
        XCTAssertNil(CachePath.sanitizedContainer("exe"))
        XCTAssertEqual(CachePath.coercedContainer("nope"), "m4a")
    }
}
