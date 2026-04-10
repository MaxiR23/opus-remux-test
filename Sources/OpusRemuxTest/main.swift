import Foundation
import AVFoundation

// MARK: - Test runner

func log(_ msg: String) {
    print("[TEST] \(msg)")
}

func logError(_ msg: String) {
    print("[FAIL] \(msg)")
}

func logPass(_ msg: String) {
    print("[PASS] \(msg)")
}

func measure<T>(_ label: String, _ block: () throws -> T) rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = try block()
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    log("\(label): \(String(format: "%.1f", elapsed))ms")
    return result
}

// MARK: - Download

func downloadSync(url: URL) -> Data? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Data?

    let task = URLSession.shared.dataTask(with: url) { data, response, error in
        if let error = error {
            logError("Download failed: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse {
            log("HTTP status: \(http.statusCode)")
            log("Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "unknown")")
        }
        result = data
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()
    return result
}

// MARK: - Validate with afinfo

func runAfinfo(path: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
    process.arguments = [path]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus == 0 {
            logPass("afinfo accepted the CAF file")
            print("--- afinfo output ---")
            print(output)
            print("--- end afinfo ---")
        } else {
            logError("afinfo rejected the CAF file (exit code \(process.terminationStatus))")
            print(output)
        }
    } catch {
        logError("Could not run afinfo: \(error)")
    }
}

// MARK: - Validate with AVFoundation

func validateAVFoundation(path: String) {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)

    let semaphore = DispatchSemaphore(value: 0)

    asset.loadValuesAsynchronously(forKeys: ["playable", "duration", "tracks"]) {
        var error: NSError?

        let playableStatus = asset.statusOfValue(forKey: "playable", error: &error)
        if playableStatus == .loaded {
            logPass("AVURLAsset loaded successfully")
            log("  playable: \(asset.isPlayable)")
            log("  duration: \(CMTimeGetSeconds(asset.duration))s")
            log("  tracks: \(asset.tracks.count)")

            for track in asset.tracks {
                log("  track: mediaType=\(track.mediaType.rawValue) codec=\(track.mediaType)")
            }
        } else {
            logError("AVURLAsset failed to load: \(error?.localizedDescription ?? "status=\(playableStatus.rawValue)")")
        }

        semaphore.signal()
    }

    _ = semaphore.wait(timeout: .now() + 10)
}

// MARK: - Hex dump helper

func hexDump(_ data: Data, maxBytes: Int = 64) -> String {
    let bytes = data.prefix(maxBytes)
    let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    let suffix = data.count > maxBytes ? " ... (\(data.count) bytes total)" : ""
    return hex + suffix
}

// MARK: - Main

func main() {
    log("=== Opus Remux Test ===")
    log("")

    // Get URL from args or use default test file
    let args = CommandLine.arguments
    let urlString: String

    if args.count > 1 {
        urlString = args[1]
        log("Using provided URL: \(urlString)")
    } else {
        // Generate a test WebM with ffmpeg if no URL provided
        log("No URL provided, generating test WebM with ffmpeg...")
        let testPath = "/tmp/test_opus.webm"

        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        ffmpeg.arguments = [
            "ffmpeg", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=5",
            "-c:a", "libopus", "-b:a", "160k",
            "-f", "webm",
            testPath
        ]
        ffmpeg.standardOutput = FileHandle.nullDevice
        ffmpeg.standardError = FileHandle.nullDevice

        do {
            try ffmpeg.run()
            ffmpeg.waitUntilExit()

            if ffmpeg.terminationStatus == 0, FileManager.default.fileExists(atPath: testPath) {
                let data = try Data(contentsOf: URL(fileURLWithPath: testPath))
                log("Generated test WebM: \(data.count) bytes")
                runTest(with: data)
                return
            } else {
                logError("ffmpeg failed, trying download fallback...")
            }
        } catch {
            logError("Could not run ffmpeg: \(error), trying download fallback...")
        }

        // Fallback: download a test file
        urlString = "https://upload.wikimedia.org/wikipedia/commons/b/b0/Animaccount_remix.webm"
        log("Falling back to download: \(urlString)")
    }

    guard let url = URL(string: urlString) else {
        logError("Invalid URL: \(urlString)")
        exit(1)
    }

    log("Downloading...")
    guard let data = measure("Download", { downloadSync(url: url) }), !data.isEmpty else {
        logError("Failed to download or empty data")
        exit(1)
    }

    log("Downloaded: \(data.count) bytes")
    runTest(with: data)
}

