// MARK: - Progressive ResourceLoader test (FIXED STREAMING BEHAVIOR)

class ProgressiveLoader: NSObject, AVAssetResourceLoaderDelegate {
    let cafData: Data
    let serveUpTo: Int
    var requestCount = 0
    var bytesServed = 0
    var firstDataRequestSize = 0
    var contentInfoRequested = false

    // keep pending requests alive (do NOT finish them prematurely)
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
        defer { lock.unlock() }

        requestCount += 1

        // Content info
        if let contentRequest = loadingRequest.contentInformationRequest {
            contentInfoRequested = true
            contentRequest.contentType = "com.apple.coreaudio-format"
            contentRequest.contentLength = Int64(cafData.count)
            contentRequest.isByteRangeAccessSupported = true
            log("  [Loader] Content info requested, reporting \(cafData.count) bytes")
        }

        // Track request for incremental serving
        pendingRequests.append(loadingRequest)

        processPendingRequests()

        return true
    }

    private func processPendingRequests() {
        let available = min(serveUpTo, cafData.count)

        var completed: [AVAssetResourceLoadingRequest] = []

        for request in pendingRequests {
            guard let dataRequest = request.dataRequest else {
                request.finishLoading()
                completed.append(request)
                continue
            }

            let offset = Int(dataRequest.requestedOffset)
            let requested = dataRequest.requestedLength

            if firstDataRequestSize == 0 {
                firstDataRequestSize = requested
            }

            // nothing available yet for this offset
            if offset >= available {
                log("  [Loader] Request offset=\(offset) waiting (available=\(available))")
                continue
            }

            let unreadAvailable = available - offset
            let alreadyResponded = dataRequest.currentOffset - Int64(offset)
            let remainingToSend = unreadAvailable - Int(alreadyResponded)

            if remainingToSend <= 0 {
                continue
            }

            let chunkSize = min(remainingToSend, requested)
            let start = offset + Int(alreadyResponded)
            let end = start + chunkSize

            let chunk = cafData.subdata(in: start..<end)
            dataRequest.respond(with: chunk)
            bytesServed += chunk.count

            log("  [Loader] offset=\(offset) requested=\(requested) served=\(chunk.count)")

            // ONLY finish if we fully satisfied requested length
            let totalServed = Int(dataRequest.currentOffset - Int64(offset))
            if totalServed >= requested {
                request.finishLoading()
                completed.append(request)
            }
        }

        // remove completed requests
        pendingRequests.removeAll { req in
            completed.contains(where: { $0 === req })
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.lock()
        defer { lock.unlock() }

        pendingRequests.removeAll { $0 === loadingRequest }
        log("  [Loader] Request cancelled")
    }
}