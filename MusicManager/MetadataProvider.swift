import Foundation

enum MetadataProviderID: String, CaseIterable, Identifiable, Codable {
    case local
    case youtube
    case itunes
    case deezer
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "Local Files"
        case .youtube: return "YouTube"
        case .itunes: return "iTunes API"
        case .deezer: return "Deezer API"
        case .apple: return "Apple Music"
        }
    }

    var isRemote: Bool {
        self != .local
    }
}

struct MetadataProviderSettings {
    static let sourcesKey = "metadataSourcesJSON"
    static let legacySourceKey = "metadataSource"

    static var defaultSources: [MetadataProviderID] {
        [.local, .youtube, .itunes, .deezer, .apple]
    }

    static var safeSources: [MetadataProviderID] {
        [.local, .youtube, .itunes, .deezer]
    }

    static func selectedSources() -> [MetadataProviderID] {
        migrateIfNeeded()
        if let legacy = UserDefaults.standard.string(forKey: legacySourceKey), legacy == "all" {
            return defaultSources
        }
        guard let json = UserDefaults.standard.string(forKey: sourcesKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([MetadataProviderID].self, from: data) else {
            return [.local]
        }
        return decoded.isEmpty ? [.local] : decoded
    }

    static func saveSources(_ sources: [MetadataProviderID]) {
        let valid = sources.isEmpty ? [MetadataProviderID.local] : sources
        if let data = try? JSONEncoder().encode(valid),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: sourcesKey)
        }
    }

    static func migrateIfNeeded() {
        guard UserDefaults.standard.string(forKey: sourcesKey) == nil else { return }
        let old = UserDefaults.standard.string(forKey: legacySourceKey) ?? "local"
        let migrated: [MetadataProviderID]
        switch old {
        case "youtube": migrated = [.local, .youtube]
        case "itunes": migrated = [.local, .itunes]
        case "deezer": migrated = [.local, .deezer]
        case "apple": migrated = [.local, .apple]
        case "all": migrated = defaultSources
        default: migrated = [.local]
        }
        saveSources(migrated)
    }

    static func addSource(_ source: MetadataProviderID) {
        var current = selectedSources()
        if !current.contains(source) {
            current.append(source)
            saveSources(current)
        }
    }

    static func removeSource(_ source: MetadataProviderID) {
        var current = selectedSources()
        current.removeAll { $0 == source }
        if current.isEmpty { current = [.local] }
        saveSources(current)
    }

    static func toggleSource(_ source: MetadataProviderID) {
        let current = selectedSources()
        if current.contains(source) {
            removeSource(source)
        } else {
            addSource(source)
        }
    }

    static func hasRemoteSource() -> Bool {
        selectedSources().contains(where: { $0.isRemote })
    }
}

struct YouTubeMetadataCandidate {
    let videoID: String
    let title: String
    let channelTitle: String
    let description: String?
    let tags: [String]
    let thumbnailURL: URL?
    let durationMs: Int?
}

struct PartialSongMetadata {
    let title: String
    let artist: String
    let album: String
    let source: MetadataProviderID
}

enum MetadataProvider {
    // MARK: - Instance Lists (shuffled per-request to distribute load)
    private static let invidiousInstances = [
        "https://invidious.darkness.services",
        "https://invidious.fdn.fr",
        "https://invidious.flokinet.to",
        "https://inv.thepixora.com",
        "https://inv.nadeko.net",
        "https://invidious.jing.rocks",
        "https://invidious.nerdvpn.de",
        "https://invidious.perennialte.ch",
        "https://invidious.drgns.space",
        "https://invidious.protokolla.fi",
        "https://invidious.privacydev.net",
        "https://invidious.private.coffee",
        "https://yt.drgnz.club",
        "https://inv.in.projectsegfau.lt",
        "https://invidious.reallyaweso.me",
        "https://invidious.materialio.us",
        "https://invidious.incogniweb.net",
        "https://invidious.privacyredirect.com",
        "https://inv.tux.pizza",
        "https://iv.nboeck.de",
        "https://iv.melmac.space",
        "https://iv.datura.network",
        "https://y.com.sb",
        "https://inv.riverside.rocks"
    ]

