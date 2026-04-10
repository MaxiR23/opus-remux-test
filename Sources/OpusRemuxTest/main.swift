import Foundation
import AVFoundation

// MARK: - Logger

func log(_ msg: String) {
    print("[TEST] \(msg)")
}

func logError(_ msg: String) {
    print("[FAIL] \(msg)")
}

func logPass(_ msg: String) {
    print("[PASS] \(msg)")
}

// MARK: - Progressive Loader

class ProgressiveLoader: NSObject, AVAssetResourceLoaderDelegate {

    let cafData: Data
    let serveUpTo: Int

    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    private let lock = NSLock()

    init(cafData: Data, servePercent: Int) {
        self.cafData = cafData
        self.serveUpTo = (cafData.count * servePercent) / 100
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {

        lock.lock()
        pendingRequests.append(loadingRequest)
        lock.unlock()

        processRequests()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.lock()
        pendingRequests.removeAll { $0 === loadingRequest }
        lock.unlock()
    }

    private func processRequests() {
        lock.lock()

        var completed: [AVAssetResourceLoadingRequest] = []

        for request in pendingRequests {

            if let content = request.contentInformationRequest {
                content.contentType = "com.apple.coreaudio-format"
                content.contentLength = Int64(cafData.count)
                content.isByteRangeAccessSupported = true
            }

            guard let dataRequest = request.dataRequest else {
                completed.append(request)
                continue
            }

            let offset = Int(dataRequest.requestedOffset)
            let requested = dataRequest.requestedLength

            let available = min(serveUpTo, cafData.count)
            let remaining = available - offset

            guard remaining > 0 else {
                continue
            }

            let length = min(requested, remaining)
            let range = offset..<(offset + length)

            dataRequest.respond(with: cafData.subdata(in: range))

            let end = offset + length
            let requestEnd = Int(dataRequest.requestedOffset + Int64(dataRequest.requestedLength))

            if end >= requestEnd {
                completed.append(request)
            }
        }

        pendingRequests.removeAll { req in
            if completed.contains(where: { $0 === req }) {
                req.finishLoading()
                return true
            }
            return false
        }

        lock.unlock()
    }
}

// MARK: - Simple Progressive Test

func testProgressive(cafData: Data, percent: Int) {
    log("")
    log("--- Progressive Test \(percent)% ---")

    let url = URL(string: "progressive://test.caf")!
    let asset = AVURLAsset(url: url)

    let loader = ProgressiveLoader(cafData: cafData, servePercent: percent)
    asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "loader"))

    let semaphore = DispatchSemaphore(value: 0)

    asset.loadValuesAsynchronously(forKeys: ["playable"]) {
        var error: NSError?

        let status = asset.statusOfValue(forKey: "playable", error: &error)

        if status == .loaded && asset.isPlayable {
            logPass("Progressive \(percent)% playable")
        } else {
            logError("Progressive \(percent)% failed: \(error?.localizedDescription ?? "status \(status.rawValue)")")
        }

        semaphore.signal()
    }

    _ = semaphore.wait(timeout: .now() + 5)
}

// MARK: - Main Test (SIMPLIFICADO)

func main() {
    log("=== Progressive CAF Test ===")

    // Generamos CAF fake simple (reemplazá por tu mux real)
    let cafData = try! Data(contentsOf: URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff"))

    testProgressive(cafData: cafData, percent: 100)
    testProgressive(cafData: cafData, percent: 50)
    testProgressive(cafData: cafData, percent: 10)

    log("=== Done ===")
}

main()
RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))