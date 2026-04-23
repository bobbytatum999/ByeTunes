import Foundation
import UIKit

extension SongMetadata {
    private struct YouTubeOEmbedResponse: Decodable {
        let title: String
        let author_name: String
        let thumbnail_url: String
    }

    static func enrichWithYouTubeMetadata(_ song: SongMetadata) async -> SongMetadata {
        let query = youtubeSearchQuery(for: song)
        guard !query.isEmpty else { return song }

        do {
            guard let videoID = try await searchYouTubeVideoID(query: query) else {
                Logger.shared.log("[SongMetadata][YouTube] No video results for query: \(query)")
                return song
            }

            guard let oEmbed = try await fetchYouTubeOEmbed(videoID: videoID) else {
                Logger.shared.log("[SongMetadata][YouTube] oEmbed fetch failed for video ID: \(videoID)")
                return song
            }

            var enriched = song
            let cleanedTitle = cleanYouTubeTitle(oEmbed.title)
            let cleanedArtist = cleanYouTubeAuthor(oEmbed.author_name)

            if shouldReplaceTitle(song.title) || !cleanedTitle.isEmpty {
                enriched.title = cleanedTitle.isEmpty ? enriched.title : cleanedTitle
            }

            if shouldReplaceArtist(song.artist) || !cleanedArtist.isEmpty {
                enriched.artist = cleanedArtist.isEmpty ? enriched.artist : cleanedArtist
            }

            if enriched.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || enriched.genre == "Unknown Genre" {
                enriched.genre = "Music"
            }

            if let artworkData = try await fetchYouTubeThumbnailData(urlString: oEmbed.thumbnail_url) {
                enriched.artworkData = artworkData
                if enriched.artworkPreviewData == nil {
                    enriched.artworkPreviewData = createYouTubeArtworkPreviewData(from: artworkData)
                }
            }

            Logger.shared.log("[SongMetadata][YouTube] Enriched metadata for \(song.localURL.lastPathComponent) using video ID: \(videoID)")
            return enriched
        } catch {
            Logger.shared.log("[SongMetadata][YouTube] Metadata fetch failed: \(error.localizedDescription)")
            return song
        }
    }

    private static func youtubeSearchQuery(for song: SongMetadata) -> String {
        let cleanedArtist = sanitizeYouTubeQueryComponent(song.artist)
        let cleanedTitle = sanitizeYouTubeQueryComponent(song.title)

        if !cleanedArtist.isEmpty && !cleanedTitle.isEmpty {
            return "\(cleanedArtist) \(cleanedTitle) song"
        }

        if !cleanedTitle.isEmpty {
            return cleanedTitle
        }

        return sanitizeYouTubeQueryComponent(song.localURL.deletingPathExtension().lastPathComponent)
    }

    private static func sanitizeYouTubeQueryComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        let withoutUUID = trimmed.replacingOccurrences(
            of: #"^[0-9A-Fa-f-]{36}_"#,
            with: "",
            options: .regularExpression
        )

        let withoutNoise = withoutUUID
            .replacingOccurrences(of: #"\bOfficial\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\bVideo\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\bAudio\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\bLyrics\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\([^\)]*official[^\)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\([^\)]*video[^\)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return withoutNoise
    }

    private static func shouldReplaceTitle(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "unknown title"
    }

    private static func shouldReplaceArtist(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "unknown artist"
    }

    private static func searchYouTubeVideoID(query: String) async throws -> String? {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/results?search_query=\(encodedQuery)&sp=EgIQAQ%253D%253D") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        let pattern = #"\"videoId\":\"([A-Za-z0-9_-]{11})\""#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let candidate = nsHTML.substring(with: match.range(at: 1))
            if candidate.count == 11 {
                return candidate
            }
        }

        return nil
    }

    private static func fetchYouTubeOEmbed(videoID: String) async throws -> YouTubeOEmbedResponse? {
        guard let watchURL = "https://www.youtube.com/watch?v=\(videoID)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/oembed?url=\(watchURL)&format=json") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("ByeTunes/2.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }

        return try JSONDecoder().decode(YouTubeOEmbedResponse.self, from: data)
    }

    private static func fetchYouTubeThumbnailData(urlString: String) async throws -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("ByeTunes/2.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            return nil
        }
        return data
    }

    private static func cleanYouTubeTitle(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\([^\)]*official[^\)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\([^\)]*lyrics?[^\)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\([^\)]*audio[^\)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\([^\)]*video[^\)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?i)\bofficial music video\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bofficial video\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bofficial audio\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\blyric video\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\blyrics\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_[]()"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? title : cleaned
    }

    private static func cleanYouTubeAuthor(_ author: String) -> String {
        let cleaned = author
            .replacingOccurrences(of: " - Topic", with: "")
            .replacingOccurrences(of: "VEVO", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? author : cleaned
    }

    private static func createYouTubeArtworkPreviewData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let targetSize = CGSize(width: 120, height: 120)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: 0.72)
    }
}
