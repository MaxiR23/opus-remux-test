import Foundation

public class CAFMuxer {

    public static func mux(opusHead: Data, packets: [OpusPacket], channels: UInt8) -> Data {
        var out = Data()

        // -- 1. File Header --
        out.append(fourCC("caff"))
        out.appendBigEndian(UInt16(1))
        out.appendBigEndian(UInt16(0))

        // -- 2. Audio Description chunk ('desc') --
        out.append(fourCC("desc"))
        out.appendBigEndian(Int64(32))
        out.appendBigEndian(Float64(48000.0))
        out.append(fourCC("opus"))
        out.appendBigEndian(UInt32(0))       // mFormatFlags
        out.appendBigEndian(UInt32(0))       // mBytesPerPacket (variable)
        out.appendBigEndian(UInt32(960))     // mFramesPerPacket (20ms @ 48kHz)
        out.appendBigEndian(UInt32(channels))
        out.appendBigEndian(UInt32(0))       // mBitsPerChannel (compressed)

        // -- 3. Channel Layout chunk ('chan') --
        out.append(fourCC("chan"))
        out.appendBigEndian(Int64(12))
        let layoutTag: UInt32 = channels == 1
            ? ((100 << 16) | 1)
            : ((101 << 16) | 2)
        out.appendBigEndian(layoutTag)
        out.appendBigEndian(UInt32(0))       // mChannelBitmap
        out.appendBigEndian(UInt32(0))       // mNumberChannelDescriptions

        // -- 4. Magic Cookie chunk ('kuki') --
        out.append(fourCC("kuki"))
        out.appendBigEndian(Int64(opusHead.count))
        out.append(opusHead)

        // -- 5. Packet Table chunk ('pakt') --
        let packetTableEntries = encodePacketTable(packets: packets)
        let totalFrames = Int64(packets.count) * 960
        let paktDataSize = 24 + packetTableEntries.count

        out.append(fourCC("pakt"))
        out.appendBigEndian(Int64(paktDataSize))
        out.appendBigEndian(Int64(packets.count))  // mNumberPackets
        out.appendBigEndian(totalFrames)            // mNumberValidFrames
        out.appendBigEndian(Int32(0))               // mPrimingFrames
        out.appendBigEndian(Int32(0))               // mRemainderFrames
        out.append(packetTableEntries)

        // -- 6. Audio Data chunk ('data') --
        let audioDataSize = packets.reduce(0) { $0 + $1.data.count }
        let dataChunkSize = 4 + audioDataSize

        out.append(fourCC("data"))
        out.appendBigEndian(Int64(dataChunkSize))
        out.appendBigEndian(UInt32(0))              // mEditCount
        for packet in packets {
            out.append(packet.data)
        }

        return out
    }

    private static func encodePacketTable(packets: [OpusPacket]) -> Data {
        var data = Data()
        for packet in packets {
            data.append(contentsOf: encodeVarInt(UInt64(packet.data.count)))
        }
        return data
    }

    private static func encodeVarInt(_ value: UInt64) -> [UInt8] {
        if value < 128 {
            return [UInt8(value)]
        }

        var v = value
        var bytes: [UInt8] = []

        bytes.append(UInt8(v & 0x7F))
        v >>= 7

        while v > 0 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }

        return bytes.reversed()
    }

    private static func fourCC(_ s: String) -> Data {
        return s.data(using: .ascii)!
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func appendBigEndian(_ value: Int32) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 4))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 4))
    }

    mutating func appendBigEndian(_ value: Int64) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 8))
    }

    mutating func appendBigEndian(_ value: Float64) {
        var v = value.bitPattern.bigEndian
        append(Data(bytes: &v, count: 8))
    }
}
