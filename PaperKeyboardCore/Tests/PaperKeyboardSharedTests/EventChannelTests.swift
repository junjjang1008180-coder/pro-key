import Foundation
import Testing
@testable import PaperKeyboardShared

struct EventChannelTests {
    // MARK: 쓰기 / 파일

    @Test func 순번은_1부터_증가하고_다시_열어도_이어진다() throws {
        let channel = EventChannel(directory: try Self.temporaryDirectory())
        var writer = try EventLogWriter(channel: channel)
        try writer.append(kind: .char, value: "a", timestamp: 1)
        try writer.append(kind: .space, value: nil, timestamp: 2)

        var reopened = try EventLogWriter(channel: channel)
        let third = try reopened.append(kind: .char, value: "b", timestamp: 3)

        #expect(third.seq == 3)
        let snapshot = try channel.read()
        #expect(snapshot.events.map(\.seq) == [1, 2, 3])
        #expect(snapshot.events[1] == KeyEvent(seq: 2, kind: .space, value: nil, timestamp: 2))
        #expect(snapshot.unreadableLines == 0)
    }

    @Test func 파일이_없으면_빈_결과() throws {
        let channel = EventChannel(directory: try Self.temporaryDirectory())
        #expect(try channel.read() == EventChannel.Snapshot(events: [], unreadableLines: 0))
    }

    @Test func 오래된_줄은_잘라내도_순번은_이어진다() throws {
        var configuration = EventChannel.Configuration()
        configuration.maxStoredEvents = 5
        let channel = EventChannel(directory: try Self.temporaryDirectory(), configuration: configuration)
        var writer = try EventLogWriter(channel: channel)
        for i in 1...20 {
            try writer.append(kind: .char, value: "x", timestamp: Double(i))
        }
        let seqs = try channel.read().events.map(\.seq)
        #expect(seqs.count <= 10)
        #expect(seqs.last == 20)
        #expect(seqs == Array(seqs.sorted()))
    }

    @Test func 줄_중간에서_끊긴_쓰기는_건너뛰고_다음_쓰기와_붙지_않는다() throws {
        let channel = EventChannel(directory: try Self.temporaryDirectory())
        var writer = try EventLogWriter(channel: channel)
        try writer.append(kind: .char, value: "a", timestamp: 1)

        // 앱이 쓰다가 죽어 줄바꿈 없이 반쪽 줄이 남은 상황
        let handle = try FileHandle(forWritingTo: channel.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":2,"ki"#.utf8))
        try handle.close()

        let broken = try channel.read()
        #expect(broken.events.map(\.seq) == [1])
        #expect(broken.unreadableLines == 1)

        try writer.append(kind: .char, value: "b", timestamp: 2)
        let repaired = try channel.read()
        #expect(repaired.events.map(\.value) == ["a", "b"])
        #expect(repaired.unreadableLines == 1)
    }

    // MARK: 읽기 판단 (커서)

    @Test func 처음_뜰_때는_과거_이벤트를_재생하지_않는다() {
        let past = [Self.event(1, at: 99), Self.event(2, at: 99.5)]
        var cursor = EventCursor.startingAtLatest(of: past)
        #expect(cursor.consume(past, now: 100, maxAge: 3).isEmpty)
        #expect(cursor.lastSeq == 2)
    }

    @Test func 새_이벤트만_한_번씩_입력한다() {
        var cursor = EventCursor(lastSeq: 2)
        let events = [Self.event(1, at: 100), Self.event(2, at: 100), Self.event(3, at: 100), Self.event(4, at: 100)]
        #expect(cursor.consume(events, now: 100, maxAge: 3).map(\.seq) == [3, 4])
        // 같은 파일을 다시 읽어도 (알림 + 폴링 중복) 다시 입력하지 않는다
        #expect(cursor.consume(events, now: 100, maxAge: 3).isEmpty)
        #expect(cursor.lastSeq == 4)
    }

    @Test func 중복_줄과_역순_줄은_순번_순서로_한_번만() {
        var cursor = EventCursor(lastSeq: 0)
        let events = [Self.event(3, at: 100), Self.event(1, at: 100), Self.event(3, at: 100), Self.event(2, at: 100)]
        #expect(cursor.consume(events, now: 100, maxAge: 3).map(\.seq) == [1, 2, 3])
    }

    @Test func 오래된_이벤트는_건너뛰되_커서는_넘어간다() {
        var cursor = EventCursor(lastSeq: 0)
        let events = [Self.event(1, at: 90), Self.event(2, at: 96.5), Self.event(3, at: 99)]
        #expect(cursor.consume(events, now: 100, maxAge: 3).map(\.seq) == [3])
        #expect(cursor.lastSeq == 3)
    }

    @Test func 순번이_처음부터_다시_시작되면_재생_없이_맞춘다() {
        // 앱 재설치 등으로 파일이 지워지고 순번이 1부터 다시 시작된 상황
        var cursor = EventCursor(lastSeq: 500)
        #expect(cursor.consume([Self.event(1, at: 100)], now: 100, maxAge: 3).isEmpty)
        #expect(cursor.lastSeq == 1)
        let next = cursor.consume([Self.event(1, at: 100), Self.event(2, at: 101)], now: 101, maxAge: 3)
        #expect(next.map(\.seq) == [2])
    }

    @Test func 빈_파일이면_커서를_건드리지_않는다() {
        var cursor = EventCursor(lastSeq: 7)
        #expect(cursor.consume([], now: 100, maxAge: 3).isEmpty)
        #expect(cursor.lastSeq == 7)
    }

    // MARK: 도우미

    static func event(_ seq: UInt64, at timestamp: Double) -> KeyEvent {
        KeyEvent(seq: seq, kind: .char, value: "a", timestamp: timestamp)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
