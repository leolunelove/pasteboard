import Foundation

func spacingMathTest() throws {
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
    func target(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> SnapTarget {
        SnapTarget(id: UUID(), rect: CGRect(x: x, y: y, width: w, height: h))
    }
    func verify(_ guide: SpacingGuide, distance: Double) throws {
        try check(guide.spans.count == 2 && close(guide.distance, distance))
        for span in guide.spans { try check(close(span.to - span.from, distance)) }
    }
    let a = target(0, 0, 100, 100)
    let b = target(140, 0, 160, 100)
    for (raw, expected) in [(337.0, 340.0), (-124, -120)] {
        var session = SnapSession()
        let result = session.snap(CGRect(x: raw, y: 20, width: 80, height: 60), to: [a, b], zoom: 1)
        try check(close(result.rect.minX, expected))
        try verify(result.spacingGuides.first(where: { $0.axis == .x })!, distance: 40)
    }
    var centered = SnapSession()
    let between = centered.snap(
        CGRect(x: 164, y: 20, width: 80, height: 60), to: [a, target(300, 0, 160, 100)], zoom: 1)
    try check(close(between.rect.minX, 160))
    try verify(between.spacingGuides.first!, distance: 60)
    var vertical = SnapSession()
    let column = vertical.snap(
        CGRect(x: 20, y: 337, width: 60, height: 80), to: [target(0, 0, 100, 100), target(0, 140, 100, 160)],
        zoom: 1)
    try check(close(column.rect.minY, 340))
    try verify(column.spacingGuides.first(where: { $0.axis == .y })!, distance: 40)
    var middleColumn = SnapSession()
    let centeredColumn = middleColumn.snap(
        CGRect(x: 20, y: 164, width: 60, height: 80), to: [target(0, 0, 100, 100), target(0, 300, 100, 160)],
        zoom: 1)
    try check(close(centeredColumn.rect.minY, 160))
    try verify(centeredColumn.spacingGuides.first(where: { $0.axis == .y })!, distance: 60)
    for zoom in [0.1, 0.625, 1, 2, 4] {
        let references = [target(0, 0, 2000, 2000), target(2040, 0, 2000, 2000)]
        var session = SnapSession()
        let captured = session.snap(
            CGRect(x: 4080 + 5 / zoom, y: 200, width: 500, height: 500), to: references, zoom: zoom)
        try check(close(captured.rect.minX, 4080))
        try verify(captured.spacingGuides.first(where: { $0.axis == .x })!, distance: 40)
        session.reset()
        let outside = session.snap(
            CGRect(x: 4080 + 11 / zoom, y: 200, width: 500, height: 500), to: references, zoom: zoom)
        try check(outside.spacingGuides.isEmpty)
    }
    var sticky = SnapSession()
    _ = sticky.snap(CGRect(x: 337, y: 20, width: 80, height: 60), to: [a, b], zoom: 1)
    try check(
        sticky.snap(CGRect(x: 348, y: 20, width: 80, height: 60), to: [a, b], zoom: 1).rect.minX == 340)
    try check(
        sticky.snap(CGRect(x: 351, y: 20, width: 80, height: 60), to: [a, b], zoom: 1).spacingGuides.isEmpty)
    for references in [
        [a, target(140, 300, 160, 100)], [a, target(80, 0, 160, 100)], [a, b, target(115, 0, 10, 100)],
    ] {
        var session = SnapSession()
        try check(
            session.snap(CGRect(x: 337, y: 20, width: 80, height: 60), to: references, zoom: 1).spacingGuides
                .isEmpty)
    }
    let edge = target(342, 200, 100, 100)
    var competition = SnapSession()
    let nearerEdge = competition.snap(
        CGRect(x: 343, y: 20, width: 80, height: 60), to: [a, b, edge], zoom: 1)
    try check(nearerEdge.rect.minX == 342 && nearerEdge.spacingGuides.isEmpty)
    competition.reset()
    try check(
        competition.snap(CGRect(x: 340, y: 20, width: 80, height: 60), to: [a, b, edge], zoom: 1).rect.minX
            == 340)
    var constrained = SnapSession()
    let disabled = constrained.snap(
        CGRect(x: 337, y: 20, width: 80, height: 60), to: [a, b], zoom: 1, xEnabled: false)
    try check(disabled.rect.minX == 337 && disabled.spacingGuides.isEmpty)
    // A wide group can fit between neighbours even when their total separation is large.
    var wide = SnapSession()
    let wideResult = wide.snap(
        CGRect(x: 204, y: 20, width: 700, height: 60), to: [a, target(1000, 0, 100, 100)], zoom: 1)
    try check(wideResult.rect.minX == 200)
    try verify(wideResult.spacingGuides.first!, distance: 100)
    let firstGroup = UUID()
    let secondGroup = UUID()
    var cards = [
        Card(x: 0, y: 0, width: 40, height: 100, text: "A"),
        Card(x: 60, y: 0, width: 40, height: 100, text: "A2"),
        Card(x: 140, y: 0, width: 80, height: 100, text: "B"),
        Card(x: 240, y: 0, width: 60, height: 100, text: "B2"),
    ]
    for i in cards.indices { cards[i].groupID = i < 2 ? firstGroup : secondGroup }
    let objects = SnapTarget.objects(in: cards, excluding: [])
    var groups = SnapSession()
    let groupResult = groups.snap(CGRect(x: 337, y: 20, width: 80, height: 60), to: objects, zoom: 1)
    try check(objects.count == 2 && groupResult.rect.minX == 340)
    try verify(groupResult.spacingGuides.first!, distance: 40)
    print(
        "PASS: repeated/between spacing, rows/columns, unequal sizes, zoom, hysteresis, occlusion, edge competition, axis locks and grouped bounds"
    )
}

func updateChannelTest(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let release = LocalRelease(
        formatVersion: 1, version: "0.6.0", build: 6,
        appURL: directory.appendingPathComponent("Gather.app").absoluteString,
        archiveURL: directory.appendingPathComponent("Gather-Mac.zip").absoluteString,
        releasedAt: "2026-11-14T00:00:00Z", notes: ["Equal spacing", "App updates"])
    let data = try JSONEncoder().encode(release)
    let decoded = try LocalRelease.decode(data)
    try check(decoded.availability(installedBuild: 5) == .update)
    try check(decoded.availability(installedBuild: 6) == .current)
    try check(decoded.availability(installedBuild: 7) == .newerInstalled)
    let feed = directory.appendingPathComponent("Gather-Latest.json")
    try data.write(to: feed, options: .atomic)
    let loaded = try LocalRelease.read(at: feed)
    try check(loaded.version == "0.6.0" && loaded.notes.count == 2)
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    object["appURL"] = "https://example.invalid/Gather.app"
    let remote = try JSONSerialization.data(withJSONObject: object)
    try check((try? LocalRelease.decode(remote)) == nil)
    try check((try? LocalRelease.decode(Data("not a release".utf8))) == nil)
    try check((try? LocalRelease.read(at: URL(string: "https://example.invalid/feed.json")!)) == nil)
    print(
        "PASS: local update channel, installed/latest comparison, release notes, invalid data and local-only links"
    )
}
