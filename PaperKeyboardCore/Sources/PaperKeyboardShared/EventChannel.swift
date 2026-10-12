import Foundation

/// 메인 앱 → 키보드 확장 이벤트 채널.
/// App Group 폴더의 `events.log`에 이벤트를 JSON 한 줄씩(JSON Lines) 쌓는다.
/// Darwin 알림은 "새 이벤트 있음" 깨우기 용도일 뿐, 데이터는 항상 이 파일에서 읽는다.
public struct EventChannel: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// 이보다 오래된 이벤트는 입력하지 않고 건너뛴다 (초).
        public var maxEventAge: Double = 3
        /// 파일에 남겨 둘 최근 이벤트 수. 두 배를 넘으면 잘라낸다.
        public var maxStoredEvents: Int = 200

        public init() {}
    }

    public enum ChannelError: LocalizedError {
        case appGroupUnavailable

        public var errorDescription: String? {
            "App Group 폴더를 열 수 없음 (그룹 미등록, 서명 문제, 또는 키보드 Full Access 꺼짐)"
        }
    }

    /// 파일을 읽은 결과. 읽지 못한 줄 수도 같이 돌려줘 조용히 묻히지 않게 한다.
    public struct Snapshot: Equatable, Sendable {
        public var events: [KeyEvent]
        /// 해석 실패한 줄 수. 쓰는 중인 마지막 줄이면 다음 읽기에서 정상으로 읽힌다.
        public var unreadableLines: Int
    }

    public static let fileName = "events.log"
    public static let darwinNotificationName = "com.junjjang.PaperKeyboard.events.changed"

    public let fileURL: URL
    public let configuration: Configuration

    public init(directory: URL, configuration: Configuration = Configuration()) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.configuration = configuration
    }

    public static func inAppGroup(configuration: Configuration = Configuration()) throws -> EventChannel {
        guard let directory = AppGroup.containerURL else { throw ChannelError.appGroupUnavailable }
        return EventChannel(directory: directory, configuration: configuration)
    }

    /// 파일이 아직 없으면 빈 결과.
    public func read() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Snapshot(events: [], unreadableLines: 0)
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        var events: [KeyEvent] = []
        var unreadable = 0
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let event = try? decoder.decode(KeyEvent.self, from: Data(line)) {
                events.append(event)
            } else {
                unreadable += 1
            }
        }
        return Snapshot(events: events, unreadableLines: unreadable)
    }
}

// MARK: - 쓰기 (메인 앱 전용)

/// 이벤트를 파일 끝에 추가한다. 쓰는 쪽은 메인 앱 하나뿐이라고 가정한다.
public struct EventLogWriter: Sendable {
    public let channel: EventChannel
    public private(set) var lastSeq: UInt64
    private var storedCount: Int

    /// 기존 파일의 마지막 순번에서 이어서 쓴다 (앱을 다시 켜도 순번이 되돌아가지 않게).
    public init(channel: EventChannel) throws {
        let snapshot = try channel.read()
        self.channel = channel
        self.lastSeq = snapshot.events.map(\.seq).max() ?? 0
        self.storedCount = snapshot.events.count
    }

    @discardableResult
    public mutating func append(kind: KeyKind, value: String?, timestamp: Double) throws -> KeyEvent {
        let event = KeyEvent(seq: lastSeq + 1, kind: kind, value: value, timestamp: timestamp)
        var line = try Self.encoder.encode(event)
        line.append(UInt8(ascii: "\n"))

        let url = channel.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            // 이전 쓰기가 줄 중간에서 끊겼다면 새 줄에서 시작해 두 줄이 붙지 않게 한다.
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) {
                    line.insert(UInt8(ascii: "\n"), at: 0)
                }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }

        lastSeq = event.seq
        storedCount += 1
        if storedCount > channel.configuration.maxStoredEvents * 2 {
            try trim()
        }
        return event
    }

    /// 최근 이벤트만 남기고 파일을 통째로 교체한다. 교체는 원자적이라 읽는 쪽은 옛 파일이나 새 파일 중 하나를 본다.
    private mutating func trim() throws {
        let kept = try channel.read().events.suffix(channel.configuration.maxStoredEvents)
        var data = Data()
        for event in kept {
            data.append(try Self.encoder.encode(event))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: channel.fileURL, options: .atomic)
        storedCount = kept.count
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

// MARK: - 읽기 판단 (키보드 확장)

/// 키보드가 어디까지 입력했는지. 컨트롤러 인스턴스가 아니라 공유 저장소에 보관해야 한다.
public struct EventCursor: Equatable, Sendable {
    public private(set) var lastSeq: UInt64

    public init(lastSeq: UInt64) {
        self.lastSeq = lastSeq
    }

    /// 키보드가 처음 뜰 때: 지금까지의 이벤트는 재생하지 않고 최신 순번부터 시작한다.
    public static func startingAtLatest(of events: [KeyEvent]) -> EventCursor {
        EventCursor(lastSeq: events.map(\.seq).max() ?? 0)
    }

    /// 새로 입력할 이벤트를 순번 순서로 돌려주고 커서를 옮긴다.
    /// - 이미 처리한 순번, 중복 줄은 무시한다.
    /// - `maxAge`보다 오래된 이벤트는 입력하지 않지만 커서는 그 뒤로 옮긴다.
    /// - 파일의 최대 순번이 커서보다 작으면 (앱 재설치 등으로 순번이 처음부터 다시 시작) 재생 없이 다시 맞춘다.
    public mutating func consume(_ events: [KeyEvent], now: Double, maxAge: Double) -> [KeyEvent] {
        guard let maxSeq = events.map(\.seq).max() else { return [] }
        if maxSeq < lastSeq {
            lastSeq = maxSeq
            return []
        }

        var bySeq: [UInt64: KeyEvent] = [:]
        for event in events where event.seq > lastSeq {
            bySeq[event.seq] = bySeq[event.seq] ?? event
        }

        var fresh: [KeyEvent] = []
        for seq in bySeq.keys.sorted() {
            let event = bySeq[seq]!
            lastSeq = seq
            if now - event.timestamp <= maxAge {
                fresh.append(event)
            }
        }
        return fresh
    }
}
