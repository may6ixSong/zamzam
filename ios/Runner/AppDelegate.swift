import AVFoundation
import Flutter
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mediaEngine: MediaEngine?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZamZamMediaEngine") {
      mediaEngine = MediaEngine(messenger: registrar.messenger())
    }
  }
}

private struct EngineError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// 재인코딩 없는 자르기·합치기(iOS).
///
/// AVAssetExportSession 의 Passthrough 프리셋은 압축된 샘플을 그대로 복사한다.
/// 자르기는 편집 목록(edit list)으로 시작 시각을 맞추므로 키프레임에 맞출 필요가 없다.
final class MediaEngine: NSObject, PHPickerViewControllerDelegate {
  private let channel: FlutterMethodChannel
  private var pendingPick: FlutterResult?
  private var session: AVAssetExportSession?
  private var progressTimer: Timer?
  private let frameQueue = DispatchQueue(label: "zamzam.frame")
  private var frameGenerator: AVAssetImageGenerator?
  private var framePath: String?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "zamzam/media", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pickVideos":
      pick(multiple: args["multiple"] as? Bool ?? false, result)
    case "probe":
      let path = args["uri"] as? String ?? ""
      background(result) { try self.probe(path: path) }
    case "thumbnails":
      let path = args["uri"] as? String ?? ""
      let count = (args["count"] as? NSNumber)?.intValue ?? 1
      let height = (args["height"] as? NSNumber)?.intValue ?? 120
      background(result) { self.thumbnails(path: path, count: count, height: height) }
    case "frameAt":
      let path = args["uri"] as? String ?? ""
      let us = (args["us"] as? NSNumber)?.int64Value ?? 0
      let height = (args["height"] as? NSNumber)?.intValue ?? 360
      let exact = args["exact"] as? Bool ?? false
      frameQueue.async {
        let data = self.frameAt(path: path, us: us, height: height, exact: exact)
        DispatchQueue.main.async { result(data.map { FlutterStandardTypedData(bytes: $0) }) }
      }
    case "trim":
      let path = args["uri"] as? String ?? ""
      let start = (args["startUs"] as? NSNumber)?.int64Value ?? 0
      let end = (args["endUs"] as? NSNumber)?.int64Value ?? 0
      let rotateCcw = (args["rotateCcw"] as? NSNumber)?.intValue ?? 0
      trim(path: path, startUs: start, endUs: end, rotateCcw: rotateCcw, result)
    case "merge":
      merge(paths: args["uris"] as? [String] ?? [], result)
    case "cancel":
      session?.cancelExport()
      result(nil)
    case "open":
      if let url = URL(string: "photos-redirect://") {
        UIApplication.shared.open(url)
      }
      result(nil)
    case "saveLocation":
      result("사진 앱 · 최근 항목")
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - pick

