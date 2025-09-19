import UIKit
import SwiftUI
import VLCKitSPM
import AVKit
import CoreMedia
import VideoToolbox

// MARK: - Enhanced RTSP Player UIView
class RTSPPlayerUIView: UIView {
    
    // VLC Components
    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?
    
    // PiP Integration
    private let pipManager = PictureInPictureManager.shared
    private var isPiPSetup = false
    
    // Sample Buffer Processing
    private var renderingLayer: AVSampleBufferDisplayLayer?
    private let sampleBufferQueue = DispatchQueue(label: "com.rtspplayer.samplebuffer", qos: .userInteractive)
    
    // Performance Optimization
    private let lowLatencyOptions = [
        "network-caching": "100",
        "rtsp-caching": "100",
        "tcp-caching": "100",
        "realrtsp-caching": "100",
        "rtsp-tcp": "",
        "avcodec-hw": "videotoolbox",      // Use VideoToolbox for H.264/H.265
        "avcodec-threads": "auto",
        "clock-synchro": "0",
        "avcodec-skiploopfilter": "0",
        "avcodec-skip-frame": "0",
        "avcodec-skip-idct": "0",
        "drop-late-frames": "0",
        "skip-frames": "0"
    ]
    
    // Stream Info
    private var streamInfo = StreamInfo()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    // MARK: - Setup
    
    private func setupView() {
        backgroundColor = .black
        setupVLCPlayer()
        setupRenderingLayer()
        registerNotifications()
    }
    
    private func setupVLCPlayer() {
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer?.drawable = self
        mediaPlayer?.delegate = self
        
        // Set audio volume
        mediaPlayer?.audio?.volume = 100
        
        print("VLC Player initialized")
    }
    
    private func setupRenderingLayer() {
        // Create sample buffer display layer for potential direct rendering
        renderingLayer = AVSampleBufferDisplayLayer()
        renderingLayer?.videoGravity = .resizeAspect
        renderingLayer?.backgroundColor = UIColor.black.cgColor
        
        if let renderingLayer = renderingLayer {
            layer.addSublayer(renderingLayer)
            renderingLayer.frame = bounds
            renderingLayer.isHidden = true // Initially hidden, shown when needed
        }
    }
    
    private func registerNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    // MARK: - Playback Control
    
