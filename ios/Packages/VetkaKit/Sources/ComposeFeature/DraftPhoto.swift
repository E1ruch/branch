import Foundation

struct DraftPhoto: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var mediaID: Int64?

    var url: URL { DraftPhotoFiles.folder.appending(path: "\(id.uuidString).jpg") }
}

/// Draft metadata stays small for UserDefaults. JPEGs are written atomically to disk.
actor DraftPhotoFiles {
    static let shared = DraftPhotoFiles()
    static let folder = URL.applicationSupportDirectory.appending(path: "VetkaDraftPhotos", directoryHint: .isDirectory)

    func save(_ jpeg: Data) throws -> DraftPhoto {
        let photo = DraftPhoto()
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try jpeg.write(to: photo.url, options: .atomic)
        return photo
    }

    func read(_ photo: DraftPhoto) throws -> Data {
        try Data(contentsOf: photo.url)
    }

    func remove(_ photos: [DraftPhoto]) {
        for photo in photos {
            try? FileManager.default.removeItem(at: photo.url)
        }
    }
}
