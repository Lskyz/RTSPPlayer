import UIKit
import SwiftUI
import VLCKitSPM
import AVKit

// MARK: - RTSP Player UIView with Sample Buffer PiP
class RTSPPlayerUIView: UIView {
    
    // VLC Components
    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?
    
    // PiP Components
    private let pipManager = PictureInPictureManager.shared
    private var isPiPEnabled = false
    
    // Stream Info
    private var currentStreamURL: String?
    private var streamInfo: StreamInfo?
    
    // Performance Monitoring
    private var performanceMonitor: PerformanceMonitor?
    
    // Low Latency Options
    private let lowLatencyOptions: [String: String] = [
        "network-caching": "150",
        "rtsp-caching": "150",
        "tcp-caching": "150",
        "realrtsp-caching": "150",
        "clock-jitter": "150",
        "rtsp-tcp": "",
        "avcodec-hw": "videotoolbox", // Use VideoToolbox for hardware decoding
        "clock-synchro": "0",
        "avcodec-skiploopfilter": "0",
        "avcodec-skip-frame": "0",
        "avcodec-skip-idct": "0",
        "avcodec-threads": "4", // Multi-threading for better performance
        "sout-mux-caching": "10", // Output mux caching
        "live-caching": "150" // Live stream caching
    ]
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPlayer()
        setupPerformanceMonitoring()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayer()
        setupPerformanceMonitoring()
    }
    
    // MARK: - Setup
    
    private func setupPlayer() {
        backgroundColor = .black
        
        // Initialize VLC Media Player
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer?.drawable = self
        mediaPlayer?.audio?.volume = 100
        mediaPlayer?.delegate = self
        
        print("VLC Player initialized")
    }
    
    private func setupPerformanceMonitoring() {
        performanceMonitor = PerformanceMonitor()
        performanceMonitor?.startMonitoring()
    }
    
    // MARK: - Playback Control
    
    func play(url: String, username: String? = nil, password: String? = nil, networkCaching: Int = 150) {
        // Stop current playback
        if mediaPlayer?.isPlaying == true {
            stop()
        }
        
        // Build authenticated URL
        let authenticatedURL = buildAuthenticatedURL(url: url, username: username, password: password)
        
        guard let mediaURL = URL(string: authenticatedURL) else {
            print("Invalid URL: \(authenticatedURL)")
            return
        }
        
        currentStreamURL = authenticatedURL
        
        // Create VLC Media
        media = VLCMedia(url: mediaURL)
        
        // Apply optimizations
        applyStreamOptimizations(caching: networkCaching)
        
        // Set media and play
        mediaPlayer?.media = media
        mediaPlayer?.play()
        
        print("Starting stream: \(url)")
        
        // Setup PiP after a delay
        setupPiPAfterDelay()
    }
    
    private func buildAuthenticatedURL(url: String, username: String?, password: String?) -> String {
        guard let username = username, let password = password else { return url }
        
        if let urlComponents = URLComponents(string: url) {
            let components = urlComponents  // Changed from var to let
            var urlString = "\(components.scheme ?? "rtsp")://"
            urlString += "\(username):\(password)@"
            urlString += "\(components.host ?? "")"
            if let port = components.port {
                urlString += ":\(port)"
            }
            urlString += components.path
            return urlString
        }
        
        return url
    }
    
    private func applyStreamOptimizations(caching: Int) {
        guard let media = media else { return }
        
        // Update caching values
        var options = lowLatencyOptions
        options["network-caching"] = "\(caching)"
        options["rtsp-caching"] = "\(caching)"
        options["tcp-caching"] = "\(caching)"
        options["realrtsp-caching"] = "\(caching)"
        options["live-caching"] = "\(caching)"
        
        // Apply all options
        for (key, value) in options {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
        
        // Additional codec optimizations
        media.addOption("--intf=dummy")
        media.addOption("--no-audio-time-stretch")
        media.addOption("--no-network-synchronisation")
        media.addOption("--no-drop-late-frames")
        media.addOption("--no-skip-frames")
        
        print("Applied optimizations with caching: \(caching)ms")
    }
    
    private func setupPiPAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.setupPiP()
        }
    }
    
    private func setupPiP() {
        guard let mediaPlayer = mediaPlayer,
              mediaPlayer.isPlaying,
              !isPiPEnabled else { return }
        
        // Connect PiP manager to this view
        pipManager.connectToVLCPlayer(mediaPlayer, containerView: self)
        isPiPEnabled = true
        
        print("PiP setup completed")
    }
    
    func stop() {
        mediaPlayer?.stop()
        media = nil
        currentStreamURL = nil
        isPiPEnabled = false
        streamInfo = nil
        
        print("Stream stopped")
    }
    
    func pause() {
        mediaPlayer?.pause()
    }
    
    func resume() {
        mediaPlayer?.play()
    }
    
    func setVolume(_ volume: Int32) {
        mediaPlayer?.audio?.volume = volume
    }
    
    func isPlaying() -> Bool {
        return mediaPlayer?.isPlaying ?? false
    }
    
    // MARK: - Advanced Features
    
    func updateNetworkCaching(_ caching: Int) {
        guard let currentURL = currentStreamURL, isPlaying() else { return }
        
        // Restart with new caching settings
        let wasPlaying = isPlaying()
        stop()
        
        if wasPlaying {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.play(url: currentURL, networkCaching: caching)
            }
        }
    }
    
    func getStreamInfo() -> StreamInfo? {
        guard let mediaPlayer = mediaPlayer, mediaPlayer.isPlaying else { return nil }
        
        var info = StreamInfo()
        
        // Video info
        let videoSize = mediaPlayer.videoSize
        info.resolution = CGSize(width: CGFloat(videoSize.width), height: CGFloat(videoSize.height))
        info.videoCodec = detectVideoCodec()
        
        // Audio info - Fixed: audioTrackNames is not optional
        if let audioTracks = mediaPlayer.audioTrackNames as? [String],
           let audioTrack = audioTracks.first {
            info.audioTrack = audioTrack
        }
        
        // Playback info
        info.position = mediaPlayer.position
        info.time = TimeInterval(mediaPlayer.time.intValue / 1000)
        
        // Network info
        info.isBuffering = mediaPlayer.state == .buffering
        info.droppedFrames = getDroppedFrames()
        
        // Performance info
        if let performance = performanceMonitor?.getCurrentMetrics() {
            info.cpuUsage = performance.cpuUsage
            info.memoryUsage = performance.memoryUsage
            info.fps = performance.fps
        }
        
        self.streamInfo = info
        return info
    }
    
    private func detectVideoCodec() -> String {
        // Try to detect codec from media info
        if let media = media {
            // Parse codec info from VLC media (simplified)
            let url = media.url?.absoluteString ?? ""
            if url.contains("h264") || url.contains("avc") {
                return "H.264/AVC"
            } else if url.contains("h265") || url.contains("hevc") {
                return "H.265/HEVC"
            }
        }
        
        return "Unknown"
    }
    
    private func getDroppedFrames() -> Int {
        // VLC doesn't directly expose dropped frames count
        // This would need custom implementation or VLC library modification
        return 0
    }
    
    // MARK: - PiP Control
    
    func startPictureInPicture() {
        if !isPiPEnabled {
            setupPiP()
        }
        
        if pipManager.canStartPiP {
            pipManager.startPiP()
        }
    }
    
    func stopPictureInPicture() {
        pipManager.stopPiP()
    }
    
    func togglePictureInPicture() {
        pipManager.togglePiP()
    }
    
    var isPiPActive: Bool {
        return pipManager.isPiPActive
    }
    
    var isPiPPossible: Bool {
        return pipManager.isPiPPossible
    }
    
    // MARK: - Cleanup
    
    deinit {
        stop()
        performanceMonitor?.stopMonitoring()
        mediaPlayer = nil
        print("RTSPPlayerUIView deinitialized")
    }
}

