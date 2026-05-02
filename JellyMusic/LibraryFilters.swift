import Foundation

enum LibraryFilters {
    static func albums(_ albums: [JellyfinItem], matching query: String) -> [JellyfinItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard search.isEmpty == false else { return albums }
        return albums.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
                $0.displayArtist.localizedCaseInsensitiveContains(search)
        }
    }

    static func tracks(_ tracks: [JellyfinItem], matching query: String) -> [JellyfinItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard search.isEmpty == false else { return tracks }
        return tracks.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
                $0.displayArtist.localizedCaseInsensitiveContains(search) ||
                ($0.album?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }
}
