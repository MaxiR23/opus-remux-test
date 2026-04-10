import Foundation
import AVFoundation

// MARK: - Logger

func log(_ msg: String)      { print("[TEST] \(msg)") }
func logError(_ msg: String) { print("[FAIL] \(msg)") }
func logPass(_ msg: String)  { print("[PASS] \(msg)") }

func measure<T>(_ label: String, _ block: () throws -> T) rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = try block()
    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
    log("\(label): \(String(format: "%.1f", ms))ms")
    return result
}

// MARK: - Download

func downloadSync(url: URL) -> Data? {
    let sem = DispatchSemaphore(value: 0)
    var result: Data?
    URLSession.shared.dataTask(with: url) { data, response, error in
        if let e = error { logError("Download: \(e.localizedDescription)") }
        if let h = response as? HTTPURLResponse { log("HTTP \(h.statusCode)") }
        result = data
        sem.signal()
    }.resume()
    sem.wait()
    return result
}

// MARK: - afinfo

func runAfinfo(path: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
    p.arguments = [path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError  = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if p.terminationStatus == 0 { logPass("afinfo OK"); print(out) }
    else                         { logError("afinfo FAIL"); print(out) }
}

// MARK: - ProgressiveLoader

class ProgressiveLoader: NSObject, AVAssetResourceLoaderDelegate {

    let cafData: Data
    private(set) var bytesAvailable: Int
    let queue = DispatchQueue(label: "progressive.loader")   // internal: needed by setDelegate

    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    private var feedTimer: DispatchSourceTimer?

    init(cafData: Data, startPercent: Int, chunkPercent: Int = 5, intervalMs: Int = 80) {
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
            log("  feed: \(self.bytesAvailable)/\(self.cafData.count) (\(self.bytesAvailable * 100 / self.cafData.count)%)")
            self.processRequests()
        }
        t.resume()
        feedTimer = t
    }

    // MARK: Delegate

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

    // MARK: Pump

    private func processRequests() {
        var finished: [AVAssetResourceLoadingRequest] = []

        for request in pendingRequests {
            if let info = request.contentInformationRequest {
                info.contentType                = "com.apple.coreaudio-format"
                info.contentLength              = Int64(cafData.count)
                info.isByteRangeAccessSupported = true
            }

            guard let dr = request.dataRequest else {
                request.finishLoading()
                finished.append(request)
                continue
            }

            let from = Int(dr.currentOffset)
            let to   = Int(dr.requestedOffset) + dr.requestedLength

            if bytesAvailable > from {
                let end = min(bytesAvailable, to)
                dr.respond(with: cafData.subdata(in: from..<end))
            }

            if Int(dr.currentOffset) >= to {
                request.finishLoading()
                finished.append(request)
            }
        }

        pendingRequests.removeAll { r in finished.contains { $0 === r } }
    }
}

// MARK: - Progressive test

func testProgressive(cafData: Data, startPercent: Int, label: String) {
    log("--- \(label): start=\(startPercent)% ---")

    let url   = URL(string: "progressive-caf://\(label).caf")!
    let asset = AVURLAsset(url: url)

    let loader = ProgressiveLoader(cafData: cafData, startPercent: startPercent)
    asset.resourceLoader.setDelegate(loader, queue: loader.queue)

    let sem = DispatchSemaphore(value: 0)

    asset.loadValuesAsynchronously(forKeys: ["playable", "duration", "tracks"]) {
        var err: NSError?
        let status = asset.statusOfValue(forKey: "playable", error: &err)

        if status == .loaded {
            let dur = CMTimeGetSeconds(asset.duration)
            logPass("\(label) → playable=\(asset.isPlayable)  duration=\(String(format: "%.2f", dur))s  tracks=\(asset.tracks.count)")
        } else {
            logError("\(label) → FAILED: \(err?.localizedDescription ?? "status \(status.rawValue)")")
        }
        sem.signal()
    }

    _ = sem.wait(timeout: .now() + 15)
    _ = loader
    log("")
}

// MARK: - Generate CAF

func generateCAF(webmURL: String?) -> Data? {
    let tmpWebM = "/tmp/test_opus.webm"
    var webmData: Data?

    let ff = Process()
    ff.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ff.arguments = ["ffmpeg", "-y",
                    "-f", "lavfi", "-i", "sine=frequency=440:duration=5",
                    "-c:a", "libopus", "-b:a", "160k",
                    "-f", "webm", tmpWebM]
    ff.standardOutput = FileHandle.nullDevice
    ff.standardError  = FileHandle.nullDevice
    if (try? ff.run()) != nil {
        ff.waitUntilExit()
        if ff.terminationStatus == 0 {
            webmData = try? Data(contentsOf: URL(fileURLWithPath: tmpWebM))
        }
    }

    if let d = webmData { log("WebM via ffmpeg: \(d.count) bytes") }

    if webmData == nil {
        let urlStr = webmURL ?? "https://upload.wikimedia.org/wikipedia/commons/b/b0/Animaccount_remix.webm"
        log("Descargando: \(urlStr)")
        guard let u = URL(string: urlStr) else { return nil }
        webmData = measure("Download") { downloadSync(url: u) }
    }

    guard let raw = webmData, !raw.isEmpty else { logError("Sin data WebM"); return nil }
    guard raw.prefix(4) == Data([0x1A, 0x45, 0xDF, 0xA3]) else { logError("No es EBML"); return nil }
    logPass("EBML magic OK")

    let demux: DemuxResult
    do { demux = try measure("Demux") { try WebMDemuxer(data: raw).demux() } }
    catch { logError("Demux: \(error)"); return nil }
    logPass("Demux OK — \(demux.packets.count) paquetes, channels=\(demux.channels)")

    let caf = measure("Mux CAF") {
        CAFMuxer.mux(opusHead: demux.opusHead, packets: demux.packets, channels: demux.channels)
    }
    guard caf.prefix(4) == "caff".data(using: .ascii) else { logError("CAF inválido"); return nil }
    logPass("CAF muxeado: \(caf.count) bytes")

    try? caf.write(to: URL(fileURLWithPath: "/tmp/remux_test_output.caf"))
    logPass("Guardado en /tmp/remux_test_output.caf")
    return caf
}

// MARK: - Main

func main() {
    log("=== Opus Remux + Progressive Streaming Test ===\n")

    let args = CommandLine.arguments

    log("=== Fase 1: WebM → CAF ===")
    guard let cafData = generateCAF(webmURL: args.count > 1 ? args[1] : nil) else {
        logError("No se pudo generar el CAF")
        exit(1)
    }

    log("\n=== Fase 2: afinfo ===")
    runAfinfo(path: "/tmp/remux_test_output.caf")

    log("\n=== Fase 3: Progressive Streaming ===")
    testProgressive(cafData: cafData, startPercent: 100, label: "100pct")
    testProgressive(cafData: cafData, startPercent: 50,  label: "50pct")
    testProgressive(cafData: cafData, startPercent: 10,  label: "10pct")
    testProgressive(cafData: cafData, startPercent: 0,   label: "0pct")

    log("=== Todo listo ===")
}

main()
RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))