// MARK: - VLCMediaPlayerDelegate
extension RTSPPlayerUIView: VLCMediaPlayerDelegate {
    
    // Fixed: Changed parameter from Notification! to Notification to match protocol
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        // Fixed: Made switch exhaustive by adding .esAdded case
        switch player.state {
        case .opening:
            print("VLC: Opening stream...")
            streamInfo?.state = "Opening"
            
        case .buffering:
            let bufferPercent = player.position * 100
            print("VLC: Buffering... \(Int(bufferPercent))%")
            streamInfo?.state = "Buffering"
            
        case .playing:
            print("VLC: Playing")
            streamInfo?.state = "Playing"
            
            // Setup PiP if not done
            if !isPiPEnabled {
                setupPiPAfterDelay()
            }
            
        case .paused:
            print("VLC: Paused")
            streamInfo?.state = "Paused"
            
        case .stopped:
            print("VLC: Stopped")
            streamInfo?.state = "Stopped"
            
        case .error:
            print("VLC: Error occurred")
            streamInfo?.state = "Error"
            streamInfo?.lastError = "Stream playback error"
            
        case .ended:
            print("VLC: Ended")
            streamInfo?.state = "Ended"
            
        case .esAdded:
            print("VLC: Elementary stream added")
            streamInfo?.state = "ES Added"
            
        @unknown default:
            print("VLC: Unknown state")
        }
    }
    
    // Fixed: Changed parameter from Notification! to Notification to match protocol
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // Update time info
        if let player = aNotification.object as? VLCMediaPlayer {
            streamInfo?.time = TimeInterval(player.time.intValue / 1000)
            streamInfo?.position = player.position
        }
    }
}

