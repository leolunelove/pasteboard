import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct BoardVideo: Codable, Equatable {
    var file: String?
    var youtubeID: String?
    var title: String
    var start: Int? = nil
    var isValid: Bool {
        guard !title.isEmpty, title.count <= 250, (0...86400).contains(start ?? 0) else { return false }
        if let file {
            return youtubeID == nil && file == URL(fileURLWithPath: file).lastPathComponent
                && VideoMedia.isMovie(URL(fileURLWithPath: file))
        }
        return youtubeID.map(YouTubeLink.validID) == true
    }
}
enum YouTubeLink {
    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
    static func parse(_ text: String) -> BoardVideo? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
            url.port == nil || url.port == 443, let host = url.host?.lowercased()
        else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id: String?
        if ["youtu.be", "www.youtu.be"].contains(host), path.count == 1 {
            id = path.first
        } else if [
            "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
            "www.youtube-nocookie.com",
        ].contains(host) {
            if path == ["watch"] {
                id = query.first { $0.name == "v" }?.value
            } else if path.count == 2 && ["shorts", "live", "embed"].contains(path[0]) {
                id = path[1]
            } else {
                id = nil
            }
        } else {
            return nil
        }
        guard let id, validID(id) else { return nil }
        let time = query.first { $0.name == "t" || $0.name == "start" }?.value ?? "0"
        var seconds = Int(time) ?? 0
        if Int(time) == nil,
            let regex = try? NSRegularExpression(pattern: "^(?:(\\d+)h)?(?:(\\d+)m)?(?:(\\d+)s)?$"),
            let match = regex.firstMatch(in: time, range: NSRange(time.startIndex..., in: time))
        {
            seconds = [3600, 60, 1].enumerated().reduce(0) { sum, part in
                guard let range = Range(match.range(at: part.offset + 1), in: time) else { return sum }
                return sum + min(86400, Int(time[range]) ?? 0) * part.element
            }
        }
        return BoardVideo(youtubeID: id, title: "YouTube · \(id)", start: min(86400, max(0, seconds)))
    }
    static func watchURL(_ video: BoardVideo) -> URL? {
        guard let id = video.youtubeID, validID(id) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)&t=\(video.start ?? 0)")
    }
    static func playerRequest(_ video: BoardVideo) -> URLRequest? {
        guard let id = video.youtubeID, validID(id) else { return nil }
        let referrer = "https://fun.leolune.gather/"
        var components = URLComponents(string: "https://www.youtube-nocookie.com/embed/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"), URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "start", value: String(video.start ?? 0)),
            URLQueryItem(name: "origin", value: String(referrer.dropLast())),
        ]
        var request = URLRequest(url: components.url!)
        // YouTube requires the registered app's identity on embedded-player requests.
        // https://developers.google.com/youtube/terms/required-minimum-functionality#embedded-player-api-client-identity
        request.setValue(referrer, forHTTPHeaderField: "Referer")
        return request
    }
}
struct PreparedVideo {
    var video: BoardVideo
    var poster: String
    var size: CGSize
}
enum VideoMedia {
    static let queue = DispatchQueue(label: "Pasteboard.video-import", qos: .userInitiated)
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .init("public.mpeg-4"), .init("com.apple.quicktime-movie"), .init("public.movie"),
    ]
    static func isMovie(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "webm", "avi", "mpeg", "mpg"].contains(url.pathExtension.lowercased())
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }
    private final class Inspection: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<(CGSize, CGImage?), Error>?
        func finish(_ value: Result<(CGSize, CGImage?), Error>) {
            lock.lock()
            result = value
            lock.unlock()
            done.signal()
        }
        func value() throws -> (CGSize, CGImage?) {
            lock.lock()
            defer { lock.unlock() }
            return try result!.get()
        }
    }
    // Imports run on the video queue. The synchronous portable-file reader shares
    // this bounded bridge while AVFoundation loads metadata and frames asynchronously.
    static func inspect(_ url: URL) throws -> (CGSize, CGImage?) {
        let inspection = Inspection()
        Task.detached {
            do { inspection.finish(.success(try await inspectAsync(url))) } catch {
                inspection.finish(.failure(error))
            }
        }
        guard inspection.done.wait(timeout: .now() + 30) == .success else {
            throw BoardExport.error("This video took too long to open. Try another MP4 or MOV.")
        }
        return try inspection.value()
    }
    private static func inspectAsync(_ url: URL) async throws -> (CGSize, CGImage?) {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard playable, let track = tracks.first else {
            throw BoardExport.error(
                "This video cannot be played on this Mac. Try an MP4 or MOV with a supported video codec.")
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: abs(rect.width), height: abs(rect.height))
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let duration = try await asset.load(.duration).seconds
        let time = CMTime(
            seconds: duration.isFinite ? min(0.25, max(0, duration / 2)) : 0, preferredTimescale: 600)
        let image = try? await generator.image(at: time).image
        return (size, image)
    }
    static func poster(image: CGImage?, title: String, youtube: Bool, size: CGSize) throws -> Data {
        let ratio = min(2, max(0.5, size.width / max(1, size.height)))
        let width = 640
        let height = Int(ceil(CGFloat(width) / ratio))
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(NSColor(hex: 0x20232D).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let image {
            let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
            let rect = CGRect(
                x: (CGFloat(width) - CGFloat(image.width) * scale) / 2,
                y: (CGFloat(height) - CGFloat(image.height) * scale) / 2, width: CGFloat(image.width) * scale,
                height: CGFloat(image.height) * scale)
            NSImage(cgImage: image, size: .zero).draw(
                in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let centre = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(ovalIn: CGRect(x: centre.x - 38, y: centre.y - 38, width: 76, height: 76)).fill()
        NSColor.white.setFill()
        let triangle = NSBezierPath()
        triangle.move(to: CGPoint(x: centre.x - 9, y: centre.y - 17))
        triangle.line(to: CGPoint(x: centre.x + 19, y: centre.y))
        triangle.line(to: CGPoint(x: centre.x - 9, y: centre.y + 17))
        triangle.close()
        triangle.fill()
        NSColor.black.withAlphaComponent(0.72).setFill()
        CGRect(x: 0, y: height - 42, width: width, height: 42).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        ((youtube ? "YouTube · Press Play" : title) as NSString).draw(
            in: CGRect(x: 16, y: height - 31, width: width - 32, height: 24),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ])
        guard let bitmap = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
    static func prepare(_ url: URL, assets: URL) throws -> PreparedVideo {
        let (_, frame) = try inspect(url)
        let measured =
            frame.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 640, height: 360)
        let name = UUID().uuidString + "." + url.pathExtension.lowercased()
        let posterName = UUID().uuidString + ".png"
        let title = String(url.lastPathComponent.prefix(250))
        let data = try poster(image: frame, title: title, youtube: false, size: measured)
        let target = assets.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: target)
        do { try data.write(to: assets.appendingPathComponent(posterName), options: .atomic) } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        let image = NSBitmapImageRep(data: data)!
        return PreparedVideo(
            video: BoardVideo(file: name, title: title), poster: posterName,
            size: CGSize(width: image.pixelsWide, height: image.pixelsHigh))
    }
}
extension Card {
    var assetNames: [String] { [asset, video?.file].compactMap { $0 } }
    var isVideo: Bool { video != nil }
}
extension BoardStore {
    func videoCard(_ prepared: PreparedVideo) -> Card {
        let scale = 440 / max(prepared.size.width, prepared.size.height)
        return Card(
            x: 0, y: 0, width: max(40, prepared.size.width * scale),
            height: max(40, prepared.size.height * scale),
            asset: prepared.poster, video: prepared.video)
    }
    func youtubeCard(_ video: BoardVideo) throws -> Card {
        guard video.isValid, video.youtubeID != nil else { throw CocoaError(.fileReadCorruptFile) }
        let name = UUID().uuidString + ".png"
        try VideoMedia.poster(
            image: nil, title: video.title, youtube: true, size: CGSize(width: 640, height: 360)
        )
        .write(to: directory.appendingPathComponent("Assets").appendingPathComponent(name), options: .atomic)
        return Card(
            x: 0, y: 0, width: 440, height: 247.5, asset: name,
            sourceURL: YouTubeLink.watchURL(video)?.absoluteString, video: video)
    }
}
