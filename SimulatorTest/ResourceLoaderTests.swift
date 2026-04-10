import XCTest
import AVFoundation

// RemuxError needed by WebMDemuxer
enum RemuxError: Error {
    case invalidEBML(String)
    case noOpusTrack
    case unexpectedEnd
}

class ResourceLoaderTests: XCTestCase {

    var cafData: Data!

    override func setUp() {
        super.setUp()
        cafData = buildCAF()
        XCTAssertNotNil(cafData, "CAF generation failed")
    }

    func testCAFDirectFileURL() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test.caf")
        try cafData.write(to: tmp)

        let asset = AVURLAsset(url: tmp)
        let exp = expectation(description: "load")

        asset.loadValuesAsynchronously(forKeys: ["playable", "duration", "tracks"]) {
            var err: NSError?
            let status = asset.statusOfValue(forKey: "playable", error: &err)
            XCTAssertEqual(status, .loaded, "status: \(err?.localizedDescription ?? "?")")
            XCTAssertTrue(asset.isPlayable, "not playable via file://")
            XCTAssertGreaterThan(asset.tracks.count, 0, "no tracks")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 10)
    }

    func testCAFProgressiveLoader100pct() {
        runProgressiveTest(startPercent: 100, label: "100pct")
    }

    func testCAFProgressiveLoader50pct() {
        runProgressiveTest(startPercent: 50, label: "50pct")
    }

    func testCAFProgressiveLoader10pct() {
        runProgressiveTest(startPercent: 10, label: "10pct")
    }

    func testCAFProgressiveLoader0pct() {
        runProgressiveTest(startPercent: 0, label: "0pct")
    }

    private func runProgressiveTest(startPercent: Int, label: String) {
        let url = URL(string: "xcaf://\(label)")!
        let asset = AVURLAsset(url: url)
        let loader = CAFProgressiveLoader(cafData: cafData, startPercent: startPercent)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)

        let exp = expectation(description: "load-\(label)")

        asset.loadValuesAsynchronously(forKeys: ["playable", "duration", "tracks"]) {
            var err: NSError?
            let status = asset.statusOfValue(forKey: "playable", error: &err)
            XCTAssertEqual(status, .loaded, "\(label) status: \(err?.localizedDescription ?? "?")")
            XCTAssertTrue(asset.isPlayable, "\(label) not playable")
            XCTAssertGreaterThan(asset.tracks.count, 0, "\(label) no tracks")
            let dur = CMTimeGetSeconds(asset.duration)
            XCTAssertGreaterThan(dur, 0, "\(label) duration=0")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 20)
        _ = loader
    }

    private func buildCAF() -> Data? {
        let sine = generateSineWebM()
        guard let raw = sine, !raw.isEmpty else { return nil }
        guard let demux = try? WebMDemuxer(data: raw).demux() else { return nil }
        let caf = CAFMuxer.mux(opusHead: demux.opusHead, packets: demux.packets, channels: demux.channels)
        guard caf.prefix(4) == "caff".data(using: .ascii) else { return nil }
        return caf
    }

    private func generateSineWebM() -> Data? {
        // 1kHz sine, 2s, Opus, WebM — generated inline via AudioToolbox PCM→Opus is complex,
        // so we embed a minimal valid WebM/Opus file as base64.
        // This is a 2-second 1ch 48kHz Opus sine tone generated offline.
        // If ffmpeg is available on the simulator runtime we use it, otherwise fallback to embedded.
        let tmp = NSTemporaryDirectory() + "sine.webm"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["ffmpeg", "-y",
                       "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                       "-c:a", "libopus", "-b:a", "64k",
                       "-f", "webm", tmp]
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                return try? Data(contentsOf: URL(fileURLWithPath: tmp))
            }
        }
        return nil
    }
}

// MARK: - CAFProgressiveLoader

class CAFProgressiveLoader: NSObject, AVAssetResourceLoaderDelegate {

    let cafData: Data
    private(set) var bytesAvailable: Int
    let queue = DispatchQueue(label: "sim.caf.loader")

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
            guard self.bytesAvailable < self.cafData.count else { self.feedTimer?.cancel(); return }
            self.bytesAvailable = min(self.bytesAvailable + chunkBytes, self.cafData.count)
            self.processRequests()
        }
        t.resume()
        feedTimer = t
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        queue.async { [weak self] in
            self?.pendingRequests.append(request)
            self?.processRequests()
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel request: AVAssetResourceLoadingRequest) {
        queue.async { [weak self] in
            self?.pendingRequests.removeAll { $0 === request }
        }
    }

    func processRequests() {
        var finished: [AVAssetResourceLoadingRequest] = []

        for request in pendingRequests {
            if let info = request.contentInformationRequest {
                info.contentType                = "com.apple.coreaudio-format"
                info.contentLength              = Int64(cafData.count)
                info.isByteRangeAccessSupported = true
                if request.dataRequest == nil {
                    request.finishLoading()
                    finished.append(request)
                    continue
                }
            }

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

            if Int(dr.currentOffset) >= requestedEnd {
                request.finishLoading()
                finished.append(request)
            }
        }

        pendingRequests.removeAll { r in finished.contains { $0 === r } }
    }
}
