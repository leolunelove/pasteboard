import AVFoundation
import AVKit
import AppKit

func makeVideoFixture(at url: URL) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
    writer.add(input)
    try check(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<48 {
        try waitFor { input.isReadyForMoreMediaData }
        var buffer: CVPixelBuffer?
        try check(
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB, nil, &buffer)
                == kCVReturnSuccess)
        let pixel = buffer!
        CVPixelBufferLockBaseAddress(pixel, [])
        let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<180 {
            for x in 0..<320 {
                let index = y * stride + x * 4
                bytes[index] = 255
                bytes[index + 1] = UInt8((x + frame * 3) % 256)
                bytes[index + 2] = 120
                bytes[index + 3] = UInt8(y)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        try check(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)))
    }
    input.markAsFinished()
    var finished = false
    writer.finishWriting { DispatchQueue.main.async { finished = true } }
    try waitFor({ finished }, timeout: 20)
    try check(writer.status == .completed)
}

func videoAndGlobalReadyTest(directory: URL) throws {
    let store = BoardStore(directory: directory)
    let source = directory.appendingPathComponent("Sample.mp4")
    try makeVideoFixture(at: source)
    let root = store.board.id
    let page = store.newPage(in: root, name: "Clips")!
    let view = BoardView(store: store)
    view.frame = CGRect(x: 0, y: 0, width: 900, height: 650)
    view.importFiles([source])
    try waitFor({ !view.hasPendingImports }, timeout: 30)
    try check(store.board.cards.count == 1)
    let movie = store.board.cards[0]
    try check(movie.isVideo && movie.assetNames.count == 2 && BoardStore.valid(movie))
    let file = store.directory.appendingPathComponent("Assets").appendingPathComponent(movie.video!.file!)
    let originalBytes = try Data(contentsOf: source)
    let copiedBytes = try Data(contentsOf: file)
    try check(copiedBytes == originalBytes)
    let player = AVPlayer(url: file)
    player.isMuted = true
    player.play()
    try waitFor({ player.currentTime().seconds > 0.2 }, timeout: 15)
    player.pause()
    try check(player.rate == 0)
    let playback = VideoPlayerWindow(store: store, boardID: page, card: movie)
    let native = playback.window!.contentView!.subviews.compactMap { $0 as? AVPlayerView }.first!
    native.player!.isMuted = true
    native.player!.play()
    try waitFor({ native.player!.currentTime().seconds > 0.1 }, timeout: 15)
    playback.close()
    try check(native.player!.currentItem == nil)
    var played: UUID?
    view.onPlayVideo = { played = $0.id }
    view.selection = [movie.id]
    view.playVideo(nil)
    try check(played == movie.id && view.cropCandidate == nil)
    view.beginCropping(movie.id)
    try check(!view.isCropping)
    let testWindow = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.borderless],
        backing: .buffered, defer: false)
    testWindow.isReleasedWhenClosed = false
    testWindow.contentView = view
    let screenPoint = view.videoPlayRect(movie).origin
    let point = view.convert(CGPoint(x: screenPoint.x + 10, y: screenPoint.y + 10), to: nil)
    let click = NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: testWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
    played = nil
    view.mouseDown(with: click)
    try check(played == movie.id && !view.isCropping)
    testWindow.contentView = NSView()
    testWindow.close()
    let copy = view.clipboardItem()!
    try check(copy.string(forType: .fileURL) == file.absoluteString)
    let youtube = YouTubeLink.parse("https://youtu.be/M7lc1UVf-VE?t=1m23s")!
    try check(youtube.start == 83)
    let request = YouTubeLink.playerRequest(youtube)!
    try check(request.value(forHTTPHeaderField: "Referer") == "https://fun.leolune.gather/")
    try check(request.url!.host == "www.youtube-nocookie.com")
    for link in [
        "https://www.youtube.com/watch?v=M7lc1UVf-VE", "https://www.youtube.com/shorts/M7lc1UVf-VE",
        "https://m.youtube.com/live/M7lc1UVf-VE",
    ] {
        try check(YouTubeLink.parse(link)?.youtubeID == youtube.youtubeID)
    }
    for link in [
        "https://youtube.com.evil.test/watch?v=M7lc1UVf-VE", "https://example.com/M7lc1UVf-VE",
        "javascript:M7lc1UVf-VE", "https://youtube.com/watch?v=../../x",
        "https://youtube.com/playlist?list=123", "some text https://youtu.be/M7lc1UVf-VE",
    ] {
        try check(YouTubeLink.parse(link) == nil)
    }
    let pb = NSPasteboard(name: .init("Pasteboard.video-test." + UUID().uuidString))
    defer { pb.releaseGlobally() }
    pb.setString(YouTubeLink.watchURL(youtube)!.absoluteString, forType: .string)
    try check(view.receive(pb, at: CGPoint(x: 500, y: 0)))
    let online = store.board.cards.last!
    try check(online.video?.youtubeID == youtube.youtubeID)
    let note = Card(x: 0, y: 500, width: 260, height: 120, text: "Clip notes")
    store.replaceCards(store.board.cards + [note], name: "Add note")
    for ids: Set<UUID> in [[movie.id], [online.id], [movie.id, note.id]] {
        do {
            _ = try store.markReady(ids)
            throw BoardExport.error("Video incorrectly marked")
        } catch { try check(error.localizedDescription.contains("cannot be marked")) }
    }
    let image = Card(x: 300, y: 500, width: 260, height: 140, asset: movie.asset)
    store.replaceCards(store.board.cards + [image], name: "Add image")
    _ = try store.markReady([image.id])
    let other = store.newPage(in: root, name: "Image drafts")!
    let image2 = Card(x: 0, y: 0, width: 260, height: 140, asset: movie.asset)
    store.replaceCards([image2], name: "Add image")
    _ = try store.markReady([image2.id])
    store.newBoard(name: "Another workspace")
    let otherRoot = store.board.id
    let image3 = Card(x: 0, y: 0, width: 260, height: 140, asset: movie.asset)
    store.replaceCards([image3], name: "Add image")
    _ = try store.markReady([image3.id])
    try check(
        store.allReadyPosts.count == 3 && store.readyPosts(in: root).count == 2
            && store.readyPosts(in: otherRoot).count == 1)
    store.activate(page)
    try check(store.save())
    let reloaded = BoardStore(directory: directory)
    try check(reloaded.board.cards.contains(movie) && reloaded.allReadyPosts.count == 3)
    let portable = try reloaded.portableData()
    let imported = BoardStore(directory: directory.appendingPathComponent("Imported"))
    try imported.importBoard(data: portable)
    let importedVideo = imported.board.cards.first(where: \.isVideo)!
    try check(importedVideo.assetNames.allSatisfy(imported.hasAsset) && BoardStore.valid(importedVideo))
    let importedBytes = try Data(
        contentsOf: imported.directory.appendingPathComponent("Assets").appendingPathComponent(
            importedVideo.video!.file!))
    try check(importedBytes == originalBytes)
    try reloaded.backups.capture(reloaded.workspace, force: true)
    let restored = try reloaded.backups.restoredBoards(
        from: reloaded.backups.records().first!,
        assetsDirectory: directory.appendingPathComponent("RestoredAssets"))
    let restoredVideo = restored.flatMap(\.cards).first { $0.video?.file != nil }!
    try check(restoredVideo.id != movie.id && restoredVideo.video?.file != movie.video?.file)
    try check(
        restoredVideo.assetNames.allSatisfy {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("RestoredAssets").appendingPathComponent($0).path)
        })
    _ = reloaded.moveCards([movie.id], from: page, to: other, viewport: CGSize(width: 900, height: 650))
    try check(
        reloaded.workspace.boards.first { $0.id == other }!.cards.contains {
            $0.id == movie.id && $0.video == movie.video
        })
    reloaded.history.undo()
    try check(reloaded.workspace.boards.first { $0.id == page }!.cards.contains(movie))
    print(
        "PASS: local video import/bytes/posters/play/pause, YouTube URL/referrer/clipboard parsing, excluded video posts, global ready scoping, save/reopen, portable files, backup media remapping and transfer/undo"
    )
}
