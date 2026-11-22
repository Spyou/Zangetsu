import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Adds source-provided HTTP headers to AVPlayer requests without replacing
/// AVPlayer. HLS playlist references are rewritten to this loader's custom URL
/// schemes so segments and keys receive the same headers as the playlist.
final class TVAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate,
  URLSessionDataDelegate
{

  private static let schemePrefix = "AniAura-"
  private static let playlistType = "com.apple.mpegurl"

  private final class PendingRequest {
    let loadingRequest: AVAssetResourceLoadingRequest
    let task: URLSessionDataTask
    let upstreamURL: URL
    let requestedRange: (start: Int64, length: Int64?)?
    var isPlaylist: Bool
    var bytesToDiscard: Int64 = 0
    var bytesDelivered: Int64 = 0
    var bufferedPlaylist = Data()

    init(
      loadingRequest: AVAssetResourceLoadingRequest,
      task: URLSessionDataTask,
      upstreamURL: URL,
      requestedRange: (start: Int64, length: Int64?)?,
      isPlaylist: Bool
    ) {
      self.loadingRequest = loadingRequest
      self.task = task
      self.upstreamURL = upstreamURL
      self.requestedRange = requestedRange
      self.isPlaylist = isPlaylist
    }
  }

  let delegateQueue = DispatchQueue(label: "app.AniAura.tv-asset-resource-loader")

  private let headers: [String: String]
  private let rootURL: URL
  private let mimeTypeHint: String?
  private let stateQueue = DispatchQueue(label: "app.AniAura.tv-asset-resource-loader-state")
  private var pendingRequests: [Int: PendingRequest] = [:]
  private var requestIDs: [ObjectIdentifier: Int] = [:]
  private var session: URLSession!

  init(headers: [String: String], rootURL: URL, mimeTypeHint: String?) {
    self.headers = headers
    self.rootURL = rootURL
    self.mimeTypeHint = mimeTypeHint
    super.init()

    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let callbackQueue = OperationQueue()
    callbackQueue.maxConcurrentOperationCount = 1
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: callbackQueue)
  }

  deinit {
    session.invalidateAndCancel()
  }

  static func requiresResourceLoader(headers: [String: String]) -> Bool {
    headers.keys.contains { $0.caseInsensitiveCompare("User-Agent") != .orderedSame }
  }

  static func assetURL(for upstreamURL: URL) -> URL? {
    guard let scheme = upstreamURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      var components = URLComponents(url: upstreamURL, resolvingAgainstBaseURL: false)
    else { return nil }
    components.scheme = schemePrefix + scheme
    return components.url
  }

  static func upstreamURL(for assetURL: URL) -> URL? {
    guard let scheme = assetURL.scheme?.lowercased(),
      scheme.hasPrefix(schemePrefix),
      var components = URLComponents(url: assetURL, resolvingAgainstBaseURL: false)
    else { return nil }
    let upstreamScheme = String(scheme.dropFirst(schemePrefix.count))
    guard upstreamScheme == "http" || upstreamScheme == "https" else { return nil }
    components.scheme = upstreamScheme
    return components.url
  }

  static func isHLS(url: URL, mimeType: String?) -> Bool {
    if url.pathExtension.lowercased() == "m3u8" { return true }
    let type = mimeType?.lowercased() ?? ""
    return type.contains("mpegurl") || type.contains("m3u8")
  }

  static func shouldOverrideMIMEType(_ mimeType: String?) -> Bool {
    let type = mimeType?.lowercased() ?? ""
    return type.contains("mpegurl") || type.hasPrefix("video/mp4")
  }

  static func isHLSResource(
    url: URL,
    rootURL: URL,
    mimeTypeHint: String?,
    responseMimeType: String? = nil
  ) -> Bool {
    if isHLS(url: url, mimeType: responseMimeType) { return true }
    return url.absoluteString == rootURL.absoluteString && isHLS(url: url, mimeType: mimeTypeHint)
  }

  static func apply(headers: [String: String], to request: inout URLRequest) {
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
  }

  static func rewriteHLSPlaylist(_ playlist: String, baseURL: URL) -> String {
    playlist.components(separatedBy: .newlines).map { line in
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
        return rewriteURIAttributes(in: line, baseURL: baseURL)
      }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty,
        let rewritten = wrappedReference(trimmed, baseURL: baseURL)
      else { return line }

      let leading = line.prefix { $0 == " " || $0 == "\t" }
      let trailing = line.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
      return String(leading) + rewritten + String(trailing)
    }.joined(separator: "\n")
  }

  private static func rewriteURIAttributes(in line: String, baseURL: URL) -> String {
    guard let expression = try? NSRegularExpression(pattern: #"URI="([^"]+)""#) else {
      return line
    }
    var rewritten = line
    let matches = expression.matches(
      in: line,
      range: NSRange(line.startIndex..., in: line)
    )
    for match in matches.reversed() {
      guard let valueRange = Range(match.range(at: 1), in: rewritten) else { continue }
      let value = String(rewritten[valueRange])
      guard let wrapped = wrappedReference(value, baseURL: baseURL) else { continue }
      rewritten.replaceSubrange(valueRange, with: wrapped)
    }
    return rewritten
  }

  private static func wrappedReference(_ value: String, baseURL: URL) -> String? {
    guard let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL,
      let wrapped = assetURL(for: resolved)
    else { return nil }
    return wrapped.absoluteString
  }

  func invalidate() {
    stateQueue.async { [weak self] in
      guard let self else { return }
      for pending in self.pendingRequests.values {
        if !pending.loadingRequest.isCancelled {
          pending.loadingRequest.finishLoading(with: URLError(.cancelled))
        }
        pending.task.cancel()
      }
      self.pendingRequests.removeAll()
      self.requestIDs.removeAll()
      self.session.invalidateAndCancel()
    }
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard let assetURL = loadingRequest.request.url,
      let sourceURL = Self.upstreamURL(for: assetURL)
    else { return false }

    var request = loadingRequest.request
    request.url = sourceURL
    Self.apply(headers: headers, to: &request)
    let isPlaylistRequest = Self.isHLSResource(
      url: sourceURL,
      rootURL: rootURL,
      mimeTypeHint: mimeTypeHint
    )
    let requestedRange =
      isPlaylistRequest ? nil : Self.requestedRange(for: loadingRequest.dataRequest)
    request.setValue(nil, forHTTPHeaderField: "Range")
    if let requestedRange {
      if requestedRange.start > 0 {
        let end = requestedRange.length.map { requestedRange.start + $0 - 1 }
        let value =
          end.map { "bytes=\(requestedRange.start)-\($0)" }
          ?? "bytes=\(requestedRange.start)-"
        request.setValue(value, forHTTPHeaderField: "Range")
      }
    }
    if isPlaylistRequest {
      request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    let task = session.dataTask(with: request)
    let pending = PendingRequest(
      loadingRequest: loadingRequest,
      task: task,
      upstreamURL: sourceURL,
      requestedRange: requestedRange,
      isPlaylist: isPlaylistRequest
    )
    stateQueue.async { [weak self] in
      guard let self else { return }
      self.pendingRequests[task.taskIdentifier] = pending
      self.requestIDs[ObjectIdentifier(loadingRequest)] = task.taskIdentifier
      task.resume()
    }
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    stateQueue.async { [weak self] in
      guard let self,
        let taskID = self.requestIDs.removeValue(forKey: ObjectIdentifier(loadingRequest))
      else { return }
      if let pending = self.pendingRequests.removeValue(forKey: taskID) {
        pending.task.cancel()
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    stateQueue.async { [weak self] in
      guard let self, let pending = self.pendingRequests[dataTask.taskIdentifier] else {
        completionHandler(.cancel)
        return
      }
      guard !pending.loadingRequest.isCancelled else {
        self.cancel(dataTask.taskIdentifier)
        completionHandler(.cancel)
        return
      }

      if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
        self.finish(
          dataTask.taskIdentifier,
          error: NSError(
            domain: NSURLErrorDomain,
            code: http.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "Stream server returned HTTP \(http.statusCode)"]
          )
        )
        completionHandler(.cancel)
        return
      }

      let responseIgnoredRange = (response as? HTTPURLResponse)?.statusCode != 206
      let responseURL = response.url ?? pending.upstreamURL
      pending.isPlaylist =
        pending.isPlaylist
        || Self.isHLSResource(
          url: responseURL,
          rootURL: rootURL,
          mimeTypeHint: mimeTypeHint,
          responseMimeType: response.mimeType
        )
      if responseIgnoredRange, pending.requestedRange != nil {
        pending.bytesToDiscard = pending.requestedRange?.start ?? 0
      }
      self.fillContentInformation(
        pending.loadingRequest.contentInformationRequest,
        response: response,
        url: pending.upstreamURL,
        isPlaylist: pending.isPlaylist,
        canServeRequestedRange: pending.requestedRange != nil
      )

      if pending.loadingRequest.dataRequest == nil {
        completionHandler(.cancel)
        self.finish(dataTask.taskIdentifier)
        return
      }
      completionHandler(.allow)
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    stateQueue.async { [weak self] in
      guard let self, let pending = self.pendingRequests[dataTask.taskIdentifier] else { return }
      guard !pending.loadingRequest.isCancelled else {
        self.cancel(dataTask.taskIdentifier)
        return
      }
      if pending.isPlaylist {
        pending.bufferedPlaylist.append(data)
      } else {
        self.respond(data, to: pending, taskID: dataTask.taskIdentifier)
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    stateQueue.async { [weak self] in
      guard let self, let pending = self.pendingRequests[task.taskIdentifier] else { return }
      guard !pending.loadingRequest.isCancelled else {
        self.cancel(task.taskIdentifier)
        return
      }
      if let error {
        self.finish(task.taskIdentifier, error: error)
        return
      }
      if pending.isPlaylist {
        guard let body = String(data: pending.bufferedPlaylist, encoding: .utf8) else {
          self.finish(
            task.taskIdentifier,
            error: URLError(.cannotDecodeContentData)
          )
          return
        }
        let baseURL = (task.response?.url) ?? pending.upstreamURL
        let rewritten = Self.rewriteHLSPlaylist(body, baseURL: baseURL)
        let data = Data(rewritten.utf8)
        pending.loadingRequest.contentInformationRequest?.contentLength = Int64(data.count)
        guard !pending.loadingRequest.isCancelled else {
          self.cancel(task.taskIdentifier)
          return
        }
        pending.loadingRequest.dataRequest?.respond(with: data)
      }
      self.finish(task.taskIdentifier)
    }
  }

  private static func requestedRange(
    for dataRequest: AVAssetResourceLoadingDataRequest?
  ) -> (start: Int64, length: Int64?)? {
    guard let dataRequest else { return nil }
    let start = max(0, max(dataRequest.currentOffset, dataRequest.requestedOffset))
    if dataRequest.requestsAllDataToEndOfResource {
      return (start, nil)
    }
    let remaining = Int64(dataRequest.requestedLength) - (start - dataRequest.requestedOffset)
    return remaining > 0 ? (start, remaining) : nil
  }

  private func respond(_ data: Data, to pending: PendingRequest, taskID: Int) {
    guard !pending.loadingRequest.isCancelled else {
      cancel(taskID)
      return
    }
    guard let dataRequest = pending.loadingRequest.dataRequest else { return }
    var chunk = data
    if pending.bytesToDiscard > 0 {
      let count = min(Int64(chunk.count), pending.bytesToDiscard)
      chunk.removeFirst(Int(count))
      pending.bytesToDiscard -= count
    }
    guard !chunk.isEmpty else { return }

    if let length = pending.requestedRange?.length {
      let remaining = length - pending.bytesDelivered
      guard remaining > 0 else { return }
      if Int64(chunk.count) > remaining {
        chunk = Data(chunk.prefix(Int(remaining)))
      }
    }
    dataRequest.respond(with: chunk)
    pending.bytesDelivered += Int64(chunk.count)
    if let length = pending.requestedRange?.length, pending.bytesDelivered >= length {
      pending.task.cancel()
      finish(taskID)
    }
  }

  private func fillContentInformation(
    _ information: AVAssetResourceLoadingContentInformationRequest?,
    response: URLResponse,
    url: URL,
    isPlaylist: Bool,
    canServeRequestedRange: Bool
  ) {
    guard let information else { return }
    if isPlaylist {
      information.contentType = Self.playlistType
    } else if let mimeType = response.mimeType
      ?? (url.absoluteString == rootURL.absoluteString ? mimeTypeHint : nil),
      let type = UTType(mimeType: mimeType)
    {
      information.contentType = type.identifier
    }

    if let http = response as? HTTPURLResponse {
      let range = http.value(forHTTPHeaderField: "Content-Range")
      if let total = Self.totalLength(fromContentRange: range) {
        information.contentLength = total
      } else if response.expectedContentLength >= 0 {
        information.contentLength = response.expectedContentLength
      }
      information.isByteRangeAccessSupported =
        http.statusCode == 206
        || canServeRequestedRange
        || http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
    } else if response.expectedContentLength >= 0 {
      information.contentLength = response.expectedContentLength
    }
  }

  private static func totalLength(fromContentRange value: String?) -> Int64? {
    guard let value, let total = value.split(separator: "/").last, total != "*" else {
      return nil
    }
    return Int64(total)
  }

  private func finish(_ taskID: Int, error: Error? = nil) {
    guard let pending = pendingRequests.removeValue(forKey: taskID) else { return }
    requestIDs.removeValue(forKey: ObjectIdentifier(pending.loadingRequest))
    guard !pending.loadingRequest.isCancelled else {
      pending.task.cancel()
      return
    }
    if let error {
      pending.loadingRequest.finishLoading(with: error)
    } else {
      pending.loadingRequest.finishLoading()
    }
  }

  private func cancel(_ taskID: Int) {
    guard let pending = pendingRequests.removeValue(forKey: taskID) else { return }
    requestIDs.removeValue(forKey: ObjectIdentifier(pending.loadingRequest))
    pending.task.cancel()
  }
}
