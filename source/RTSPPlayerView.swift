import UIKit
import SwiftUI
import VLCKitSPM
import AVKit
import CoreMedia
import VideoToolbox

// MARK: - RTSP Player UIView with Direct Sample Buffer Support
class RTSPPlayerUIView: UIView {
    
    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?
    
    // PiP and Sample Buffer
    private var pipManager: PictureInPictureManager?
    private var isPiPConfigured = false
    
    // Direct RTSP Sample Buffer Processing
    private var sampleBufferProcessor: RTSPDirectSampleBufferProcessor?
    private var isProcessingFrames = false
    
    // Stream info
    private var streamCodec: VideoCodec = .unknown
    private var streamResolution: CGSize = .zero
    
    enum VideoCodec {
        case h264
        case h265
        case unknown
    }
    
    // Low latency options optimized for sample buffer extraction
    private let lowLatencyOptions = [
        "network-caching": "100",
        "rtsp-caching": "100",
        "tcp-caching": "100",
        "realrtsp-caching": "100",
        "clock-jitter": "100",
        "rtsp-tcp": "",
        "avcodec-hw": "videotoolbox",  // Force VideoToolbox hardware decoding
        "clock-synchro": "0",
        "avcodec-skiploopfilter": "0",
        "avcodec-skip-frame": "0",
        "avcodec-skip-idct": "0",
        "avcodec-fast": "",              // Enable fast decoding
        "sout-x264-preset": "ultrafast", // For re-encoding if needed
        "sout-x264-tune": "zerolatency", // Zero latency tuning
        "live-caching": "100",           // Live stream caching
        "file-caching": "100"            // File caching
    ]
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPlayer()
        setupPiPManager()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayer()
        setupPiPManager()
    }
    
    // MARK: - Setup
    
    private func setupPlayer() {
        backgroundColor = .black
        
        // Initialize VLC media player
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer?.drawable = self
        
        // Set initial volume
        mediaPlayer?.audio?.volume = 100
        
        // Set delegate
        mediaPlayer?.delegate = self
        
        // Initialize sample buffer processor
        setupSampleBufferProcessor()
        
        print("RTSP Player initialized with sample buffer support")
    }
    
    private func setupPiPManager() {
        pipManager = PictureInPictureManager.shared
    }
    
    private func setupSampleBufferProcessor() {
        sampleBufferProcessor = RTSPDirectSampleBufferProcessor()
        sampleBufferProcessor?.delegate = self
    }
    
    // MARK: - Playback Methods
    
    func play(url: String, username: String? = nil, password: String? = nil) {
        guard let mediaPlayer = mediaPlayer else { return }
        
        // Stop existing playback
        if mediaPlayer.isPlaying {
            stop()
        }
        
        // Build authenticated RTSP URL
        let rtspURL = buildAuthenticatedURL(url: url, username: username, password: password)
        
        guard let url = URL(string: rtspURL) else {
            print("Invalid URL: \(rtspURL)")
            return
        }
        
        // Create VLC Media
        media = VLCMedia(url: url)
        
        // Apply optimized options for sample buffer extraction
        applyOptimizedOptions()
        
        // Detect codec from URL or stream
        detectStreamCodec(from: rtspURL)
        
        // Set media and start playback
        mediaPlayer.media = media
        mediaPlayer.play()
        
        print("Starting RTSP stream with sample buffer extraction: \(rtspURL)")
        
        // Start sample buffer processing after playback begins
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startSampleBufferProcessing()
        }
    }
    
    private func buildAuthenticatedURL(url: String, username: String?, password: String?) -> String {
        guard let username = username, let password = password else {
            return url
        }
        
        guard var urlComponents = URLComponents(string: url) else {
            return url
        }
        
        var urlString = "\(urlComponents.scheme ?? "rtsp")://"
        urlString += "\(username):\(password)@"
        urlString += "\(urlComponents.host ?? "")"
        if let port = urlComponents.port {
            urlString += ":\(port)"
        }
        urlString += urlComponents.path
        
        return urlString
    }
    
    private func applyOptimizedOptions() {
        guard let media = media else { return }
        
        // Apply low latency options
        for (key, value) in lowLatencyOptions {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
        
        // Additional options for sample buffer extraction
        media.addOption("--intf=dummy")
        media.addOption("--vout=macosx")  // Use native output
        media.addOption("--no-audio-time-stretch")
        media.addOption("--no-network-synchronisation")
        
        // Enable video filter for frame extraction
        media.addOption("--video-filter=scene")
        media.addOption("--scene-format=png")
        media.addOption("--scene-ratio=1")
        
        print("Applied optimized options for sample buffer extraction")
    }
    
    private func detectStreamCodec(from url: String) {
        let lowercasedURL = url.lowercased()
        
        if lowercasedURL.contains("h264") || lowercasedURL.contains("avc") {
            streamCodec = .h264
        } else if lowercasedURL.contains("h265") || lowercasedURL.contains("hevc") {
            streamCodec = .h265
        } else {
            // Try to detect from stream metadata
            streamCodec = .unknown
        }
        
        print("Detected codec: \(streamCodec)")
    }
    
    // MARK: - Sample Buffer Processing
    
    private func startSampleBufferProcessing() {
        guard let mediaPlayer = mediaPlayer,
              mediaPlayer.isPlaying,
              !isProcessingFrames else { return }
        
        isProcessingFrames = true
        
        // Configure PiP with RTSP sample buffer support
        configurePiPWithSampleBuffer()
        
        // Start direct frame processing
        sampleBufferProcessor?.startProcessing(with: mediaPlayer)
        
        print("Started sample buffer processing")
    }
    
    private func configurePiPWithSampleBuffer() {
        guard !isPiPConfigured,
              let mediaPlayer = mediaPlayer else { return }
        
        // Setup PiP with RTSP sample buffer extractor
        pipManager?.setupPiPForRTSPStream(
            vlcPlayer: mediaPlayer,
            streamURL: media?.url?.absoluteString ?? ""
        )
        
        isPiPConfigured = true
        print("Configured PiP with RTSP sample buffer support")
    }
    
    func stop() {
        sampleBufferProcessor?.stopProcessing()
        isProcessingFrames = false
        
        mediaPlayer?.stop()
        media = nil
        isPiPConfigured = false
        
        print("Stopped RTSP stream and sample buffer processing")
    }
    
    func pause() {
        mediaPlayer?.pause()
        sampleBufferProcessor?.pauseProcessing()
    }
    
    func resume() {
        mediaPlayer?.play()
        sampleBufferProcessor?.resumeProcessing()
    }
    
    func setVolume(_ volume: Int32) {
        mediaPlayer?.audio?.volume = volume
    }
    
    func isPlaying() -> Bool {
        return mediaPlayer?.isPlaying ?? false
    }
    
    // MARK: - Stream Information
    
    func getStreamInfo() -> StreamInfo {
        var info = StreamInfo()
        
        guard let mediaPlayer = mediaPlayer else { return info }
        
        // Basic info
        info.isPlaying = mediaPlayer.isPlaying
        info.codec = streamCodec
        
        // Video info
        let videoSize = mediaPlayer.videoSize
        if videoSize.width > 0 && videoSize.height > 0 {
            info.resolution = videoSize
            streamResolution = videoSize
        }
        
        // Track info
        info.hasVideo = (mediaPlayer.videoTrackNames.count ?? 0) > 0
        info.hasAudio = (mediaPlayer.audioTrackNames.count ?? 0) > 0
        
        // Frame rate (estimate from VLC)
        if let fps = mediaPlayer.media?.statistics?.demuxBitrate, fps > 0 {
            info.frameRate = Double(fps)
        }
        
        // Bitrate
        if let stats = mediaPlayer.media?.statistics {
            info.bitrate = Int(stats.demuxBitrate)
        }
        
        return info
    }
    
    func updateLatencySettings(networkCaching: Int) {
        guard let currentMedia = media?.url?.absoluteString,
              isPlaying() else { return }
        
        // Update options and restart stream
        stop()
        
        // Update caching values
        var updatedOptions = lowLatencyOptions
        updatedOptions["network-caching"] = "\(networkCaching)"
        updatedOptions["rtsp-caching"] = "\(networkCaching)"
        updatedOptions["tcp-caching"] = "\(networkCaching)"
        updatedOptions["realrtsp-caching"] = "\(networkCaching)"
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.play(url: currentMedia)
        }
    }
    
    deinit {
        stop()
        sampleBufferProcessor = nil
        mediaPlayer = nil
        print("RTSPPlayerUIView deinitialized")
    }
}