// MARK: - Stream Info Model
struct StreamInfo {
    var state: String = "Idle"
    var resolution: CGSize = .zero
    var videoCodec: String = "Unknown"
    var audioTrack: String?
    var position: Float = 0.0
    var time: TimeInterval = 0
    var isBuffering: Bool = false
    var droppedFrames: Int = 0
    var lastError: String?
    var cpuUsage: Float = 0.0
    var memoryUsage: Float = 0.0
    var fps: Float = 0.0
    
    var qualityDescription: String {
        if resolution.width >= 3840 {
            return "4K UHD"
        } else if resolution.width >= 1920 {
            return "Full HD"
        } else if resolution.width >= 1280 {
            return "HD"
        } else if resolution.width > 0 {
            return "SD"
        } else {
            return "Unknown"
        }
    }
    
    var resolutionString: String {
        if resolution.width > 0 && resolution.height > 0 {
            return "\(Int(resolution.width))x\(Int(resolution.height))"
        }
        return "N/A"
    }
}

// MARK: - Performance Monitor
class PerformanceMonitor {
    private var timer: Timer?
    private var lastCPUInfo: host_cpu_load_info?
    
    struct Metrics {
        var cpuUsage: Float = 0.0
        var memoryUsage: Float = 0.0
        var fps: Float = 0.0
    }
    
    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    func getCurrentMetrics() -> Metrics {
        var metrics = Metrics()
        
        // CPU Usage
        metrics.cpuUsage = getCPUUsage()
        
        // Memory Usage
        metrics.memoryUsage = getMemoryUsage()
        
        // FPS (would need actual frame counting)
        metrics.fps = 30.0 // Placeholder
        
        return metrics
    }
    
    private func updateMetrics() {
        // Update metrics periodically
        _ = getCurrentMetrics()
    }
    
    private func getCPUUsage() -> Float {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            return Float(info.resident_size) / Float(1024 * 1024) // MB
        }
        
        return 0.0
    }
    
    private func getMemoryUsage() -> Float {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            return Float(info.resident_size) / Float(1024 * 1024 * 1024) // GB
        }
        
        return 0.0
    }
    
    deinit {
        stopMonitoring()
    }
}

// MARK: - SwiftUI Wrapper
struct RTSPPlayerView: UIViewRepresentable {
    @Binding var url: String
    @Binding var isPlaying: Bool
    var username: String?
    var password: String?
    var networkCaching: Int = 150
    
    // Callbacks
    var onStreamInfo: ((StreamInfo) -> Void)?
    var onPiPStatusChanged: ((Bool) -> Void)?
    
    func makeUIView(context: Context) -> RTSPPlayerUIView {
        let playerView = RTSPPlayerUIView()
        
        // Setup PiP delegate
        PictureInPictureManager.shared.delegate = context.coordinator
        
        return playerView
    }
    
    func updateUIView(_ uiView: RTSPPlayerUIView, context: Context) {
        if isPlaying {
            if !uiView.isPlaying() && !url.isEmpty {
                uiView.play(url: url, username: username, password: password, networkCaching: networkCaching)
            }
        } else {
            if uiView.isPlaying() {
                uiView.pause()
            }
        }
        
        // Update network caching if changed
        uiView.updateNetworkCaching(networkCaching)
        
        // Get stream info
        if let info = uiView.getStreamInfo() {
            onStreamInfo?(info)
        }
        
        // Report PiP status
        onPiPStatusChanged?(uiView.isPiPActive)
    }
    
    static func dismantleUIView(_ uiView: RTSPPlayerUIView, coordinator: Coordinator) {
        uiView.stop()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // MARK: - Coordinator
    class Coordinator: NSObject, PictureInPictureManagerDelegate {
        let parent: RTSPPlayerView
        
        init(_ parent: RTSPPlayerView) {
            self.parent = parent
        }
        
        func pipDidStart() {
            parent.onPiPStatusChanged?(true)
        }
        
        func pipDidStop() {
            parent.onPiPStatusChanged?(false)
        }
        
        func pipWillStart() {
            // Handle PiP will start
        }
        
        func pipWillStop() {
            // Handle PiP will stop
        }
        
        func pipRestoreUserInterface(completionHandler: @escaping (Bool) -> Void) {
            // Restore UI when returning from PiP
            completionHandler(true)
        }
    }
}

// MARK: - Helper Extensions
extension RTSPPlayerView {
    
    /// Configure with stream info callback
    func onStreamInfoUpdate(_ callback: @escaping (StreamInfo) -> Void) -> RTSPPlayerView {
        var view = self
        view.onStreamInfo = callback
        return view
    }
    
    /// Configure with PiP status callback
    func onPiPStatusUpdate(_ callback: @escaping (Bool) -> Void) -> RTSPPlayerView {
        var view = self
        view.onPiPStatusChanged = callback
        return view
    }
}
