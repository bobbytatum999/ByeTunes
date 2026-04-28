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
    // Updated Invidious instances: official public list as of April 2026
    private static let invidiousInstances = [
        "https://inv.nadeko.net",
        "https://invidious.nerdvpn.de",
        "https://inv.thepixora.com",
        "https://yt.chocolatemoo53.com",
        "https://yewtu.be"
    ]

    // Piped API instances for fallback (audio streams + metadata)
    private static let pipedInstances = [
        "https://pipedapi.kavin.rocks",
        "https://pipedapi.leptons.xyz",
        "https://piped-api.lunar.icu",
        "https://pipedapi.r4fo.com",
        "https://pipedapi.ngn.tf"
    ]

    static func normalizeYouTubeTitle(_ rawTitle: String, channel: String) -> PartialSongMetadata {
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

    static func extractYouTubeVideoID(from urlString: String) -> String? {
        let patterns = [
            #"(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/|music\.youtube\.com/watch\?v=)([a-zA-Z0-9_-]{11})"#,
            #"^([a-zA-Z0-9_-]{11})$"#
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

    static func fetchYouTubeMetadata(videoID: String, apiKey: String? = nil) async -> YouTubeMetadataCandidate? {
        if let key = apiKey, !key.isEmpty {
            return await fetchYouTubeMetadataWithAPIKey(videoID: videoID, apiKey: key)
        }
        return await fetchYouTubeMetadataFree(videoID: videoID)
    }

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

    static func fetchYouTubeMetadataFree(videoID: String) async -> YouTubeMetadataCandidate? {
        // 1) Try Invidious instances first
        for instance in invidiousInstances {
            let urlString = "\(instance)/api/v1/videos/\(videoID)"
            guard let url = URL(string: urlString) else { continue }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }

                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let title = json?["title"] as? String ?? ""
                let author = json?["author"] as? String ?? ""
                let lengthSeconds = json?["lengthSeconds"] as? Int
                let videoThumbnails = json?["videoThumbnails"] as? [[String: Any]]
                let bestThumbnail = videoThumbnails?.first { ($0["quality"] as? String) == "maxresdefault" }
                    ?? videoThumbnails?.first { ($0["quality"] as? String) == "high" }
                    ?? videoThumbnails?.first { ($0["quality"] as? String) == "medium" }
                    ?? videoThumbnails?.first
                let thumbnailURL = bestThumbnail?["url"] as? String

                if !title.isEmpty || !author.isEmpty {
                    return YouTubeMetadataCandidate(
                        videoID: videoID,
                        title: title,
                        channelTitle: author,
                        description: json?["description"] as? String,
                        tags: json?["keywords"] as? [String] ?? [],
                        thumbnailURL: thumbnailURL.flatMap { URL(string: $0) },
                        durationMs: lengthSeconds.map { $0 * 1000 }
                    )
                }
            } catch {
                Logger.shared.log("[YouTubeProvider] Invidious instance \(instance) failed: \(error)")
                continue
            }
        }

        // 2) Fallback to Piped instances
        if let piped = await fetchPipedMetadata(videoID: videoID) {
            return piped
        }

        // 3) Fallback to official YouTube oEmbed
        let oembedURLString = "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=\(videoID)&format=json"
        guard let oembedURL = URL(string: oembedURLString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: oembedURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let title = json?["title"] as? String ?? ""
            let authorName = json?["author_name"] as? String ?? ""
            let thumbnailURL = json?["thumbnail_url"] as? String

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
        } catch {
            Logger.shared.log("[YouTubeProvider] YouTube oEmbed fallback failed: \(error)")
        }

        // 4) Last resort: noembed.com mirror
        let noembedURLString = "https://noembed.com/embed?url=https://www.youtube.com/watch?v=\(videoID)"
        guard let noembedURL = URL(string: noembedURLString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: noembedURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let title = json?["title"] as? String ?? ""
            let authorName = json?["author_name"] as? String ?? ""
            let thumbnailURL = json?["thumbnail_url"] as? String

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
        } catch {
            Logger.shared.log("[YouTubeProvider] noembed fallback failed: \(error)")
        }

        return nil
    }

    // MARK: - Piped helpers

    private static func fetchPipedMetadata(videoID: String) async -> YouTubeMetadataCandidate? {
        for instance in pipedInstances {
            let urlString = "\(instance)/streams/\(videoID)"
            guard let url = URL(string: urlString) else { continue }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                let title = json["title"] as? String ?? ""
                let uploader = json["uploader"] as? String ?? ""
                let duration = json["duration"] as? Int
                let thumbnailURL = json["thumbnailUrl"] as? String

                if !title.isEmpty || !uploader.isEmpty {
                    return YouTubeMetadataCandidate(
                        videoID: videoID,
                        title: title,
                        channelTitle: uploader,
                        description: json["description"] as? String,
                        tags: [],
                        thumbnailURL: thumbnailURL.flatMap { URL(string: $0) },
                        durationMs: duration.map { $0 * 1000 }
                    )
                }
            } catch {
                Logger.shared.log("[YouTubeProvider] Piped metadata \(instance) failed: \(error)")
                continue
            }
        }
        return nil
    }

    static func searchYouTubeForMetadata(query: String, limit: Int = 5) async -> [YouTubeMetadataCandidate] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        // 1) Try Invidious search API
        for instance in invidiousInstances {
            let searchURLString = "\(instance)/api/v1/search?q=\(encodedQuery)&type=video"
            guard let searchURL = URL(string: searchURLString) else { continue }

            do {
                var request = URLRequest(url: searchURL)
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }

                guard let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }

                var candidates: [YouTubeMetadataCandidate] = []
                for item in results.prefix(limit) {
                    guard let videoID = item["videoId"] as? String else { continue }
                    let title = item["title"] as? String ?? ""
                    let author = item["author"] as? String ?? ""
                    let lengthSeconds = item["lengthSeconds"] as? Int
                    let videoThumbnails = item["videoThumbnails"] as? [[String: Any]]
                    let bestThumbnail = videoThumbnails?.first { ($0["quality"] as? String) == "maxresdefault" }
                        ?? videoThumbnails?.first { ($0["quality"] as? String) == "high" }
                        ?? videoThumbnails?.first { ($0["quality"] as? String) == "medium" }
                        ?? videoThumbnails?.first
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
            } catch {
                Logger.shared.log("[YouTubeProvider] Invidious search \(instance) failed: \(error)")
                continue
            }
        }

        // 2) Fallback to Piped search
        for instance in pipedInstances {
            let searchURLString = "\(instance)/search?q=\(encodedQuery)&filter=videos"
            guard let searchURL = URL(string: searchURLString) else { continue }

            do {
                let (data, response) = try await URLSession.shared.data(from: searchURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = json["items"] as? [[String: Any]] else { continue }

                var candidates: [YouTubeMetadataCandidate] = []
                for item in items.prefix(limit) {
                    guard let urlPath = item["url"] as? String,
                          let videoID = extractYouTubeVideoID(from: urlPath) else { continue }
                    let title = item["title"] as? String ?? ""
                    let author = item["uploaderName"] as? String ?? ""
                    let duration = item["duration"] as? Int
                    let thumbnailURL = item["thumbnail"] as? String

                    if !title.isEmpty || !author.isEmpty {
                        candidates.append(YouTubeMetadataCandidate(
                            videoID: videoID,
                            title: title,
                            channelTitle: author,
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
            } catch {
                Logger.shared.log("[YouTubeProvider] Piped search \(instance) failed: \(error)")
                continue
            }
        }

        // 3) Fallback to YouTube HTML scraping
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
            return []
        }
    }

    static func resolveYouTubeAudioStreamURL(videoID: String) async -> URL? {
        // 1) Try Invidious adaptive audio streams
        for instance in invidiousInstances {
            let urlString = "\(instance)/api/v1/videos/\(videoID)"
            guard let url = URL(string: urlString) else { continue }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                if let adaptiveFormats = json["adaptiveFormats"] as? [[String: Any]] {
                    let audioFormats = adaptiveFormats.filter {
                        let type = $0["type"] as? String ?? ""
                        return type.hasPrefix("audio/")
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

                if let formatStreams = json["formatStreams"] as? [[String: Any]] {
                    if let firstStream = formatStreams.first,
                       let streamURL = firstStream["url"] as? String,
                       let resolved = URL(string: streamURL) {
                        return resolved
                    }
                }
            } catch {
                Logger.shared.log("[YouTubeProvider] Invidious stream resolve \(instance) failed: \(error)")
                continue
            }
        }

        // 2) Fallback to Piped audio streams
        for instance in pipedInstances {
            let urlString = "\(instance)/streams/\(videoID)"
            guard let url = URL(string: urlString) else { continue }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

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

                // Piped also exposes combined video+audio streams if audio-only isn't present
                if let videoStreams = json["videoStreams"] as? [[String: Any]] {
                    let sortedVideo = videoStreams.sorted {
                        let bit0 = $0["bitrate"] as? Int ?? 0
                        let bit1 = $1["bitrate"] as? Int ?? 0
                        return bit0 > bit1
                    }
                    if let bestStream = sortedVideo.first,
                       let streamURL = bestStream["url"] as? String,
                       let resolved = URL(string: streamURL) {
                        return resolved
                    }
                }
            } catch {
                Logger.shared.log("[YouTubeProvider] Piped stream resolve \(instance) failed: \(error)")
                continue
            }
        }

        return nil
    }

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