    func play(url: String, username: String? = nil, password: String? = nil) {
        stop() // Clean up any existing playback
        
        // Build authenticated URL if needed
        let rtspURL = buildAuthenticatedURL(url: url, username: username, password: password)
        
        guard let mediaURL = URL(string: rtspURL) else {
            print("Invalid URL: \(rtspURL)")
            return
        }
        
        // Create VLC media with optimizations
        media = VLCMedia(url: mediaURL)
        applyStreamOptimizations()
        
        // Set media and start playback
        mediaPlayer?.media = media
        mediaPlayer?.play()
        
        print("Starting RTSP stream: \(rtspURL)")
        
        // Setup PiP after a short delay to ensure playback has started
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.setupPictureInPicture()
        }
    }
    
    private func buildAuthenticatedURL(url: String, username: String?, password: String?) -> String {
        guard let username = username, 
              let password = password,
              !username.isEmpty, 
              !password.isEmpty else {
            return url
        }
        
        if let urlComponents = URLComponents(string: url) {
            var components = urlComponents
            var urlString = "\(components.scheme ?? "rtsp")://"
            urlString += "\(username):\(password)@"
            urlString += "\(components.host ?? "")"
            if let port = components.port {
                urlString += ":\(port)"
            }
            urlString += components.path
            if let query = components.query {
                urlString += "?\(query)"
            }
            return urlString
        }
        
        return url
    }
    
    private func applyStreamOptimizations() {
        guard let media = media else { return }
        
        // Apply low latency options
        for (key, value) in lowLatencyOptions {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
        
        // Additional codec-specific optimizations
        media.addOption("--intf=dummy")
        media.addOption("--no-audio-time-stretch")
        media.addOption("--no-network-synchronisation")
        
        // H.264/H.265 hardware acceleration
        media.addOption("--codec=avcodec")
        media.addOption("--avcodec-hw=videotoolbox")
        
        print("Stream optimizations applied")
    }
    
    func stop() {
        mediaPlayer?.stop()
        media = nil
        isPiPSetup = false
        streamInfo.reset()
        print("Playback stopped")
    }
    
    func pause() {
        mediaPlayer?.pause()
    }
    
    func resume() {
        mediaPlayer?.play()
    }
    
    func setVolume(_ volume: Int32) {
        mediaPlayer?.audio?.volume = max(0, min(200, volume))
    }
    
    // MARK: - Picture in Picture Setup
    
    private func setupPictureInPicture() {
        guard let mediaPlayer = mediaPlayer,
              mediaPlayer.isPlaying,
              !isPiPSetup else { return }
        
        // Setup PiP with the new sample buffer approach
        pipManager.setupPiPForVLCPlayer(mediaPlayer, in: self)
        isPiPSetup = true
        
        print("Picture in Picture configured")
    }
    
    // MARK: - Stream Information
    
    func updateStreamInfo() {
        guard let mediaPlayer = mediaPlayer else { return }
        
        streamInfo.isPlaying = mediaPlayer.isPlaying
        streamInfo.position = mediaPlayer.position
        streamInfo.time = mediaPlayer.time
        
        // Video info
        let videoSize = mediaPlayer.videoSize
        if videoSize.width > 0 && videoSize.height > 0 {
            streamInfo.videoResolution = videoSize
            streamInfo.hasVideo = true
        }
        
        // Audio info
        streamInfo.hasAudio = (mediaPlayer.audioTrackIndexes?.count ?? 0) > 0
        
        // Codec detection
        if let media = media {
            streamInfo.codec = detectCodec(from: media)
        }
    }
    
    private func detectCodec(from media: VLCMedia) -> String {
        // Try to detect codec from media metadata
        if let tracksInfo = media.tracksInformation as? [[String: Any]] {
            for track in tracksInfo {
                if let type = track["type"] as? String,
                   type == "video",
                   let codec = track["codec"] as? String {
                    if codec.contains("h264") || codec.contains("avc1") {
                        return "H.264"
                    } else if codec.contains("h265") || codec.contains("hevc") {
                        return "H.265"
                    }
                }
            }
        }
        
        // Fallback to URL hints
        let urlString = media.url?.absoluteString.lowercased() ?? ""
        if urlString.contains("h264") {
            return "H.264"
        } else if urlString.contains("h265") || urlString.contains("hevc") {
            return "H.265"
        }
        
        return "Unknown"
    }
    
    func getStreamInfo() -> StreamInfo {
        updateStreamInfo()
        return streamInfo
    }
    
    // MARK: - Network Statistics
    
    func getNetworkStats() -> NetworkStats {
        var stats = NetworkStats()
        
        if let mediaPlayer = mediaPlayer {
            // Basic stats from VLC
            stats.isConnected = mediaPlayer.isPlaying
            stats.bufferLevel = 0.0 // VLC doesn't expose buffer level directly
            
            // Calculate bitrate if possible
            if let media = media, media.length.intValue > 0 {
                // Rough estimation
                stats.bitrate = 0
            }
        }
        
        return stats
    }
    
    // MARK: - Advanced Features
    
    func updateLatencySettings(networkCaching: Int) {
        guard let currentURL = media?.url?.absoluteString,
              mediaPlayer?.isPlaying == true else { return }
        
        // Update caching values
        var updatedOptions = lowLatencyOptions
        updatedOptions["network-caching"] = "\(networkCaching)"
        updatedOptions["rtsp-caching"] = "\(networkCaching)"
        updatedOptions["tcp-caching"] = "\(networkCaching)"
        
        // Restart with new settings
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.play(url: currentURL)
        }
    }
    
    func captureSnapshot() -> UIImage? {
        // Render current view to image
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { context in
            layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - Layout
    
    override func layoutSubviews() {
        super.layoutSubviews()
        renderingLayer?.frame = bounds
    }
    
    // MARK: - Background Handling
    
    @objc private func handleEnterBackground() {
        // Continue playback in background if PiP is active
        if !pipManager.isPiPActive {
            // Optionally pause to save resources
            // pause()
        }
    }
    
    @objc private func handleEnterForeground() {
        // Resume if needed
        if mediaPlayer?.state == .paused {
            // resume()
        }
    }
    
    // MARK: - Cleanup
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stop()
        mediaPlayer = nil
        print("RTSPPlayerUIView deinitialized")
    }
}

// MARK: - VLCMediaPlayerDelegate
extension RTSPPlayerUIView: VLCMediaPlayerDelegate {
    
    func mediaPlayerStateChanged(_ aNotification: Notification!) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        let state = player.state
        streamInfo.playerState = state
        
