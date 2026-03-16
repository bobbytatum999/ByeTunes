import SwiftUI

struct LyricsSearchSheet: View {
    @Binding var lyrics: String
    @Binding var isPresented: Bool
    let songTitle: String
    let songArtist: String
    
    @State private var searchQuery: String = ""
    @State private var results: [LRCLIBResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack(alignment: .lastTextBaseline) {
                    Text("Select Lyrics")
                        .font(.system(size: 24, weight: .bold))
                    
                    Text("LRCLIB")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                        )
                        .offset(y: -2)
                    
                    Spacer()
                    
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .padding([.top, .horizontal], 20)
                .padding(.bottom, 10)
                
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search lyrics...", text: $searchQuery)
                        .submitLabel(.search)
                        .onSubmit {
                            performSearch()
                        }
                    
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                
                if isLoading {
                    Spacer()
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Searching LRCLIB...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else if let error = errorMessage {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text(error)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 50))
                            .foregroundColor(Color(.systemGray4))
                        Text("No lyrics found")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Try a different artist or title")
                            .font(.subheadline)
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                Button {
                                    let raw = result.syncedLyrics ?? result.plainLyrics ?? ""
                                    lyrics = SongMetadata.cleanLyrics(raw, title: songTitle, artist: songArtist)
                                    isPresented = false
                                } label: {
                                    LyricsRow(result: result)
                                }
                                .buttonStyle(PlainButtonStyle())
                                
                                if index < results.count - 1 {
                                    Divider().padding(.leading, 78)
                                }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .onAppear {
            if searchQuery.isEmpty {
                searchQuery = "\(songArtist) \(songTitle)"
                performSearch()
            }
        }
    }
    
    private func performSearch() {
        guard !searchQuery.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        
        Task {
            let searchResults = await SongMetadata.searchLyrics(query: searchQuery)
            await MainActor.run {
                self.results = searchResults
                self.isLoading = false
            }
        }
    }
}

struct LyricsRow: View {
    let result: LRCLIBResult
    
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Color(uiColor: .systemGray6)
                Image(systemName: "text.quote")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor.opacity(0.7))
            }
            .frame(width: 48, height: 48)
            .cornerRadius(10)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(result.trackName ?? "Unknown Title")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Text(result.artistName ?? "Unknown Artist")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                if let album = result.albumName, !album.isEmpty, album.lowercased() != "null" {
                    Text(album)
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if result.syncedLyrics != nil {
                Image(systemName: "timer")
                    .font(.caption2)
                    .foregroundColor(.accentColor.opacity(0.6))
                    .padding(.trailing, 4)
            }
            
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(uiColor: .tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