  private func pick(multiple: Bool, _ result: @escaping FlutterResult) {
    pendingPick?([String]())
    pendingPick = result
    var config = PHPickerConfiguration()
    config.filter = .videos
    config.selectionLimit = multiple ? 30 : 1
    // 원본 그대로(HEVC→H.264 같은 변환 없이) 받는다.
    config.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    guard let top = topViewController() else {
      pendingPick = nil
      result(FlutterError(code: "FAILED", message: "화면을 찾지 못했어요", details: nil))
      return
    }
    top.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = pendingPick else { return }
    pendingPick = nil
    if results.isEmpty {
      result([String]())
      return
    }
    let group = DispatchGroup()
    let lock = NSLock()
    var paths = [String?](repeating: nil, count: results.count)
    for (i, item) in results.enumerated() {
      let provider = item.itemProvider
      let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .movie) == true }
        ?? UTType.movie.identifier
      group.enter()
      provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
        defer { group.leave() }
        guard let url = url else { return }
        // 콜백이 끝나면 지워지는 파일이라 앱 임시 폴더로 옮겨 둔다.
        let dir = FileManager.default.temporaryDirectory
          .appendingPathComponent("picked", isDirectory: true)
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        do {
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          try FileManager.default.copyItem(at: url, to: dest)
          lock.lock()
          paths[i] = dest.path
          lock.unlock()
        } catch {}
      }
    }
    group.notify(queue: .main) {
      result(paths.compactMap { $0 })
    }
  }

  // MARK: - probe

  private func probe(path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    guard let video = asset.tracks(withMediaType: .video).first else {
      throw EngineError(message: "영상 트랙이 없는 파일이에요")
    }
    let size = video.naturalSize
    let t = video.preferredTransform
    let angle = Int((atan2(Double(t.b), Double(t.a)) * 180 / .pi).rounded())
    let rotation = (angle + 360) % 360

    var info: [String: Any] = [
      "uri": path,
      "name": url.lastPathComponent,
      "size": fileSize(url),
      "durationUs": microseconds(asset.duration),
      "width": Int(abs(size.width)),
      "height": Int(abs(size.height)),
      "rotation": rotation,
      "videoMime": NSNull(),
      "videoSig": NSNull(),
      "fps": Double(video.nominalFrameRate > 0 ? video.nominalFrameRate : 30),
      "audioMime": NSNull(),
      "sampleRate": NSNull(),
      "channels": NSNull(),
      "keyframesUs": [Int64](),
      "exactCut": true,
    ]
    if let desc = video.formatDescriptions.first {
      let fd = desc as! CMFormatDescription
      info["videoMime"] = videoMime(CMFormatDescriptionGetMediaSubType(fd))
    }
    if let audio = asset.tracks(withMediaType: .audio).first, let desc = audio.formatDescriptions.first {
      let fd = desc as! CMFormatDescription
      if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
        info["audioMime"] = audioMime(asbd.mFormatID)
        info["sampleRate"] = Int(asbd.mSampleRate)
        info["channels"] = Int(asbd.mChannelsPerFrame)
      }
    }
    return info
  }

  private func videoMime(_ codec: FourCharCode) -> String {
    switch codec {
    case kCMVideoCodecType_HEVC: return "video/hevc"
    case kCMVideoCodecType_H264: return "video/avc"
    default: return "video/" + fourCC(codec).lowercased()
    }
  }

  private func audioMime(_ format: AudioFormatID) -> String {
    switch format {
    case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "audio/mp4a-latm"
    case kAudioFormatLinearPCM: return "audio/raw"
    default: return "audio/" + fourCC(format).lowercased()
    }
  }

  private func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "unknown"
  }

  private func thumbnails(path: String, count: Int, height: Int) -> [FlutterStandardTypedData] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: height * 3, height: height)
    let duration = asset.duration.seconds
    var out: [FlutterStandardTypedData] = []
    for i in 0..<count {
      let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
      guard let cg = try? gen.copyCGImage(at: t, actualTime: nil),
        let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.75)
      else { continue }
      out.append(FlutterStandardTypedData(bytes: data))
    }
    return out
  }

  /// [us] 시점 화면 한 장(JPEG). [exact]가 아니면 근처 프레임이라 빠르다.
  private func frameAt(path: String, us: Int64, height: Int, exact: Bool) -> Data? {
    if framePath != path {
      let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
      gen.appliesPreferredTrackTransform = true
      gen.maximumSize = CGSize(width: height * 3, height: height)
      frameGenerator = gen
      framePath = path
    }
    guard let gen = frameGenerator else { return nil }
    let tolerance = exact ? CMTime.zero : CMTime(seconds: 1, preferredTimescale: 600)
    gen.requestedTimeToleranceBefore = tolerance
    gen.requestedTimeToleranceAfter = tolerance
    let t = CMTime(value: max(us, 0), timescale: 1_000_000)
    guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { return nil }
    return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
  }

  // MARK: - export

  /// [rotateCcw]: 화면에서 왼쪽(반시계)으로 더 돌릴 각도. 트랙의 회전 정보만 바꾸므로 무손실이다.
  private func trim(path: String, startUs: Int64, endUs: Int64, rotateCcw: Int, _ result: @escaping FlutterResult) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let range = CMTimeRange(
      start: CMTime(value: startUs, timescale: 1_000_000),
      end: CMTime(value: endUs, timescale: 1_000_000))
    var source: AVAsset = asset
    var timeRange: CMTimeRange? = range
    if rotateCcw % 360 != 0 {
      // 회전하려면 컴포지션으로 구간을 옮겨 담고 트랙 방향을 바꾼다.
      let comp = AVMutableComposition()
      do {
        guard let v = asset.tracks(withMediaType: .video).first,
          let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw EngineError(message: "영상 트랙이 없는 파일이에요") }
        try vt.insertTimeRange(range, of: v, at: .zero)
        let t = v.preferredTransform
        let current = Int((atan2(Double(t.b), Double(t.a)) * 180 / .pi).rounded())
        let angle = ((current - rotateCcw) % 360 + 360) % 360
        vt.preferredTransform = transform(angle: angle, size: v.naturalSize)
        if let a = asset.tracks(withMediaType: .audio).first,
          let audioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        {
          let audioRange = a.timeRange.intersection(range)
          if !audioRange.isEmpty {
            try audioTrack.insertTimeRange(audioRange, of: a, at: audioRange.start - range.start)
          }
        }
      } catch {
        result(FlutterError(code: "FAILED", message: error.localizedDescription, details: nil))
        return
      }
      source = comp
      timeRange = nil
    }
    guard let s = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetPassthrough) else {
      result(FlutterError(code: "FAILED", message: "이 영상은 내보낼 수 없어요", details: nil))
      return
    }
    if let timeRange = timeRange { s.timeRange = timeRange }
    runExport(s, durationUs: endUs - startUs, result)
  }

  /// 시계 방향 [angle]도로 보이게 하는 표준 회전 행렬.
  private func transform(angle: Int, size: CGSize) -> CGAffineTransform {
    let w = abs(size.width)
    let h = abs(size.height)
    switch angle {
    case 90: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
    case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
    case 270: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
    default: return .identity
    }
  }

  private func merge(paths: [String], _ result: @escaping FlutterResult) {
    let comp = AVMutableComposition()
    guard paths.count >= 2,
      let videoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      result(FlutterError(code: "FAILED", message: "두 개 이상 골라주세요", details: nil))
      return
    }
    var audioTrack: AVMutableCompositionTrack?
    var cursor = CMTime.zero
    do {
      for (i, path) in paths.enumerated() {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let v = asset.tracks(withMediaType: .video).first else {
          throw EngineError(message: "\(i + 1)번 영상에 영상 트랙이 없어요")
        }
        if i == 0 { videoTrack.preferredTransform = v.preferredTransform }
        let range = v.timeRange
        try videoTrack.insertTimeRange(range, of: v, at: cursor)
        if let a = asset.tracks(withMediaType: .audio).first {
          if audioTrack == nil {
            audioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
          }
          // 음성은 영상 길이까지만 넣어 다음 영상과 겹치지 않게 한다.
          let audioRange = a.timeRange.intersection(range)
          if !audioRange.isEmpty {
            try audioTrack?.insertTimeRange(audioRange, of: a, at: cursor + (audioRange.start - range.start))
          }
        }
        cursor = cursor + range.duration
      }
    } catch {
      result(FlutterError(code: "FAILED", message: error.localizedDescription, details: nil))
      return
    }
    guard let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
      result(FlutterError(code: "FAILED", message: "이어붙일 수 없는 조합이에요", details: nil))
      return
    }
    runExport(s, durationUs: microseconds(cursor), result)
  }

  private func runExport(_ s: AVAssetExportSession, durationUs: Int64, _ result: @escaping FlutterResult) {
    let useMp4 = s.supportedFileTypes.contains(.mp4)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    let name = "ZamZam_\(formatter.string(from: Date())).\(useMp4 ? "mp4" : "mov")"
    let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: out)
    s.outputURL = out
    s.outputFileType = useMp4 ? .mp4 : .mov
    session = s

    progressTimer?.invalidate()
    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      self?.channel.invokeMethod("progress", arguments: Double(s.progress) * 0.95)
    }
    s.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.progressTimer?.invalidate()
        self.progressTimer = nil
        self.session = nil
        switch s.status {
        case .completed:
          self.saveToPhotos(out, name: name, durationUs: durationUs, result)
        case .cancelled:
          try? FileManager.default.removeItem(at: out)
          result(FlutterError(code: "CANCELLED", message: "취소했어요", details: nil))
        default:
          try? FileManager.default.removeItem(at: out)
          result(FlutterError(
            code: "FAILED", message: s.error?.localizedDescription ?? "내보내지 못했어요", details: nil))
        }
      }
    }
  }

  private func saveToPhotos(_ file: URL, name: String, durationUs: Int64, _ result: @escaping FlutterResult) {
    let size = fileSize(file)
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async {
          result(FlutterError(code: "FAILED", message: "사진 앱에 저장할 권한이 없어요", details: nil))
        }
        return
      }
      var placeholder: PHObjectPlaceholder?
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name
        options.shouldMoveFile = true
        request.addResource(with: .video, fileURL: file, options: options)
        placeholder = request.placeholderForCreatedAsset
      }) { ok, error in
        DispatchQueue.main.async {
          if ok {
            self.channel.invokeMethod("progress", arguments: 1.0)
            result([
              "uri": placeholder?.localIdentifier ?? name,
              "name": name,
              "size": size,
              "durationUs": durationUs,
            ] as [String: Any])
          } else {
            try? FileManager.default.removeItem(at: file)
            result(FlutterError(
              code: "FAILED", message: error?.localizedDescription ?? "사진 앱에 저장하지 못했어요", details: nil))
          }
        }
      }
    }
  }

  // MARK: - helpers

  private func background(_ result: @escaping FlutterResult, _ work: @escaping () throws -> Any) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let value = try work()
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func microseconds(_ t: CMTime) -> Int64 {
    guard t.isNumeric else { return 0 }
    return Int64((t.seconds * 1_000_000).rounded())
  }

  private func fileSize(_ url: URL) -> Int64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
  }

  private func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    var vc = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = vc?.presentedViewController {
      vc = presented
    }
    return vc
  }
}
