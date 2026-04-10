import Foundation

enum RemuxError: LocalizedError {
    case invalidEBML(String)
    case noOpusTrack
    case unexpectedEnd
    case invalidURL(String)
    case emptyResponse
    case invalidRange
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .invalidEBML(let detail):
            return "Invalid EBML: \(detail)"
        case .noOpusTrack:
            return "No Opus audio track found in WebM"
        case .unexpectedEnd:
            return "Unexpected end of data while parsing"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .emptyResponse:
            return "Server returned empty response"
        case .invalidRange:
            return "Requested byte range out of bounds"
        case .notPrepared:
            return "Stream not prepared yet"
        }
    }
}
