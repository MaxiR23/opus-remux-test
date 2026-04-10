import Foundation

// MARK: - EBML Element IDs (Matroska/WebM subset)
enum EBMLElementID: UInt32 {
    case ebmlHeader       = 0x1A45DFA3
    case segment          = 0x18538067
    case tracks           = 0x1654AE6B
    case trackEntry       = 0xAE
    case codecID          = 0x86
    case codecPrivate     = 0x63A2
    case cluster          = 0x1F43B675
    case timecode         = 0xE7
    case simpleBlock      = 0xA3
    case segmentInfo      = 0x1549A966
    case seekHead         = 0x114D9B74
    case cues             = 0x1C53BB6B
    case trackType        = 0x83
    case trackNumber      = 0xD7
}

// MARK: - Parsed output
struct OpusPacket {
    let data: Data
    let timestampMs: Int64
    let isKeyframe: Bool
}

struct DemuxResult {
    let opusHead: Data
    let packets: [OpusPacket]
    let channels: UInt8
    let sampleRate: UInt32
}

// MARK: - WebMDemuxer
class WebMDemuxer {

    private var buffer: Data
    private var offset: Int = 0

    init(data: Data) {
        self.buffer = data
    }

    func demux() throws -> DemuxResult {
        offset = 0

        let ebmlHeader = try readElement()
        guard ebmlHeader.id == EBMLElementID.ebmlHeader.rawValue else {
            throw RemuxError.invalidEBML("Expected EBML header, got 0x\(String(ebmlHeader.id, radix: 16))")
        }

        let segmentId = try readElementID()
        let segmentSize = try readElementSize()
        guard segmentId == EBMLElementID.segment.rawValue else {
            throw RemuxError.invalidEBML("Expected Segment, got 0x\(String(segmentId, radix: 16))")
        }

        let segmentEnd: Int
        if segmentSize == Int.max {
            segmentEnd = buffer.count
        } else {
            segmentEnd = min(offset + segmentSize, buffer.count)
        }

        var opusHead: Data?
        var packets: [OpusPacket] = []
        var audioTrackNumber: UInt64 = 1

        while offset < segmentEnd {
            guard offset + 1 < buffer.count else { break }

            let id: UInt32
            let size: Int

            do {
                id = try readElementID()
                size = try readElementSize()
            } catch {
                break
            }

            let dataEnd: Int
            if size == Int.max {
                dataEnd = segmentEnd
            } else {
                dataEnd = min(offset + size, buffer.count)
            }

            switch id {
            case EBMLElementID.tracks.rawValue:
                let result = try parseTracks(end: dataEnd)
                opusHead = result.codecPrivate
                audioTrackNumber = result.trackNumber

            case EBMLElementID.cluster.rawValue:
                let clusterPackets = try parseCluster(
                    end: dataEnd,
                    audioTrackNumber: audioTrackNumber
                )
                packets.append(contentsOf: clusterPackets)

            default:
                if size != Int.max {
                    offset = dataEnd
                } else {
                    break
                }
            }
        }

        guard let head = opusHead else {
            throw RemuxError.noOpusTrack
        }

        let channels = head.count > 9 ? head[9] : 2
        let sampleRate: UInt32 = head.count >= 16
            ? head.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            : 48000

        return DemuxResult(
            opusHead: head,
            packets: packets,
            channels: channels,
            sampleRate: sampleRate
        )
    }

    // MARK: - Tracks parsing

    private struct TrackInfo {
        let codecPrivate: Data
        let trackNumber: UInt64
    }

    private func parseTracks(end: Int) throws -> TrackInfo {
        var codecPrivate: Data?
        var trackNumber: UInt64 = 1
        var foundOpus = false

        while offset < end {
            let id = try readElementID()
            let size = try readElementSize()
            let elemEnd = min(offset + size, end)

            if id == EBMLElementID.trackEntry.rawValue {
                let result = try parseTrackEntry(end: elemEnd)
                if result.isOpus {
                    codecPrivate = result.codecPrivate
                    trackNumber = result.trackNumber
                    foundOpus = true
                }
            }

            offset = elemEnd
        }

        guard foundOpus, let cp = codecPrivate else {
            throw RemuxError.noOpusTrack
        }

        return TrackInfo(codecPrivate: cp, trackNumber: trackNumber)
    }

    private struct TrackEntryResult {
        let isOpus: Bool
        let codecPrivate: Data?
        let trackNumber: UInt64
    }

    private func parseTrackEntry(end: Int) throws -> TrackEntryResult {
        var codecId: String?
        var codecPrivate: Data?
        var trackNum: UInt64 = 1

        while offset < end {
            let id = try readElementID()
            let size = try readElementSize()
            let elemEnd = min(offset + size, end)

            switch id {
            case EBMLElementID.codecID.rawValue:
                codecId = String(data: buffer.subdata(in: offset..<elemEnd), encoding: .ascii)

            case EBMLElementID.codecPrivate.rawValue:
                codecPrivate = buffer.subdata(in: offset..<elemEnd)

            case EBMLElementID.trackNumber.rawValue:
                trackNum = try readUInt(size: size)

            default:
                break
            }

            offset = elemEnd
        }

        let isOpus = codecId == "A_OPUS"
        return TrackEntryResult(isOpus: isOpus, codecPrivate: codecPrivate, trackNumber: trackNum)
    }

