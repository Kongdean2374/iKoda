import Foundation

// Signed-in WEB_REMIX responses: the account menu, the library pages and the
// answers to account writes. Koda can't sign in to probe these, so the paths
// follow Koda for Android's production parsers (YouTubeAccount.kt,
// MusicResponseParsers.kt, PlaylistEditing.kt, PlaylistMembership.kt); the rows
// inside them are the same renderers Rows reads signed out. The verdict and the
// signed-out answers were probed in October 2026.

enum AccountPages {
    // MARK: Verdict

    /// YouTube's `logged_in` for the request, from `responseContext.serviceTrackingParams`
    /// (GFEEDBACK carries it): false when a signed request was answered as anonymous.
    /// Nil when the response doesn't say, which proves nothing either way.
    static func signedIn(_ root: JSON) -> Bool? {
        for service in root["responseContext"]["serviceTrackingParams"].array {
            for param in service["params"].array where param["key"].string == "logged_in" {
                switch param["value"].string {
                case "1": return true
                case "0": return false
                default: break
                }
            }
        }
        return nil
    }

    // MARK: Account menu (account/account_menu)

    static func accountInfo(_ root: JSON) -> AccountInfo? {
        let popup = root["actions"][0]["openPopupAction"]["popup"]["multiPageMenuRenderer"]
        let header = popup["header"]["activeAccountHeaderRenderer"].exists
            ? popup["header"]["activeAccountHeaderRenderer"]
            : root.first("activeAccountHeaderRenderer")
        guard let name = header["accountName"].text.nonEmptyString else { return nil }
        let photo = header["accountPhoto"].bestThumbnail ?? header["avatar"].bestThumbnail ?? header.bestThumbnail
        // "Your channel" links the account's own channel; the menu's other links go elsewhere.
        let channel = popup["sections"].objects("compactLinkRenderer").lazy
            .compactMap { $0["navigationEndpoint"].browseTarget?.id }
            .first { $0.hasPrefix("UC") }
        return AccountInfo(
            name: name,
            handle: header["channelHandle"].text.nonEmptyString,
            channelId: channel,
            photo: photo,
            datasyncId: root["responseContext"]["mainAppWebResponseContext"]["datasyncId"].nonEmpty)
    }

    // MARK: Library pages (FEmusic_liked_videos, _liked_playlists, _liked_albums, _library_corpus_artists)

    /// Where a library page and its continuations keep their items: a list shelf of rows
    /// or a grid of cards first, then the legacy and modern continuation shapes.
    private static func libraryContainers(_ root: JSON) -> [JSON] {
        root.objects("musicShelfRenderer") + root.objects("gridRenderer")
            + root.objects("musicShelfContinuation") + root.objects("gridContinuation")
            + root.objects("appendContinuationItemsAction")
    }

    static func hasLibraryContainer(_ root: JSON) -> Bool {
        let containers = libraryContainers(root)
        return !containers.isEmpty && containers.allSatisfy {
            $0["contents"].raw is [Any] || $0["items"].raw is [Any] || $0["continuationItems"].raw is [Any]
        }
    }

    /// An authoritative directory may remove formerly cached entries. An unknown
    /// row or malformed container must therefore fail, never become an empty catalog.
    static func completeLibraryItems(_ root: JSON) throws -> [MusicItem] {
        guard hasLibraryContainer(root) else { throw CloudPlaylistError.incompleteResponse }
        let containers = libraryContainers(root)
        for scope in containers where scope["continuations"].exists {
            guard scope["continuations"].raw is [Any], scope["continuations"].array.allSatisfy({
                $0["nextContinuationData"]["continuation"].nonEmpty != nil
            }) else { throw CloudPlaylistError.incompleteResponse }
        }
        let entries = containers.flatMap { $0["contents"].array + $0["items"].array + $0["continuationItems"].array }
        var items: [MusicItem] = []
        for entry in entries {
            if let item = libraryItem(entry) {
                items.append(item)
            } else if entry["continuationItemRenderer"].exists {
                // Pagination controls are not playlists, but a missing token cannot
                // be mistaken for the end of an otherwise complete directory.
                guard entry["continuationItemRenderer"].first("continuationCommand")["token"].nonEmpty != nil else {
                    throw CloudPlaylistError.incompleteResponse
                }
            } else if isNewPlaylistCard(entry) {
                // The library's New playlist card does not represent a remote item.
                continue
            } else {
                throw CloudPlaylistError.incompleteResponse
            }
        }
        return Pages.dedupe(items)
    }

    static func libraryItems(_ root: JSON) -> [MusicItem] {
        let entries = libraryContainers(root).flatMap { $0["contents"].array + $0["items"].array + $0["continuationItems"].array }
        return Pages.dedupe(entries.compactMap(libraryItem))
    }

