import XCTest
@testable import ContinuityCore

final class TrackRenameTests: XCTestCase {
    func testTrimsAndCollapsesWhitespace() {
        let edit = TrackRename.normalized(title: "  Blinding   Lights \n", artist: "\tThe  Weeknd ")
        XCTAssertEqual(edit, TrackRename.Edit(title: "Blinding Lights", artist: "The Weeknd"))
    }

    func testBlankTitleIsRejected() {
        XCTAssertNil(TrackRename.normalized(title: "", artist: "Someone"))
        XCTAssertNil(TrackRename.normalized(title: "   \n\t", artist: "Someone"))
    }

    func testBlankArtistFallsBackToUnknown() {
        let edit = TrackRename.normalized(title: "Untitled", artist: "   ")
        XCTAssertEqual(edit?.artist, TrackRename.unknownArtist)
    }

    func testChangeDetection() {
        let edit = TrackRename.Edit(title: "Song", artist: "Artist")
        XCTAssertFalse(TrackRename.isChange(edit, fromTitle: "Song", artist: "Artist"))
        XCTAssertTrue(TrackRename.isChange(edit, fromTitle: "Song", artist: "Other"))
        XCTAssertTrue(TrackRename.isChange(edit, fromTitle: "Other", artist: "Artist"))
    }

    func testNormalizingAnExistingValueIsNotAChange() {
        // Re-saving an untouched sheet must read as "no change" so Save stays disabled.
        let edit = TrackRename.normalized(title: "Song", artist: "Artist")!
        XCTAssertFalse(TrackRename.isChange(edit, fromTitle: "Song", artist: "Artist"))
    }
}
