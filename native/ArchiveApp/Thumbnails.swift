import AppKit
import ImageIO
import SwiftUI

private final class CachedImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private actor ThumbnailStore {
    static let shared = ThumbnailStore()
    private let cache = NSCache<NSURL, CachedImage>()
    init() { cache.totalCostLimit = 48 * 1024 * 1024 }
    func image(at url: URL) -> CachedImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let cached = CachedImage(image)
        cache.setObject(cached, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return cached
    }
}

struct LocalThumbnail: View {
    let url: URL
    @State private var image: CGImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Rectangle().fill(.gray.opacity(0.12))
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else if failed { Label("Preview unavailable", systemImage: "photo").font(.caption) }
            else { ProgressView().controlSize(.small) }
        }
        .task(id: url) {
            image = nil
            failed = false
            let result = await ThumbnailStore.shared.image(at: url)
            guard !Task.isCancelled else { return }
            image = result?.image
            failed = result == nil
        }
    }
}
