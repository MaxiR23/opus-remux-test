import Foundation

struct OGGMuxer {

    static func mux(opusHead: Data, packets: [OpusPacket], channels: UInt8) -> Data {
        var out = Data()
        var seq: UInt32 = 0
        let serial: UInt32 = 0x4F505553

        out.append(buildPage(
            payload: buildOpusHead(opusHead: opusHead, channels: channels),
            granule: 0, serial: serial, seq: &seq, headerType: 0x02
        ))
        out.append(buildPage(
            payload: buildOpusTags(),
            granule: 0, serial: serial, seq: &seq, headerType: 0x00
        ))

        var granule: Int64 = 0
        var i = 0
        while i < packets.count {
            var payload = Data()
            var segments: [UInt8] = []

            while i < packets.count && segments.count < 200 {
                let pkt = packets[i]
                var rem = pkt.data.count
                while rem > 0 && segments.count < 255 {
                    let s = min(rem, 255)
                    segments.append(UInt8(s))
                    rem -= s
                }
                if segments.last == 255 { segments.append(0) }
                payload.append(pkt.data)
                granule += 960
                i += 1
            }

            let isLast = i >= packets.count
            out.append(buildPage(
                payload: payload,
                segments: segments,
                granule: granule,
                serial: serial,
                seq: &seq,
                headerType: isLast ? 0x04 : 0x00
            ))
        }

        return out
    }

    private static func buildOpusHead(opusHead: Data, channels: UInt8) -> Data {
        if opusHead.count >= 19, opusHead.prefix(8) == Data("OpusHead".utf8) {
            return opusHead
        }
        var d = Data()
        d.append(contentsOf: "OpusHead".utf8)
        d.append(0x01)
        d.append(channels)
        d.appendLE(UInt16(312))
        d.appendLE(UInt32(48000))
        d.appendLE(UInt16(0))
        d.append(0x00)
        return d
    }

    private static func buildOpusTags() -> Data {
        var d = Data()
        d.append(contentsOf: "OpusTags".utf8)
        let vendor = "remux"
        d.appendLE(UInt32(vendor.utf8.count))
        d.append(contentsOf: vendor.utf8)
        d.appendLE(UInt32(0))
        return d
    }

    private static func buildPage(
        payload: Data,
        granule: Int64,
        serial: UInt32,
        seq: inout UInt32,
        headerType: UInt8
    ) -> Data {
        var segments: [UInt8] = []
        var rem = payload.count
        while rem > 0 {
            let s = min(rem, 255)
            segments.append(UInt8(s))
            rem -= s
        }
        if segments.last == 255 { segments.append(0) }
        return buildPage(payload: payload, segments: segments,
                         granule: granule, serial: serial,
                         seq: &seq, headerType: headerType)
    }

    private static func buildPage(
        payload: Data,
        segments: [UInt8],
        granule: Int64,
        serial: UInt32,
        seq: inout UInt32,
        headerType: UInt8
    ) -> Data {
        var header = Data()
        header.append(contentsOf: "OggS".utf8)
        header.append(0x00)
        header.append(headerType)
        header.appendLE(UInt64(bitPattern: granule))
        header.appendLE(serial)
        header.appendLE(seq)
        seq += 1
        header.appendLE(UInt32(0))
        header.append(UInt8(segments.count))
        header.append(contentsOf: segments)

        var page = header
        page.append(payload)

        let crc = crc32ogg(page)
        page[22] = UInt8((crc >>  0) & 0xFF)
        page[23] = UInt8((crc >>  8) & 0xFF)
        page[24] = UInt8((crc >> 16) & 0xFF)
        page[25] = UInt8((crc >> 24) & 0xFF)

        return page
    }

    private static func crc32ogg(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            let idx = Int((crc >> 24) ^ UInt32(byte)) & 0xFF
            crc = (crc << 8) ^ table[idx]
        }
        return crc
    }

    private static let table: [UInt32] = {
        let poly: UInt32 = 0x04C11DB7
        return (0..<256).map { i -> UInt32 in
            var crc = UInt32(i) << 24
            for _ in 0..<8 { crc = (crc & 0x80000000) != 0 ? (crc << 1) ^ poly : crc << 1 }
            return crc
        }
    }()
}

private extension Data {
    mutating func appendLE(_ v: UInt16) { var x = v.littleEndian; append(Data(bytes: &x, count: 2)) }
    mutating func appendLE(_ v: UInt32) { var x = v.littleEndian; append(Data(bytes: &x, count: 4)) }
    mutating func appendLE(_ v: UInt64) { var x = v.littleEndian; append(Data(bytes: &x, count: 8)) }
}
