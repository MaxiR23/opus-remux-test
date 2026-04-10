import XCTest
import AVFoundation
import OpusRemuxLib

class ResourceLoaderTests: XCTestCase {

    var cafData: Data!

    override func setUp() {
        super.setUp()
        cafData = buildCAF()
        XCTAssertNotNil(cafData, "CAF generation failed")
        XCTAssertTrue(cafData.prefix(4) == "caff".data(using: .ascii), "Invalid CAF magic")
    }

    // MARK: - Direct file playback

    func testCAFDirectFileURL() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test.caf")
        try cafData.write(to: tmp)

        let asset = AVURLAsset(url: tmp)
        let exp = expectation(description: "direct-load")

        asset.loadValuesAsynchronously(forKeys: ["playable", "duration", "tracks"]) {
            var err: NSError?
            let status = asset.statusOfValue(forKey: "playable", error: &err)
            XCTAssertEqual(status, .loaded, "status: \(err?.localizedDescription ?? "?")")
            XCTAssertTrue(asset.isPlayable, "not playable via file://")
            XCTAssertGreaterThan(asset.tracks.count, 0, "no tracks")
            let dur = CMTimeGetSeconds(asset.duration)
            print("[TEST] Direct: playable=true duration=\(String(format: "%.1f", dur))s")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 10)
    }

    // MARK: - Progressive loader tests

    func testProgressive100pct() { runProgressive(start: 100, label: "100pct") }
    func testProgressive50pct()  { runProgressive(start: 50,  label: "50pct")  }
    func testProgressive25pct()  { runProgressive(start: 25,  label: "25pct")  }
    func testProgressive10pct()  { runProgressive(start: 10,  label: "10pct")  }
    func testProgressive0pct()   { runProgressive(start: 0,   label: "0pct")   }

    // MARK: - Progressive test runner (AVPlayer + AVPlayerItem, like TrackPlayer)

    private func runProgressive(start: Int, label: String) {
        let url = URL(string: "xcaf://track/\(label).caf")!
        let asset = AVURLAsset(url: url)
        let loader = CAFProgressiveLoader(cafData: cafData, startPercent: start)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)

        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)

        let exp = expectation(description: "progressive-\(label)")

        let observer = playerItem.observe(\.status, options: [.new]) { item, _ in
            switch item.status {
            case .readyToPlay:
                let dur = CMTimeGetSeconds(item.duration)
                let durStr = dur.isFinite ? String(format: "%.1f", dur) : "unknown"
                print("[TEST] \(label): readyToPlay duration=\(durStr)s bytesServed=\(loader.bytesServed)")
                exp.fulfill()
            case .failed:
                let err = item.error?.localizedDescription ?? "unknown"
                print("[TEST] \(label): FAILED error=\(err)")
                XCTFail("\(label) failed: \(err)")
                exp.fulfill()
            case .unknown:
                break
            @unknown default:
                break
            }
        }

        player.play()

        wait(for: [exp], timeout: 20)

        let dur = CMTimeGetSeconds(playerItem.duration)
        XCTAssertEqual(playerItem.status, .readyToPlay, "\(label) not readyToPlay")
        XCTAssertTrue(dur.isFinite && dur > 0, "\(label) duration=\(dur)")

        observer.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
        _ = loader
    }

    // MARK: - Build CAF test data

    private func buildCAF() -> Data? {
        #if os(macOS)
        if let webm = generateWithFFmpeg() {
            return remuxWebMToCAF(webm)
        }
        #endif

        if let data = EmbeddedTestData.cafData {
            print("[TEST] Using embedded CAF data: \(data.count) bytes")
            return data
        }

        XCTFail("No test data available")
        return nil
    }

    private func remuxWebMToCAF(_ webm: Data) -> Data? {
        guard let demux = try? WebMDemuxer(data: webm).demux() else { return nil }
        let caf = CAFMuxer.mux(opusHead: demux.opusHead, packets: demux.packets, channels: demux.channels)
        print("[TEST] Built CAF: \(caf.count) bytes, \(demux.packets.count) packets, \(demux.channels)ch")
        return caf
    }

    #if os(macOS)
    private func generateWithFFmpeg() -> Data? {
        let tmp = NSTemporaryDirectory() + "sine.webm"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["ffmpeg", "-y",
                       "-f", "lavfi", "-i", "sine=frequency=440:duration=5",
                       "-ac", "2",
                       "-c:a", "libopus", "-b:a", "160k",
                       "-vbr", "on", "-frame_duration", "20",
                       "-f", "webm", tmp]
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: tmp))
    }
    #endif
}

// MARK: - Embedded test data fallback

enum EmbeddedTestData {
    static var cafData: Data? {
        guard let b64 = _base64, !b64.isEmpty else { return nil }
        return Data(base64Encoded: b64)
    }
    static let _base64: String? = nil
}

// MARK: - CAFProgressiveLoader

class CAFProgressiveLoader: NSObject, AVAssetResourceLoaderDelegate {

    let cafData: Data
    private(set) var bytesAvailable: Int
    private(set) var bytesServed: Int = 0
    let queue = DispatchQueue(label: "caf.progressive.loader")

    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    private var feedTimer: DispatchSourceTimer?

    init(cafData: Data, startPercent: Int, chunkPercent: Int = 5, intervalMs: Int = 50) {
        self.cafData = cafData
        self.bytesAvailable = cafData.count * startPercent / 100
        super.init()
        startFeed(chunkBytes: max(1, cafData.count * chunkPercent / 100), intervalMs: intervalMs)
    }

    private func startFeed(chunkBytes: Int, intervalMs: Int) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(intervalMs),
                   repeating: .milliseconds(intervalMs))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.bytesAvailable < self.cafData.count else {
                self.feedTimer?.cancel()
                return
            }
            self.bytesAvailable = min(self.bytesAvailable + chunkBytes, self.cafData.count)
            self.processRequests()
        }
        t.resume()
        feedTimer = t
    }

    // MARK: - Delegate (FIX CLAVE AQUÍ)

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {

        // ←←← Rellenamos el header SÍNCRONAMENTE (antes de que loadValuesAsynchronously termine)
        if let info = request.contentInformationRequest {
            info.contentType                = AVFileType.caf.rawValue
            info.contentLength              = Int64(cafData.count)
            info.isByteRangeAccessSupported = true
        }

        // Ahora sí mandamos el resto al queue (dataRequest + proceso)
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingRequests.append(request)
            self.processRequests()
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel request: AVAssetResourceLoadingRequest
    ) {
        queue.async { [weak self] in
            self?.pendingRequests.removeAll { $0 === request }
        }
    }

    private func processRequests() {
        var finished: [AVAssetResourceLoadingRequest] = []

        for request in pendingRequests {
            // content info ya se rellenó arriba, solo procesamos dataRequest
            guard let dr = request.dataRequest else {
                request.finishLoading()
                finished.append(request)
                continue
            }

            let requestedEnd    = Int(dr.requestedOffset) + dr.requestedLength
            let currentPosition = Int(dr.currentOffset)

            guard bytesAvailable > currentPosition else { continue }

            let end   = min(bytesAvailable, requestedEnd)
            let chunk = cafData.subdata(in: currentPosition..<end)
            dr.respond(with: chunk)
            bytesServed += chunk.count

            if Int(dr.currentOffset) + chunk.count >= requestedEnd {
                request.finishLoading()
                finished.append(request)
            }
        }

        pendingRequests.removeAll { r in finished.contains { $0 === r } }
    }
}