func runTest(with webmData: Data) {
    log("")
    log("--- Step 1: EBML Header Check ---")
    log("First bytes: \(hexDump(webmData, maxBytes: 32))")

    let magic = webmData.prefix(4)
    if magic == Data([0x1A, 0x45, 0xDF, 0xA3]) {
        logPass("Valid EBML magic bytes")
    } else {
        logError("Not a valid EBML file!")
        exit(1)
    }

    log("")
    log("--- Step 2: Demux WebM ---")
    let demuxResult: DemuxResult
    do {
        demuxResult = try measure("Demux") {
            let demuxer = WebMDemuxer(data: webmData)
            return try demuxer.demux()
        }
        logPass("Demux succeeded")
        log("  OpusHead size: \(demuxResult.opusHead.count) bytes")
        log("  OpusHead hex: \(hexDump(demuxResult.opusHead, maxBytes: 19))")
        log("  Channels: \(demuxResult.channels)")
        log("  Sample rate: \(demuxResult.sampleRate)")
        log("  Total packets: \(demuxResult.packets.count)")

        if demuxResult.packets.isEmpty {
            logError("No packets extracted!")
            exit(1)
        }

        let sizes = demuxResult.packets.map { $0.data.count }
        let avgSize = sizes.reduce(0, +) / sizes.count
        let minSize = sizes.min() ?? 0
        let maxSize = sizes.max() ?? 0
        log("  Packet sizes: min=\(minSize) avg=\(avgSize) max=\(maxSize)")

        let durationMs = demuxResult.packets.last?.timestampMs ?? 0
        log("  Duration (from timestamps): ~\(durationMs)ms (\(String(format: "%.1f", Double(durationMs) / 1000))s)")

        // Validate OpusHead magic
        if demuxResult.opusHead.prefix(8) == "OpusHead".data(using: .ascii) {
            logPass("OpusHead has valid magic")
        } else {
            logError("OpusHead missing 'OpusHead' magic!")
        }

    } catch {
        logError("Demux failed: \(error)")
        exit(1)
    }

    log("")
    log("--- Step 3: Mux to CAF ---")
    let cafData = measure("Mux CAF") {
        CAFMuxer.mux(
            opusHead: demuxResult.opusHead,
            packets: demuxResult.packets,
            channels: demuxResult.channels
        )
    }
    logPass("CAF muxed: \(cafData.count) bytes")
    log("  CAF header: \(hexDump(cafData, maxBytes: 32))")

    // Verify CAF magic
    if cafData.prefix(4) == "caff".data(using: .ascii) {
        logPass("CAF has valid 'caff' magic")
    } else {
        logError("CAF missing 'caff' magic!")
    }

    // Save to disk
    let cafPath = "/tmp/remux_test_output.caf"
    do {
        try cafData.write(to: URL(fileURLWithPath: cafPath))
        logPass("Saved CAF to \(cafPath)")
    } catch {
        logError("Failed to save CAF: \(error)")
        exit(1)
    }

    log("")
    log("--- Step 4: Validate with afinfo ---")
    runAfinfo(path: cafPath)

    log("")
    log("--- Step 5: Validate with AVFoundation ---")
    validateAVFoundation(path: cafPath)

    log("")
    log("--- Step 6: Size comparison ---")
    let webmSize = webmData.count
    let cafSize = cafData.count
    let ratio = Double(cafSize) / Double(webmSize)
    log("  WebM input:  \(webmSize) bytes")
    log("  CAF output:  \(cafSize) bytes")
    log("  Ratio:       \(String(format: "%.2f", ratio))x")

    log("")
    log("=== Test complete ===")
}

main()
RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
