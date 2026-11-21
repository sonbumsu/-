import Foundation

/// 맥(호스트)과 아이패드(뷰어)가 주고받는 메시지 정의.
///
/// 전송 형식: `[type: UInt8][length: UInt32 BE][payload: length bytes]`
public enum ScreenLink {
    public static let protocolVersion = 1
    public static let bonjourType = "_screenlink._tcp"
    public static let defaultPort: UInt16 = 52020
}

public enum MessageType: UInt8, Sendable {
    case hello = 1           // 뷰어 → 호스트 (JSON: Hello)
    case helloAck = 2        // 호스트 → 뷰어 (JSON: HelloAck)
    case video = 3           // 호스트 → 뷰어 (binary: VideoFrame)
    case input = 4           // 뷰어 → 호스트 (binary: InputEvent)
    case requestKeyframe = 5 // 뷰어 → 호스트 (빈 payload)
    case ping = 6
    case pong = 7
    case bye = 8
}

public enum ProtocolError: Error, Equatable {
    case unknownType(UInt8)
    case payloadTooLarge(Int)
    case malformed(String)
}

public struct Message: Sendable, Equatable {
    public static let headerSize = 5
    public static let maxPayloadSize = 16 * 1024 * 1024

    public var type: MessageType
    public var payload: Data

    public init(_ type: MessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    public func encoded() -> Data {
        var d = Data(capacity: Message.headerSize + payload.count)
        d.append(type.rawValue)
        d.appendBE(UInt32(payload.count))
        d.append(payload)
        return d
    }

    /// 5바이트 헤더를 해석해 (타입, payload 길이)를 돌려준다.
    public static func parseHeader(_ header: Data) throws -> (MessageType, Int) {
        guard header.count == headerSize else { throw ProtocolError.malformed("header size \(header.count)") }
        var r = ByteReader(header)
        let rawType = try r.readUInt8()
        let length = Int(try r.readUInt32())
        guard let type = MessageType(rawValue: rawType) else { throw ProtocolError.unknownType(rawType) }
        guard length <= maxPayloadSize else { throw ProtocolError.payloadTooLarge(length) }
        return (type, length)
    }

    public static func json<T: Encodable>(_ type: MessageType, _ value: T) -> Message {
        // 우리가 정의한 단순 구조체만 인코딩하므로 실패하지 않는다.
        Message(type, payload: (try? JSONEncoder().encode(value)) ?? Data())
    }

    public func decodeJSON<T: Decodable>(_: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: payload)
    }
}

// MARK: - 핸드셰이크

public enum SessionMode: String, Codable, Sendable, CaseIterable {
    case extend   // 아이패드를 맥의 서브 모니터로
    case mirror   // 맥 메인 화면을 그대로 보여주기
}

public struct Hello: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var deviceName: String
    public var pin: String
    public var mode: SessionMode
    /// 뷰어 화면 크기 (포인트 단위)와 배율. 확장 모드에서 가상 디스플레이 크기를 정할 때 쓴다.
    public var pointWidth: Int
    public var pointHeight: Int
    public var scale: Double
    public var maxFPS: Int

    public init(deviceName: String, pin: String, mode: SessionMode,
                pointWidth: Int, pointHeight: Int, scale: Double, maxFPS: Int = 60) {
        self.protocolVersion = ScreenLink.protocolVersion
        self.deviceName = deviceName
        self.pin = pin
        self.mode = mode
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.scale = scale
        self.maxFPS = maxFPS
    }
}

public struct HelloAck: Codable, Sendable, Equatable {
    public var accepted: Bool
    public var reason: String?
    public var videoWidth: Int
    public var videoHeight: Int
    public var hostName: String

    public init(accepted: Bool, reason: String? = nil, videoWidth: Int = 0, videoHeight: Int = 0, hostName: String = "") {
        self.accepted = accepted
        self.reason = reason
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.hostName = hostName
    }
}

// MARK: - 입력 이벤트