    /// Unknown cards can coexist with known remote IDs in the browsing directory.
    /// Unlike completeLibraryItems, this explicitly reports any discarded content;
    /// it can never be mistaken for an authoritative empty library.
    static func playlistCatalogPage(_ root: JSON) -> CloudPlaylistCatalogPage {
        let containers = libraryContainers(root)
        var issues: [CloudPlaylistCatalogIssue] = []
        var playlists: [PlaylistSummary] = []
        var unknownEntries = 0
        var invalidContinuation = false
        if containers.isEmpty { issues.append(.unrecognizedPage) }
        for scope in containers {
            guard scope["contents"].raw is [Any] || scope["items"].raw is [Any] || scope["continuationItems"].raw is [Any] else {
                if !issues.contains(.unrecognizedPage) { issues.append(.unrecognizedPage) }
                continue
            }
            if scope["continuations"].exists,
               !(scope["continuations"].raw is [Any]) || !scope["continuations"].array.allSatisfy({
                   $0["nextContinuationData"]["continuation"].nonEmpty != nil
               }) {
                invalidContinuation = true
            }
            for entry in scope["contents"].array + scope["items"].array + scope["continuationItems"].array {
                if let item = libraryItem(entry) {
                    if case .playlist(let playlist) = item, playlist.id != "LM", playlist.id != "SE" {
                        playlists.append(playlist)
                    }
                } else if entry["continuationItemRenderer"].exists {
                    if entry["continuationItemRenderer"].first("continuationCommand")["token"].nonEmpty == nil {
                        invalidContinuation = true
                    }
                } else if !isNewPlaylistCard(entry) {
                    unknownEntries += 1
                }
            }
        }
        if unknownEntries > 0 { issues.append(.unrecognizedEntries(unknownEntries)) }
        if invalidContinuation { issues.append(.invalidContinuation) }
        return .init(playlists: Pages.dedupe(playlists), continuation: libraryContinuation(root), issues: issues)
    }

    /// The service places navigation on either the card or its title runs. The
    /// latter is the path used by ytmusicapi/parsers/browsing.py parse_playlist.
    /// Restrict the fallback to the title; artist links in the subtitle are not
    /// the identity of the playlist itself.
    private static func libraryItem(_ entry: JSON) -> MusicItem? {
        if let item = Rows.item(entry: entry) { return item }
        let isCard = entry["musicTwoRowItemRenderer"].exists
        let row = isCard ? entry["musicTwoRowItemRenderer"] : entry["musicResponsiveListItemRenderer"]
        guard row.exists, !row["navigationEndpoint"]["browseEndpoint"].exists,
              !row["navigationEndpoint"]["watchEndpoint"].exists else { return nil }
        let titleRuns = isCard ? row["title"].runs : (Rows.columns(row).first?.runs ?? [])
        let linked = titleRuns.filter { $0.link != nil }
        guard let first = linked.first, let id = first.link?.id,
              linked.allSatisfy({ $0.link?.id == id }), var fields = row.raw as? [String: Any] else { return nil }
        fields["navigationEndpoint"] = first["navigationEndpoint"].raw
        return isCard ? Rows.item(twoRow: JSON(fields)) : Rows.item(listRow: JSON(fields))
    }

    private static func isNewPlaylistCard(_ entry: JSON) -> Bool {
        let card = entry["musicTwoRowItemRenderer"]
        guard card.exists else { return false }
        let endpoints = [card["navigationEndpoint"]] + card["title"].runs.map { $0["navigationEndpoint"] }
        guard !endpoints.contains(where: { $0["browseEndpoint"].exists || $0["watchEndpoint"].exists }) else { return false }
        return endpoints.contains { $0["createPlaylistEndpoint"].exists }
    }

    static func librarySongs(_ root: JSON) -> [Song] {
        libraryItems(root).compactMap { if case .song(let song) = $0 { return song }; return nil }
    }

    /// Only the library container's own token: the section list around it can carry one
    /// of its own that leads to other shelves, not more of the library.
    static func libraryContinuation(_ root: JSON) -> String? {
        for scope in libraryContainers(root) {
            if let token = scope["continuations"].objects("nextContinuationData").first?["continuation"].nonEmpty { return token }
            let entries = scope["contents"].array + scope["items"].array + scope["continuationItems"].array
            if let token = entries.lazy.compactMap({
                $0["continuationItemRenderer"].first("continuationCommand")["token"].nonEmpty
            }).first { return token }
        }
        return nil
    }

    // MARK: Writes

    /// The account's playlists in a `playlist/get_add_to_playlist` answer. Watch Later and
    /// Liked Music are left out: neither takes songs added by hand.
    static func addToPlaylistOptions(_ root: JSON) -> [EditablePlaylist] {
        let options = root.objects("playlistAddToOptionRenderer").compactMap { option -> EditablePlaylist? in
            guard option["isDisabled"].bool != true, option["disabled"].bool != true,
                  let id = option["playlistId"].nonEmpty.map({ String($0.trimmingPrefix("VL")) }),
                  id != "WL", id != "LM", let title = option["title"].text.nonEmptyString else { return nil }
            let contains: Bool? = switch option["containsSelectedVideos"].string {
            case "ALL", "SOME": true
            case "NONE": false
            default: nil
            }
            return EditablePlaylist(id: id, title: title, containsSongs: contains)
        }
        return Pages.dedupe(options)
    }

    /// `playlist/create` answers with the new playlist's id.
    static func createdPlaylistId(_ root: JSON) -> String? {
        root["playlistId"].nonEmpty
    }

    /// `browse/edit_playlist` reports success in a top-level status; account writes answer
    /// 200 to requests they did not act on, so the status is what counts.
    static func editSucceeded(_ root: JSON) -> Bool {
        root["status"].string == "STATUS_SUCCEEDED"
    }
}