    // MARK: - Cluster parsing

    private func parseCluster(end: Int, audioTrackNumber: UInt64) throws -> [OpusPacket] {
        var packets: [OpusPacket] = []
        var clusterTimecode: Int64 = 0

        while offset < end {
            guard offset + 1 < buffer.count else { break }

            let id: UInt32
            let size: Int
            do {
                id = try readElementID()
                size = try readElementSize()
            } catch {
                break
            }

            let elemEnd: Int
            if size == Int.max {
                elemEnd = end
            } else {
                elemEnd = min(offset + size, end)
            }

            switch id {
            case EBMLElementID.timecode.rawValue:
                clusterTimecode = Int64(try readUInt(size: size))

            case EBMLElementID.simpleBlock.rawValue:
                if let packet = try parseSimpleBlock(
                    size: size,
                    clusterTimecode: clusterTimecode,
                    audioTrackNumber: audioTrackNumber
                ) {
                    packets.append(packet)
                }

            default:
                break
            }

            offset = elemEnd
        }

        return packets
    }

    private func parseSimpleBlock(
        size: Int,
        clusterTimecode: Int64,
        audioTrackNumber: UInt64
    ) throws -> OpusPacket? {
        let blockStart = offset

        let trackNum = try readVINT()

        guard offset + 2 <= buffer.count else { return nil }
        let relTimestamp = Int16(bigEndian: buffer.subdata(in: offset..<(offset + 2))
            .withUnsafeBytes { $0.load(as: Int16.self) })
        offset += 2

        guard offset < buffer.count else { return nil }
        let flags = buffer[offset]
        offset += 1

        let isKeyframe = (flags & 0x80) != 0

        let dataSize = size - (offset - blockStart)
        guard dataSize > 0, offset + dataSize <= buffer.count else { return nil }
        let packetData = buffer.subdata(in: offset..<(offset + dataSize))
        offset += dataSize

        guard trackNum == audioTrackNumber else { return nil }

        let timestampMs = clusterTimecode + Int64(relTimestamp)

        return OpusPacket(
            data: packetData,
            timestampMs: timestampMs,
            isKeyframe: isKeyframe
        )
    }

    // MARK: - EBML primitives

    private struct EBMLElement {
        let id: UInt32
        let size: Int
        let dataOffset: Int
    }

    private func readElement() throws -> EBMLElement {
        let id = try readElementID()
        let size = try readElementSize()
        let dataOffset = offset
        if size != Int.max {
            offset = min(offset + size, buffer.count)
        }
        return EBMLElement(id: id, size: size, dataOffset: dataOffset)
    }

    private func readElementID() throws -> UInt32 {
        guard offset < buffer.count else {
            throw RemuxError.unexpectedEnd
        }

        let first = buffer[offset]
        let length: Int

        if first & 0x80 != 0 { length = 1 }
        else if first & 0x40 != 0 { length = 2 }
        else if first & 0x20 != 0 { length = 3 }
        else if first & 0x10 != 0 { length = 4 }
        else { throw RemuxError.invalidEBML("Invalid element ID leading byte: \(first)") }

        guard offset + length <= buffer.count else {
            throw RemuxError.unexpectedEnd
        }

        var value: UInt32 = 0
        for i in 0..<length {
            value = (value << 8) | UInt32(buffer[offset + i])
        }
        offset += length
        return value
    }

    private func readElementSize() throws -> Int {
        return Int(try readVINT())
    }

    private func readVINT() throws -> UInt64 {
        guard offset < buffer.count else {
            throw RemuxError.unexpectedEnd
        }

        let first = buffer[offset]
        let length: Int

        if first & 0x80 != 0 { length = 1 }
        else if first & 0x40 != 0 { length = 2 }
        else if first & 0x20 != 0 { length = 3 }
        else if first & 0x10 != 0 { length = 4 }
        else if first & 0x08 != 0 { length = 5 }
        else if first & 0x04 != 0 { length = 6 }
        else if first & 0x02 != 0 { length = 7 }
        else if first & 0x01 != 0 { length = 8 }
        else { throw RemuxError.invalidEBML("Invalid VINT leading byte: \(first)") }

        guard offset + length <= buffer.count else {
            throw RemuxError.unexpectedEnd
        }

        let mask: UInt8 = 0xFF >> length
        var value: UInt64 = UInt64(first & mask)

        for i in 1..<length {
            value = (value << 8) | UInt64(buffer[offset + i])
        }
        offset += length

        let maxValue: UInt64 = (1 << (7 * length)) - 1
        if value == maxValue {
            return UInt64(Int.max)
        }

        return value
    }

    private func readUInt(size: Int) throws -> UInt64 {
        guard offset + size <= buffer.count else {
            throw RemuxError.unexpectedEnd
        }
        var value: UInt64 = 0
        for i in 0..<size {
            value = (value << 8) | UInt64(buffer[offset + i])
        }
        offset += size
        return value
    }
}
