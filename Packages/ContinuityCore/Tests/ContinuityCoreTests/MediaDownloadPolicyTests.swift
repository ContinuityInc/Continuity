import XCTest
@testable import ContinuityCore

final class MediaDownloadPolicyTests: XCTestCase {
    func testAllowsYouTubeMediaHosts() {
        XCTAssertTrue(MediaDownloadPolicy.isAllowedStreamHost("rr1---sn-abc.googlevideo.com"))
        XCTAssertTrue(MediaDownloadPolicy.isAllowedStreamHost("www.youtube.com"))
        XCTAssertTrue(MediaDownloadPolicy.isAllowedStreamHost("i.ytimg.com"))
        XCTAssertFalse(MediaDownloadPolicy.isAllowedStreamHost("evil.example"))
        XCTAssertFalse(MediaDownloadPolicy.isAllowedStreamHost("googlevideo.com.evil.example"))
    }

    func testRequiresHTTPS() {
        XCTAssertTrue(MediaDownloadPolicy.isAllowedStreamURL(
            URL(string: "https://rr1---sn-abc.googlevideo.com/videoplayback")!))
        XCTAssertFalse(MediaDownloadPolicy.isAllowedStreamURL(
            URL(string: "http://rr1---sn-abc.googlevideo.com/videoplayback")!))
        XCTAssertFalse(MediaDownloadPolicy.isAllowedStreamURL(
            URL(string: "https://evil.example/payload")!))
    }
}