        switch state {
        case .opening:
            print("VLC: Opening stream...")
            onStreamOpening()
            
        case .buffering:
            let bufferProgress = player.position * 100
            print("VLC: Buffering... \(Int(bufferProgress))%")
            onStreamBuffering(progress: bufferProgress)
            
        case .playing:
            print("VLC: Playing")
            onStreamPlaying()
            
        case .paused:
            print("VLC: Paused")
            onStreamPaused()
            
        case .stopped:
            print("VLC: Stopped")
            onStreamStopped()
            
        case .error:
            print("VLC: Error occurred")
            onStreamError()
            
        case .ended:
            print("VLC: Stream ended")
            onStreamEnded()
            
        @unknown default:
            print("VLC: Unknown state")
        }
    }
    
    func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        // Update time if needed
        if let player = aNotification.object as? VLCMediaPlayer {
            streamInfo.time = player.time
            streamInfo.position = player.position
        }
    }
    
    // MARK: - State Handlers
    
    private func onStreamOpening() {
        // Prepare UI for stream opening
    }
    
    private func onStreamBuffering(progress: Float) {
        // Update buffering indicator
    }
    
    private func onStreamPlaying() {
        // Setup PiP if not already done
        if !isPiPSetup {
            setupPictureInPicture()
        }
        
        // Update stream info
        updateStreamInfo()
    }
    
    private func onStreamPaused() {
        // Handle pause state
    }
    
    private func onStreamStopped() {
        // Clean up resources
        isPiPSetup = false
    }
    
    private func onStreamError() {
        // Handle error state
        // Could implement retry logic here
    }
    
    private func onStreamEnded() {
        // Handle stream end
    }
}

// MARK: - Stream Info Model
struct StreamInfo {
    var isPlaying: Bool = false
    var hasVideo: Bool = false
    var hasAudio: Bool = false
    var videoResolution: CGSize = .zero
    var codec: String = "Unknown"
    var position: Float = 0.0
    var time: VLCTime?
    var playerState: VLCMediaPlayerState = .stopped
    
    mutating func reset() {
        isPlaying = false
        hasVideo = false
        hasAudio = false
        videoResolution = .zero
        codec = "Unknown"
        position = 0.0
        time = nil
        playerState = .stopped
    }
    
    var resolutionText: String {
        if videoResolution == .zero {
            return "Unknown"
        }
        return "\(Int(videoResolution.width))x\(Int(videoResolution.height))"
    }
    
    var qualityText: String {
        let width = Int(videoResolution.width)
        let height = Int(videoResolution.height)
        
        if width >= 3840 && height >= 2160 {
            return "4K UHD"
        } else if width >= 1920 && height >= 1080 {
            return "Full HD"
        } else if width >= 1280 && height >= 720 {
            return "HD"
        } else if width > 0 && height > 0 {
            return "SD"
        }
        return "Unknown"
    }
}

// MARK: - Network Statistics Model
struct NetworkStats {
    var isConnected: Bool = false
    var bitrate: Int = 0
    var bufferLevel: Float = 0.0
    var packetsLost: Int = 0
    var packetsReceived: Int = 0
    
    var bitrateText: String {
        if bitrate > 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000.0)
        } else if bitrate > 1000 {
            return String(format: "%.0f Kbps", Double(bitrate) / 1000.0)
        }
        return "\(bitrate) bps"
    }
}

// MARK: - SwiftUI Wrapper
struct RTSPPlayerView: UIViewRepresentable {
    @Binding var url: String
    @Binding var isPlaying: Bool
    var username: String?
    var password: String?
    var networkCaching: Int = 100
    var onStreamInfo: ((StreamInfo) -> Void)?
    
    func makeUIView(context: Context) -> RTSPPlayerUIView {
        let playerView = RTSPPlayerUIView()
        context.coordinator.playerView = playerView
        return playerView
    }
    
    func updateUIView(_ uiView: RTSPPlayerUIView, context: Context) {
        if isPlaying {
            if !uiView.isPlaying && !url.isEmpty {
                uiView.play(url: url, username: username, password: password)
            }
        } else {
            if uiView.isPlaying {
                uiView.pause()
            }
        }
        
        // Update latency settings if changed
        uiView.updateLatencySettings(networkCaching: networkCaching)
        
        // Report stream info
        if let onStreamInfo = onStreamInfo {
            onStreamInfo(uiView.getStreamInfo())
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    static func dismantleUIView(_ uiView: RTSPPlayerUIView, coordinator: Coordinator) {
        uiView.stop()
    }
    
    class Coordinator {
        weak var playerView: RTSPPlayerUIView?
    }
}

// MARK: - Helper Extensions
extension RTSPPlayerUIView {
    
    var isPlaying: Bool {
        return mediaPlayer?.isPlaying ?? false
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }
    
    func reconnect() {
        guard let currentURL = media?.url?.absoluteString else { return }
        
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.play(url: currentURL)
        }
    }
}