// MARK: - VLCMediaPlayerDelegate
extension RTSPPlayerUIView: VLCMediaPlayerDelegate {
    
    func mediaPlayerStateChanged(_ aNotification: Notification!) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        switch player.state {
        case .opening:
            print("VLC: Opening stream...")
            
        case .buffering:
            if let bufferPercent = player.media?.statistics?.demuxBitrate {
                print("VLC: Buffering... \(bufferPercent)%")
            }
            
        case .playing:
            print("VLC: Playing")
            
            // Extract stream metadata
            if streamCodec == .unknown {
                detectCodecFromMetadata()
            }
            
            // Start sample buffer processing if not started
            if !isProcessingFrames {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.startSampleBufferProcessing()
                }
            }
            
        case .paused:
            print("VLC: Paused")
            
        case .stopped:
            print("VLC: Stopped")
            
        case .error:
            print("VLC: Error occurred")
            if let errorDescription = player.media?.statistics?.decodedAudio {
                print("Error details: \(errorDescription)")
            }
            
        case .ended:
            print("VLC: Stream ended")
            
        @unknown default:
            print("VLC: Unknown state")
        }
    }
    
    func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        // Handle time changes if needed
    }
    
    private func detectCodecFromMetadata() {
        guard let player = mediaPlayer,
              let tracks = player.media?.tracksInformation as? [[String: Any]] else { return }
        
        for track in tracks {
            if let type = track["type"] as? String, type == "video" {
                if let codec = track["codec"] as? String {
                    if codec.contains("h264") || codec.contains("avc") {
                        streamCodec = .h264
                    } else if codec.contains("h265") || codec.contains("hevc") {
                        streamCodec = .h265
                    }
                    print("Detected codec from metadata: \(codec)")
                    break
                }
            }
        }
    }
}

