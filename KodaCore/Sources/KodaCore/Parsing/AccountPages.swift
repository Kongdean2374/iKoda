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
            if let item = Rows.item(entry: entry) {
                items.append(item)
            } else if entry["continuationItemRenderer"].exists {
                // Pagination controls are not playlists, but a missing token cannot
                // be mistaken for the end of an otherwise complete directory.
                guard entry["continuationItemRenderer"].first("continuationCommand")["token"].nonEmpty != nil else {
                    throw CloudPlaylistError.incompleteResponse
                }
            } else if entry["musicTwoRowItemRenderer"]["navigationEndpoint"]["createPlaylistEndpoint"].exists {
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
        return Pages.dedupe(entries.compactMap(Rows.item(entry:)))
    }

    static func librarySongs(_ root: JSON) -> [Song] {
        libraryItems(root).compactMap { if case .song(let song) = $0 { return song }; return nil }
    }

    /// Only the library container's own token: the section list around it can carry one
    /// of its own that leads to other shelves, not more of the library.
    static func libraryContinuation(_ root: JSON) -> String? {
        for scope in libraryContainers(root) {
            if let token = scope["continuations"].objects("nextContinuationData").first?["continuation"].nonEmpty { return token }
            if let token = scope.objects("continuationItemRenderer").lazy
                .compactMap({ $0["continuationEndpoint"]["continuationCommand"]["token"].nonEmpty }).first { return token }
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
