import XCTest
@testable import JellyMusic

final class LibraryFiltersTests: XCTestCase {
    func testTrackSearchMatchesTitleArtistAndAlbum() {
        let tracks = [
            JellyfinItem(id: "1", name: "Blue Train", type: "Audio", albumArtist: "John Coltrane", album: "Blue Train"),
            JellyfinItem(id: "2", name: "So What", type: "Audio", albumArtist: "Miles Davis", album: "Kind of Blue")
        ]

        XCTAssertEqual(LibraryFilters.tracks(tracks, matching: "miles").map(\.id), ["2"])
        XCTAssertEqual(LibraryFilters.tracks(tracks, matching: "blue").map(\.id), ["1", "2"])
        XCTAssertEqual(LibraryFilters.tracks(tracks, matching: "   ").count, 2)
    }

    func testAlbumSearchMatchesTitleAndArtist() {
        let albums = [
            JellyfinItem(id: "1", name: "Discovery", type: "MusicAlbum", albumArtist: "Daft Punk"),
            JellyfinItem(id: "2", name: "Homework", type: "MusicAlbum", albumArtist: "Daft Punk")
        ]

        XCTAssertEqual(LibraryFilters.albums(albums, matching: "home").map(\.id), ["2"])
        XCTAssertEqual(LibraryFilters.albums(albums, matching: "daft").count, 2)
    }
}