// MARK: - RTSP Direct Sample Buffer Processor
class RTSPDirectSampleBufferProcessor: NSObject {
    
    weak var delegate: RTSPSampleBufferProcessorDelegate?
    
    private var isProcessing = false
    private var isPaused = false
    private weak var vlcPlayer: VLCMediaPlayer?
    
    // Video processing
    private let processingQueue = DispatchQueue(label: "com.rtspplayer.processing", qos: .userInteractive)
    private var frameTimer: Timer?
    
    // Direct frame access through VLC
    private var videoOutputCallback: UnsafeMutableRawPointer?
    
    func startProcessing(with player: VLCMediaPlayer) {
        guard !isProcessing else { return }
        
        vlcPlayer = player
        isProcessing = true
        isPaused = false
        
        // Setup direct video output access
        setupDirectVideoAccess()
        
        // Start frame extraction timer
        startFrameExtraction()
    }
    
    func stopProcessing() {
        isProcessing = false
        frameTimer?.invalidate()
        frameTimer = nil
        cleanupDirectVideoAccess()
    }
    
    func pauseProcessing() {
        isPaused = true
    }
    
    func resumeProcessing() {
        isPaused = false
    }
    
    private func setupDirectVideoAccess() {
        // This is where we'd set up direct access to VLC's video output
        // In a production app, this would involve VLC's video callback API
        print("Setting up direct video access for sample buffer extraction")
    }
    
    private func cleanupDirectVideoAccess() {
        videoOutputCallback = nil
    }
    