public struct InputEvent: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case move = 1
        case leftDown = 2
        case leftDrag = 3
        case leftUp = 4
        case rightClick = 5
        case scroll = 6
    }

    public var kind: Kind
    /// 영상 영역 기준 정규화 좌표 (0...1)
    public var x: Float
    public var y: Float
    /// 스크롤 양 (뷰어 포인트 단위)
    public var dx: Float
    public var dy: Float

    public init(_ kind: Kind, x: Float = 0, y: Float = 0, dx: Float = 0, dy: Float = 0) {
        self.kind = kind
        self.x = x
        self.y = y
        self.dx = dx
        self.dy = dy
    }

    public static let encodedSize = 17

    public func encoded() -> Data {
        var d = Data(capacity: InputEvent.encodedSize)
        d.append(kind.rawValue)
        d.appendBE(x.bitPattern)
        d.appendBE(y.bitPattern)
        d.appendBE(dx.bitPattern)
        d.appendBE(dy.bitPattern)
        return d
    }

    public init(decoding data: Data) throws {
        var r = ByteReader(data)
        let raw = try r.readUInt8()
        guard let kind = Kind(rawValue: raw) else { throw ProtocolError.malformed("input kind \(raw)") }
        self.kind = kind
        self.x = Float(bitPattern: try r.readUInt32())
        self.y = Float(bitPattern: try r.readUInt32())
        self.dx = Float(bitPattern: try r.readUInt32())
        self.dy = Float(bitPattern: try r.readUInt32())
    }

    public var message: Message { Message(.input, payload: encoded()) }
}

// MARK: - 영상 프레임

/// H.264 프레임 한 장. NAL 유닛은 AVCC 형식(4바이트 길이 접두사)이다.
public struct VideoFrame: Sendable, Equatable {
    public var isKeyframe: Bool
    /// 프레젠테이션 시각 (나노초)
    public var timestampNs: UInt64
    /// 키프레임일 때만 들어 있는 SPS/PPS
    public var parameterSets: [Data]
    public var data: Data

    public init(isKeyframe: Bool, timestampNs: UInt64, parameterSets: [Data] = [], data: Data) {
        self.isKeyframe = isKeyframe
        self.timestampNs = timestampNs
        self.parameterSets = parameterSets
        self.data = data
    }

    public func encoded() -> Data {
        var d = Data(capacity: 16 + data.count + parameterSets.reduce(0) { $0 + $1.count + 2 })
        d.append(isKeyframe ? 1 : 0)
        d.appendBE(timestampNs)
        d.append(UInt8(parameterSets.count))
        for ps in parameterSets {
            d.appendBE(UInt16(ps.count))
            d.append(ps)
        }
        d.append(data)
        return d
    }

    public init(decoding payload: Data) throws {
        var r = ByteReader(payload)
        let flags = try r.readUInt8()
        isKeyframe = flags & 1 != 0
        timestampNs = try r.readUInt64()
        let count = Int(try r.readUInt8())
        var sets: [Data] = []
        for _ in 0..<count {
            let len = Int(try r.readUInt16())
            sets.append(try r.readData(len))
        }
        parameterSets = sets
        data = r.readRemaining()
    }

    public var message: Message { Message(.video, payload: encoded()) }
}

// MARK: - 바이트 도우미

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    private mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.endIndex else { throw ProtocolError.malformed("unexpected end") }
        var value: T = 0
        for i in 0..<size {
            value = (value << 8) | T(data[offset + i])
        }
        offset += size
        return value
    }

    mutating func readUInt8() throws -> UInt8 { try read(UInt8.self) }
    mutating func readUInt16() throws -> UInt16 { try read(UInt16.self) }
    mutating func readUInt32() throws -> UInt32 { try read(UInt32.self) }
    mutating func readUInt64() throws -> UInt64 { try read(UInt64.self) }

    mutating func readData(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.endIndex else { throw ProtocolError.malformed("unexpected end") }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func readRemaining() -> Data {
        defer { offset = data.endIndex }
        return data.subdata(in: offset..<data.endIndex)
    }
}