    private static let pipedInstances = [
        "https://api.piped.projectsegfault.com",
        "https://pipedapi.moomoo.me",
        "https://pipedapi.adminforge.de",
        "https://pipedapi.mint.lgbt",
        "https://pipedapi.frontendfriendly.xyz",
        "https://pipedapi.moomoo.me",
        "https://api.piped.privacydev.net"
    ]

    private static func shuffledInstances(_ instances: [String]) -> [String] {
        var copy = instances
        copy.shuffle()
        return copy
    }

    // MARK: - Shared HTTP/JSON Helper

    /// Fetches JSON from a URL and returns it as `[String: Any]`.
    /// - Returns: The parsed dictionary, or `nil` if the request fails or returns non-JSON.
    private static func fetchJSONDictionary(from url: URL) async -> [String: Any]? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            Logger.shared.log("[MetadataProvider] fetchJSONDictionary failed for \(url): \(error)")
            return nil
        }
    }

    /// Fetches JSON from a URL and returns it as `[[String: Any]]`.
    /// - Returns: The parsed array, or `nil` if the request fails or returns non-JSON.
    private static func fetchJSONArray(from url: URL) async -> [[String: Any]]? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch {
            Logger.shared.log("[MetadataProvider] fetchJSONArray failed for \(url): \(error)")
            return nil
        }
    }

    /// Fetches JSON from a URLRequest and returns it as `[[String: Any]]`.
    private static func fetchJSONArray(for request: URLRequest) async -> [[String: Any]]? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch {
            Logger.shared.log("[MetadataProvider] fetchJSONArray failed for \(request.url?.absoluteString ?? "nil"): \(error)")
            return nil
        }
    }

    /// Fetches JSON from a URLRequest and returns it as `[String: Any]`.
    private static func fetchJSONDictionary(for request: URLRequest) async -> [String: Any]? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            Logger.shared.log("[MetadataProvider] fetchJSONDictionary failed for \(request.url?.absoluteString ?? "nil"): \(error)")
            return nil
        }
    }

    // MARK: - Title Normalization

    nonisolated static func normalizeYouTubeTitle(_ rawTitle: String, channel: String) -> PartialSongMetadata {
        let cleaned = rawTitle
            .replacingOccurrences(of: "(Official Video)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Official Audio)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "[Lyrics]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Lyrics)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Visualizer)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(AMV)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Remix)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Unreleased)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Leak)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "prod.", with: "prod.", options: .caseInsensitive)
            .replacingOccurrences(of: "ft.", with: "feat.", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.contains(" - ") {
            let parts = cleaned.split(separator: "-", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return PartialSongMetadata(
                title: parts.count > 1 ? parts[1] : cleaned,
                artist: parts.first ?? channel,
                album: "YouTube",
                source: .youtube
            )
        }
        return PartialSongMetadata(
            title: cleaned,
            artist: channel,
            album: "YouTube",
            source: .youtube
        )
    }

    // MARK: - Video ID Extraction

    nonisolated static func extractYouTubeVideoID(from urlString: String) -> String? {
        let patterns = [
            #"(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/|music\.youtube\.com/watch\?v=)([a-zA-Z0-9_-]{11})"#,
            #"^/?watch\?v=([a-zA-Z0-9_-]{11})"#,          // Relative /watch?v=... (Piped, etc.)
            #"^/?shorts/([a-zA-Z0-9_-]{11})"#,            // Relative /shorts/...
            #"^/?live/([a-zA-Z0-9_-]{11})"#,              // Relative /live/...
            #"^([a-zA-Z0-9_-]{11})$"#                     // Bare ID
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range(at: 1), in: urlString) {
                return String(urlString[range])
            }
        }
        return nil
    }

    // MARK: - Public Metadata Entry Point

    static func fetchYouTubeMetadata(videoID: String, apiKey: String? = nil) async -> YouTubeMetadataCandidate? {
        if let key = apiKey, !key.isEmpty {
            return await fetchYouTubeMetadataWithAPIKey(videoID: videoID, apiKey: key)
        }
        return await fetchYouTubeMetadataFree(videoID: videoID)
    }

    // MARK: - API Key Path

    private static func fetchYouTubeMetadataWithAPIKey(videoID: String, apiKey: String) async -> YouTubeMetadataCandidate? {
        let urlString = "https://www.googleapis.com/youtube/v3/videos?part=snippet,contentDetails&id=\(videoID)&key=\(apiKey)"
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let items = json?["items"] as? [[String: Any]], let first = items.first else { return nil }

            let snippet = first["snippet"] as? [String: Any] ?? [:]
            let contentDetails = first["contentDetails"] as? [String: Any] ?? [:]

            let title = snippet["title"] as? String ?? ""
            let channelTitle = snippet["channelTitle"] as? String ?? ""
            let description = snippet["description"] as? String
            let tags = snippet["tags"] as? [String] ?? []
            let thumbnailURL = (snippet["thumbnails"] as? [String: Any])?["high"] as? [String: Any]? ?? (snippet["thumbnails"] as? [String: Any])?["default"] as? [String: Any]
            let thumbURL = thumbnailURL?["url"] as? String

            var durationMs: Int?
            if let isoDuration = contentDetails["duration"] as? String {
                durationMs = parseISO8601Duration(isoDuration)
            }

            return YouTubeMetadataCandidate(
                videoID: videoID,
                title: title,
                channelTitle: channelTitle,
                description: description,
                tags: tags,
                thumbnailURL: thumbURL.flatMap { URL(string: $0) },
                durationMs: durationMs
            )
        } catch {
            Logger.shared.log("[YouTubeProvider] API Key fetch failed: \(error)")
            return nil
        }
    }

    // MARK: - Free Metadata Path

    static func fetchYouTubeMetadataFree(videoID: String) async -> YouTubeMetadataCandidate? {
        // Try Invidious instances first (metadata + duration + thumbnails)
        for instance in shuffledInstances(invidiousInstances) {
            let urlString = "\(instance)/api/v1/videos/\(videoID)"
            guard let url = URL(string: urlString) else { continue }

            if let json = await fetchJSONDictionary(from: url) {
                let title = json["title"] as? String ?? ""
                let author = json["author"] as? String ?? ""
                let lengthSeconds = json["lengthSeconds"] as? Int
                let videoThumbnails = json["videoThumbnails"] as? [[String: Any]]
                var bestThumbnail: [String: Any]? = nil
                if let thumbs = videoThumbnails {
                    bestThumbnail = thumbs.first { ($0["quality"] as? String) == "maxresdefault" }
                    if bestThumbnail == nil {
                        bestThumbnail = thumbs.first { ($0["quality"] as? String) == "high" }
                    }
                    if bestThumbnail == nil {
                        bestThumbnail = thumbs.first { ($0["quality"] as? String) == "medium" }
                    }
                    if bestThumbnail == nil {
                        bestThumbnail = thumbs.first
                    }
                }
                let thumbnailURL = bestThumbnail?["url"] as? String

                if !title.isEmpty || !author.isEmpty {
                    return YouTubeMetadataCandidate(
                        videoID: videoID,
                        title: title,
                        channelTitle: author,
                        description: json["description"] as? String,
                        tags: json["keywords"] as? [String] ?? [],
                        thumbnailURL: thumbnailURL.flatMap { URL(string: $0) },
                        durationMs: lengthSeconds.map { $0 * 1000 }
                    )
                }
            }
        }

        // Fallback 1: Piped instances (metadata + duration + thumbnails)
        for instance in shuffledInstances(pipedInstances) {
            let urlString = "\(instance)/streams/\(videoID)"
            guard let url = URL(string: urlString) else { continue }

            if let json = await fetchJSONDictionary(from: url) {
                let title = json["title"] as? String ?? ""
                let uploader = json["uploader"] as? String ?? ""
                let thumbnailURL = json["thumbnailUrl"] as? String
                let duration = json["duration"] as? Int
                let description = json["description"] as? String

                if !title.isEmpty || !uploader.isEmpty {
                    return YouTubeMetadataCandidate(
                        videoID: videoID,
                        title: title,
                        channelTitle: uploader,
                        description: description,
                        tags: [],
                        thumbnailURL: thumbnailURL.flatMap { URL(string: $0) },
                        durationMs: duration.map { $0 * 1000 }
                    )
                }
            }
        }

        // Fallback 2: noembed.com (oEmbed mirror — very reliable for basic metadata)
        let noembedURLString = "https://noembed.com/embed?url=https://www.youtube.com/watch?v=\(videoID)"
        guard let noembedURL = URL(string: noembedURLString) else { return nil }

        if let json = await fetchJSONDictionary(from: noembedURL) {
            let title = json["title"] as? String ?? ""
            let authorName = json["author_name"] as? String ?? ""
            let thumbnailURL = json["thumbnail_url"] as? String

            if !title.isEmpty || !authorName.isEmpty {
                return YouTubeMetadataCandidate(
                    videoID: videoID,
                    title: title,
                    channelTitle: authorName,
                    description: nil,
                    tags: [],
                    thumbnailURL: thumbnailURL.flatMap { URL(string: $0) },
                    durationMs: nil
                )
            }
        }

        // Fallback 3: YouTube Innertube (ANDROID client) — most reliable when frontends are blocked
        if let candidate = await fetchYouTubeMetadataInnertube(videoID: videoID) {
            return candidate
        }

        return nil
    }

    // MARK: - Innertube Metadata Fallback

    private static func fetchYouTubeMetadataInnertube(videoID: String) async -> YouTubeMetadataCandidate? {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8")!
        let payload: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "17.10.35",
                    "androidSdkVersion": 30,
                    "hl": "en",
                    "gl": "US"
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.youtube/17.10.35 (Linux; U; Android 11) gzip", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let json = await fetchJSONDictionary(for: request),
              let videoDetails = json["videoDetails"] as? [String: Any] else { return nil }

        let title = videoDetails["title"] as? String ?? ""
        let author = videoDetails["author"] as? String ?? ""
        let lengthSecondsStr = videoDetails["lengthSeconds"] as? String
        let lengthSeconds = lengthSecondsStr.flatMap(Int.init)

        // Thumbnails from videoDetails.thumbnail.thumbnails (last is usually highest res)
        let thumbnailArray = (videoDetails["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let bestThumb = thumbnailArray?.last
        let thumbnailURL = bestThumb?["url"] as? String

        return YouTubeMetadataCandidate(
            videoID: videoID,
            title: title,
            channelTitle: author,
            description: nil,
            tags: [],
            thumbnailURL: thumbnailURL.flatMap { URL(string: $0) } ?? URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"),
            durationMs: lengthSeconds.map { $0 * 1000 }
        )
    }

    // MARK: - Innertube Search Fallback (free Swift-native alternative to Invidious/Piped search)

    private static func searchYouTubeInnertube(query: String, limit: Int) async -> [YouTubeMetadataCandidate] {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/search?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8")!
        let payload: [String: Any] = [
            "query": query,
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "17.10.35",
                    "androidSdkVersion": 30,
                    "hl": "en",
                    "gl": "US"
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.youtube/17.10.35 (Linux; U; Android 11) gzip", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let json = await fetchJSONDictionary(for: request) else { return [] }
        guard
            let contents = json["contents"] as? [String: Any],
            let twoColumn = contents["twoColumnSearchResultsRenderer"] as? [String: Any],
            let primary = twoColumn["primaryContents"] as? [String: Any],
            let sectionList = primary["sectionListRenderer"] as? [String: Any],
            let sections = sectionList["contents"] as? [[String: Any]]
        else {
            return []
        }

        var parsed: [YouTubeMetadataCandidate] = []
        for section in sections {
            guard let itemSection = section["itemSectionRenderer"] as? [String: Any],
                  let items = itemSection["contents"] as? [[String: Any]] else { continue }

            for item in items {
                guard let videoRenderer = item["videoRenderer"] as? [String: Any],
                      let videoID = videoRenderer["videoId"] as? String else { continue }

                let titleRuns = ((videoRenderer["title"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
                let ownerRuns = (((videoRenderer["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? [])
                let title = titleRuns.compactMap { $0["text"] as? String }.joined()
                let owner = ownerRuns.compactMap { $0["text"] as? String }.joined()

                if title.isEmpty && owner.isEmpty { continue }
                parsed.append(YouTubeMetadataCandidate(
                    videoID: videoID,
                    title: title,
                    channelTitle: owner,
                    description: nil,
                    tags: [],
                    thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"),
                    durationMs: nil
                ))
                if parsed.count >= limit { return parsed }
            }
        }
        return parsed
    }

    // MARK: - Search

    static func searchYouTubeForMetadata(query: String, limit: Int = 5) async -> [YouTubeMetadataCandidate] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        // Try Invidious search API first
        for instance in shuffledInstances(invidiousInstances) {
            let searchURLString = "\(instance)/api/v1/search?q=\(encodedQuery)&type=video"
            guard let searchURL = URL(string: searchURLString) else { continue }

            do {
                var request = URLRequest(url: searchURL)
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

                guard let results = await fetchJSONArray(for: request) else { continue }

                var candidates: [YouTubeMetadataCandidate] = []
                for item in results.prefix(limit) {
                    guard let videoID = item["videoId"] as? String else { continue }
                    let title = item["title"] as? String ?? ""
                    let author = item["author"] as? String ?? ""
                    let lengthSeconds = item["lengthSeconds"] as? Int
                    let videoThumbnails = item["videoThumbnails"] as? [[String: Any]]
                    var bestThumbnail: [String: Any]? = nil
                    if let thumbs = videoThumbnails {
                        bestThumbnail = thumbs.first { ($0["quality"] as? String) == "maxresdefault" }
                        if bestThumbnail == nil {
                            bestThumbnail = thumbs.first { ($0["quality"] as? String) == "high" }
                        }
                        if bestThumbnail == nil {
                            bestThumbnail = thumbs.first { ($0["quality"] as? String) == "medium" }
                        }
                        if bestThumbnail == nil {
                            bestThumbnail = thumbs.first
                        }
                    }
                    let thumbnailURL = bestThumbnail?["url"] as? String

                    if !title.isEmpty || !author.isEmpty {
                        candidates.append(YouTubeMetadataCandidate(
                            videoID: videoID,
                            title: title,
                            channelTitle: author,
                            description: item["description"] as? String,
                            tags: item["keywords"] as? [String] ?? [],
                            thumbnailURL: thumbnailURL.flatMap { URL(string: $0) },
                            durationMs: lengthSeconds.map { $0 * 1000 }
                        ))
                    }
                }

                if !candidates.isEmpty {
                    return candidates
                }
            }
        }

        // Fallback: Piped search API — returns top-level [[String: Any]] array
        for instance in shuffledInstances(pipedInstances) {
            let searchURLString = "\(instance)/search?q=\(encodedQuery)&filter=videos"
            guard let searchURL = URL(string: searchURLString) else { continue }

            if let results = await fetchJSONArray(from: searchURL) {
                var candidates: [YouTubeMetadataCandidate] = []
                for item in results.prefix(limit) {
                    // Piped search items use "url" with relative paths like "/watch?v=..."
                    let urlField = item["url"] as? String ?? ""
                    guard let videoID = extractYouTubeVideoID(from: urlField) else { continue }
                    let title = item["title"] as? String ?? item["name"] as? String ?? ""
                    let uploader = item["uploaderName"] as? String ?? item["uploader"] as? String ?? ""
                    let thumbnailURL = item["thumbnail"] as? String
                    let duration = item["duration"] as? Int

                    if !title.isEmpty || !uploader.isEmpty {
                        candidates.append(YouTubeMetadataCandidate(
                            videoID: videoID,
                            title: title,
                            channelTitle: uploader,
                            description: nil,
                            tags: [],
                            thumbnailURL: thumbnailURL.flatMap { URL(string: $0) },
                            durationMs: duration.map { $0 * 1000 }
                        ))
                    }
                }

                if !candidates.isEmpty {
                    return candidates
                }
            }
        }

        // Fallback: YouTube HTML scraping
        let searchURLString = "https://www.youtube.com/results?search_query=\(encodedQuery)"
        guard let searchURL = URL(string: searchURLString) else { return [] }

        do {
            var request = URLRequest(url: searchURL)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }

            guard let html = String(data: data, encoding: .utf8) else { return [] }

            var videoIDs: [String] = []
            let patterns = [
                #""videoId":"([a-zA-Z0-9_-]{11})""#,
                #"watch\?v=([a-zA-Z0-9_-]{11})"#,
                #"/watch\?v=([a-zA-Z0-9_-]{11})"#,
                #""videoIds":"([a-zA-Z0-9_-]{11})""#,
                #"%22videoId%22%3A%22([a-zA-Z0-9_-]{11})%22"#,
                #"\"videoId\":\"([a-zA-Z0-9_-]{11})\""#,
                #"videoId%22%3A%22([a-zA-Z0-9_-]{11})"#
            ]

            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                for match in matches {
                    if let range = Range(match.range(at: 1), in: html) {
                        let videoID = String(html[range])
                        if !videoIDs.contains(videoID) {
                            videoIDs.append(videoID)
                        }
                    }
                }
            }

            let limitedIDs = Array(videoIDs.prefix(limit))
            var results: [YouTubeMetadataCandidate] = []

            for videoID in limitedIDs {
                if let candidate = await fetchYouTubeMetadataFree(videoID: videoID) {
                    results.append(candidate)
                }
            }

            return results
        } catch {
            Logger.shared.log("[YouTubeProvider] YouTube HTML search failed: \(error)")
        }

        // Fallback: Innertube search (Swift-native, no third-party host dependency)
        return await searchYouTubeInnertube(query: query, limit: limit)
    }

    // MARK: - Audio Stream Resolution

    static func resolveYouTubeAudioStreamURL(videoID: String) async -> URL? {
        // Try Invidious instances for adaptive audio streams
        for instance in shuffledInstances(invidiousInstances) {
            let urlString = "\(instance)/api/v1/videos/\(videoID)"
            guard let url = URL(string: urlString) else { continue }

            if let json = await fetchJSONDictionary(from: url) {
                // Prefer adaptiveFormats audio-only streams
                if let adaptiveFormats = json["adaptiveFormats"] as? [[String: Any]] {
                    let audioFormats = adaptiveFormats.filter {
                        let type = $0["type"] as? String ?? ""
                        return type.hasPrefix("audio/")
                    }

                    // Sort by bitrate descending to get best quality
                    let sortedAudio = audioFormats.sorted {
                        let bit0 = $0["bitrate"] as? Int ?? 0
                        let bit1 = $1["bitrate"] as? Int ?? 0
                        return bit0 > bit1
                    }

                    if let bestAudio = sortedAudio.first,
                       let streamURL = bestAudio["url"] as? String,
                       let resolved = URL(string: streamURL) {
                        return resolved
                    }
                }

                // Fallback to formatStreams if no adaptive audio found
                if let formatStreams = json["formatStreams"] as? [[String: Any]] {
                    if let firstStream = formatStreams.first,
                       let streamURL = firstStream["url"] as? String,
                       let resolved = URL(string: streamURL) {
                        return resolved
                    }
                }
            }
        }

        // Fallback: Piped streams endpoint
        for instance in shuffledInstances(pipedInstances) {
            let urlString = "\(instance)/streams/\(videoID)"
            guard let url = URL(string: urlString) else { continue }

            if let json = await fetchJSONDictionary(from: url) {
                // Piped returns audioStreams array with quality/bitrate info
                if let audioStreams = json["audioStreams"] as? [[String: Any]] {
                    let sortedAudio = audioStreams.sorted {
                        let bit0 = $0["bitrate"] as? Int ?? 0
                        let bit1 = $1["bitrate"] as? Int ?? 0
                        return bit0 > bit1
                    }
                    if let bestAudio = sortedAudio.first,
                       let streamURL = bestAudio["url"] as? String,
                       let resolved = URL(string: streamURL) {
                        return resolved
                    }
                }

                // Fallback to stream / hls if available
                if let hlsURL = json["hls"] as? String, let resolved = URL(string: hlsURL) {
                    return resolved
                }
            }
        }

        // Fallback: Innertube direct stream extraction
        if let streamURL = await resolveYouTubeAudioStreamInnertube(videoID: videoID) {
            return streamURL
        }

        return nil
    }

    // MARK: - Innertube Stream Resolution

    private static func resolveYouTubeAudioStreamInnertube(videoID: String) async -> URL? {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8")!
        let payload: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "17.10.35",
                    "androidSdkVersion": 30,
                    "hl": "en",
                    "gl": "US"
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.youtube/17.10.35 (Linux; U; Android 11) gzip", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let json = await fetchJSONDictionary(for: request),
              let streamingData = json["streamingData"] as? [String: Any] else { return nil }

        // Check adaptiveFormats for audio-only streams
        if let adaptiveFormats = streamingData["adaptiveFormats"] as? [[String: Any]] {
            let audioFormats = adaptiveFormats.filter {
                let mimeType = $0["mimeType"] as? String ?? ""
                return mimeType.hasPrefix("audio/")
            }
            let sortedAudio = audioFormats.sorted {
                let bit0 = $0["bitrate"] as? Int ?? 0
                let bit1 = $1["bitrate"] as? Int ?? 0
                return bit0 > bit1
            }
            if let bestAudio = sortedAudio.first,
               let streamURL = bestAudio["url"] as? String,
               let resolved = URL(string: streamURL) {
                return resolved
            }
        }

        // Fallback to regular formats
        if let formats = streamingData["formats"] as? [[String: Any]] {
            if let first = formats.first,
               let streamURL = first["url"] as? String,
               let resolved = URL(string: streamURL) {
                return resolved
            }
        }

        return nil
    }

    // MARK: - Duration Parsing

    private static func parseISO8601Duration(_ duration: String) -> Int? {
        let pattern = #"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = duration as NSString
        let results = regex.matches(in: duration, range: NSRange(location: 0, length: nsString.length))
        guard let match = results.first else { return nil }

        var totalMs = 0
        if let hoursRange = Range(match.range(at: 1), in: duration), let hours = Int(duration[hoursRange]) {
            totalMs += hours * 3600000
        }
        if let minutesRange = Range(match.range(at: 2), in: duration), let minutes = Int(duration[minutesRange]) {
            totalMs += minutes * 60000
        }
        if let secondsRange = Range(match.range(at: 3), in: duration), let seconds = Int(duration[secondsRange]) {
            totalMs += seconds * 1000
        }
        return totalMs > 0 ? totalMs : nil
    }
}