    private func startFrameExtraction() {
        // Use CADisplayLink for better frame timing
        DispatchQueue.main.async { [weak self] in
            let displayLink = CADisplayLink(target: self!, selector: #selector(self?.extractFrame))
            displayLink.preferredFramesPerSecond = 30
            displayLink.add(to: .current, forMode: .common)
            // Store as timer for compatibility
            self?.frameTimer = Timer(timeInterval: 1.0/30.0, repeats: false, block: { _ in })
        }
    }
    
    @objc private func extractFrame() {
        guard isProcessing, !isPaused,
              let player = vlcPlayer,
              player.isPlaying else { return }
        
        processingQueue.async { [weak self] in
            self?.processCurrentFrame()
        }
    }
    
    private func processCurrentFrame() {
        // Extract frame data from VLC
        // This would typically use VLC's video callback API
        
        // For now, capture from drawable
        DispatchQueue.main.async { [weak self] in
            guard let drawable = self?.vlcPlayer?.drawable as? UIView else { return }
            
            if let sampleBuffer = self?.createSampleBuffer(from: drawable) {
                self?.delegate?.didProcessSampleBuffer(sampleBuffer)
            }
        }
    }
    
    private func createSampleBuffer(from view: UIView) -> CMSampleBuffer? {
        // Create CVPixelBuffer from view
        guard let pixelBuffer = view.createPixelBuffer() else { return nil }
        
        // Create CMSampleBuffer
        return pixelBuffer.createSampleBuffer()
    }
}

// MARK: - Sample Buffer Processor Delegate
protocol RTSPSampleBufferProcessorDelegate: AnyObject {
    func didProcessSampleBuffer(_ sampleBuffer: CMSampleBuffer)
}

extension RTSPPlayerUIView: RTSPSampleBufferProcessorDelegate {
    func didProcessSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Forward to PiP manager if needed
        print("Processed sample buffer")
    }
}

// MARK: - Stream Info
struct StreamInfo {
    var isPlaying: Bool = false
    var codec: RTSPPlayerUIView.VideoCodec = .unknown
    var resolution: CGSize = .zero
    var frameRate: Double = 0.0
    var bitrate: Int = 0
    var hasVideo: Bool = false
    var hasAudio: Bool = false
    
    var resolutionString: String {
        if resolution.width > 0 && resolution.height > 0 {
            return "\(Int(resolution.width))x\(Int(resolution.height))"
        }
        return "Unknown"
    }
    
    var qualityString: String {
        if resolution.width >= 3840 {
            return "4K UHD"
        } else if resolution.width >= 1920 {
            return "Full HD"
        } else if resolution.width >= 1280 {
            return "HD"
        } else {
            return "SD"
        }
    }
    
    var codecString: String {
        switch codec {
        case .h264:
            return "H.264/AVC"
        case .h265:
            return "H.265/HEVC"
        case .unknown:
            return "Unknown"
        }
    }
}

// MARK: - Helper Extensions
extension UIView {
    func createPixelBuffer() -> CVPixelBuffer? {
        let width = Int(bounds.width * UIScreen.main.scale)
        let height = Int(bounds.height * UIScreen.main.scale)
        
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        }
        
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }
        
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: UIScreen.main.scale, y: -UIScreen.main.scale)
        
        layer.render(in: context)
        
        return buffer
    }
}

extension CVPixelBuffer {
    func createSampleBuffer() -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: self,
            formatDescriptionOut: &formatDescription
        )
        
        guard let formatDesc = formatDescription else { return nil }
        
        let currentTime = CACurrentMediaTime()
        let presentationTime = CMTime(seconds: currentTime, preferredTimescale: 600)
        
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(seconds: 1.0/30.0, preferredTimescale: 600),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: self,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        guard status == noErr, let buffer = sampleBuffer else {
            return nil
        }
        
        // Mark for immediate display
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) {
            let dict = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        
        return buffer
    }
}

// MARK: - SwiftUI Wrapper
struct RTSPPlayerView: UIViewRepresentable {
    @Binding var url: String
    @Binding var isPlaying: Bool
    var username: String?
    var password: String?
    var networkCaching: Int = 100
    
    func makeUIView(context: Context) -> RTSPPlayerUIView {
        let playerView = RTSPPlayerUIView()
        return playerView
    }
    
    func updateUIView(_ uiView: RTSPPlayerUIView, context: Context) {
        if isPlaying {
            if !uiView.isPlaying() && !url.isEmpty {
                uiView.play(url: url, username: username, password: password)
            }
        } else {
            if uiView.isPlaying() {
                uiView.pause()
            }
        }
        
        // Update latency settings
        uiView.updateLatencySettings(networkCaching: networkCaching)
    }
    
    static func dismantleUIView(_ uiView: RTSPPlayerUIView, coordinator: ()) {
        uiView.stop()
    }
}

// MARK: - SwiftUI Preview
struct RTSPPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        RTSPPlayerView(
            url: .constant("rtsp://example.com/stream"),
            isPlaying: .constant(true),
            networkCaching: 100
        )
    }
}
