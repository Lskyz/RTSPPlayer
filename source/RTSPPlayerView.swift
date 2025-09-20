import UIKit
import SwiftUI
import VLCKitSPM
import AVKit

// MARK: - Enhanced RTSP Player UIView with System Level PiP (Software Rendering)
class RTSPPlayerUIView: UIView {
    
    // VLC Components
    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?
    
    // Video rendering optimization
    private var videoContainerView: UIView?
    private var containerViewConstraints: [NSLayoutConstraint] = []
    
    // PiP Components - Using enhanced manager
    private let pipManager = PictureInPictureManager.shared
    private var isPiPConnected = false
    
    // Stream management
    private var currentStreamURL: String?
    private var streamInfo: StreamInfo?
    private var isSetupComplete = false
    
    // Performance monitoring
    private var performanceMonitor: PerformanceMonitor?
    
    // Callbacks
    var onStreamInfoUpdate: ((StreamInfo) -> Void)?
    var onPiPStatusUpdate: ((Bool) -> Void)?
    
    // Low latency optimization settings (SOFTWARE RENDERING - NO HARDWARE ACCELERATION)
    private let lowLatencyOptions: [String: String] = [
        "network-caching": "150",
        "rtsp-caching": "150", 
        "tcp-caching": "150",
        "realrtsp-caching": "150",
        "clock-jitter": "150",
        "rtsp-tcp": "",
        // REMOVED: "avcodec-hw": "videotoolbox" - 하드웨어 가속 비활성화
        "clock-synchro": "0",
        "avcodec-skiploopfilter": "0",
        "avcodec-skip-frame": "0", 
        "avcodec-skip-idct": "0",
        "avcodec-threads": "4",
        "sout-mux-caching": "10",
        "live-caching": "150",
        "no-audio-time-stretch": "",
        "no-drop-late-frames": "",
        "no-skip-frames": ""
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
    
    // MARK: - Setup Methods
    
    private func setupPlayer() {
        backgroundColor = .black
        
        // Create optimized video container
        setupVideoContainer()
        
        // Initialize VLC Media Player with optimizations
        mediaPlayer = VLCMediaPlayer()
        guard let player = mediaPlayer else {
            print("❌ Failed to create VLC media player")
            return
        }
        
        // Configure player for optimal streaming (SOFTWARE RENDERING)
        configureVLCPlayer(player)
        
        print("✅ VLC Player initialized with SOFTWARE RENDERING for PiP compatibility")
        isSetupComplete = true
    }
    
    private func setupVideoContainer() {
        // Create dedicated container view for video rendering
        videoContainerView = UIView()
        videoContainerView?.backgroundColor = .black
        videoContainerView?.translatesAutoresizingMaskIntoConstraints = false
        videoContainerView?.isOpaque = true
        videoContainerView?.clearsContextBeforeDrawing = false
        
        guard let containerView = videoContainerView else { return }
        
        addSubview(containerView)
        
        // Setup constraints for full coverage
        containerViewConstraints = [
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        
        NSLayoutConstraint.activate(containerViewConstraints)
        
        print("🖼️ Video container setup completed")
    }
    
    private func configureVLCPlayer(_ player: VLCMediaPlayer) {
        // Set drawable to container view
        player.drawable = videoContainerView
        
        // Configure audio
        player.audio?.volume = 100
        
        // Set delegate for state monitoring
        player.delegate = self
        
        // Configure video settings for optimal rendering
        player.videoAspectRatio = nil // Auto-detect
        player.scaleFactor = 0 // Auto-scale
        
        // Enable hardware acceleration if available
        if let videoView = videoContainerView {
            videoView.contentMode = .scaleAspectFit
        }
        
        print("⚙️ VLC Player configured for software rendering (PiP compatible)")
    }
    
    private func setupPerformanceMonitoring() {
        performanceMonitor = PerformanceMonitor()
        performanceMonitor?.startMonitoring()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // Update container bounds
        videoContainerView?.frame = bounds
        
        // Force VLC to redraw if playing
        if let player = mediaPlayer, player.isPlaying {
            DispatchQueue.main.async {
                player.drawable = self.videoContainerView
            }
        }
    }
    
    // MARK: - Playback Control Methods
    
    func play(url: String, username: String? = nil, password: String? = nil, networkCaching: Int = 150) {
        guard isSetupComplete else {
            print("❌ Player not ready yet")
            return
        }
        
        // Stop current playback if any
        if mediaPlayer?.isPlaying == true {
            stop()
        }
        
        // Build authenticated URL
        let authenticatedURL = buildAuthenticatedURL(url: url, username: username, password: password)
        
        guard let mediaURL = URL(string: authenticatedURL) else {
            print("❌ Invalid URL: \(authenticatedURL)")
            return
        }
        
        currentStreamURL = authenticatedURL
        
        print("🎬 Starting stream: \(url)")
        
        // Create VLC Media with optimizations
        media = VLCMedia(url: mediaURL)
        guard let media = media else {
            print("❌ Failed to create VLC media")
            return
        }
        
        // Apply enhanced stream optimizations (SOFTWARE RENDERING)
        applyStreamOptimizations(media: media, caching: networkCaching)
        
        // Configure player and start playback
        mediaPlayer?.media = media
        
        // Ensure proper drawable setup
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.mediaPlayer?.drawable = self.videoContainerView
            self.mediaPlayer?.play()
            
            // Setup PiP after stream stabilizes
            self.setupPiPAfterDelay()
        }
    }
    
    private func buildAuthenticatedURL(url: String, username: String?, password: String?) -> String {
        guard let username = username?.trimmingCharacters(in: .whitespacesAndNewlines),
              let password = password?.trimmingCharacters(in: .whitespacesAndNewlines),
              !username.isEmpty, !password.isEmpty else { 
            return url 
        }
        
        if let urlComponents = URLComponents(string: url) {
            let components = urlComponents
            var urlString = "\(components.scheme ?? "rtsp")://"
            
            // Add authentication
            urlString += "\(username):\(password)@"
            urlString += "\(components.host ?? "")"
            
            if let port = components.port {
                urlString += ":\(port)"
            }
            
            urlString += components.path
            
            // Add query parameters if any
            if let query = components.query {
                urlString += "?\(query)"
            }
            
            return urlString
        }
        
        return url
    }
    
    private func applyStreamOptimizations(media: VLCMedia, caching: Int) {
        // Update caching values based on user preference
        var options = lowLatencyOptions
        options["network-caching"] = "\(caching)"
        options["rtsp-caching"] = "\(caching)"
        options["tcp-caching"] = "\(caching)"
        options["realrtsp-caching"] = "\(caching)"
        options["live-caching"] = "\(caching)"
        
        // Apply all optimizations
        for (key, value) in options {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
        
        // Additional RTSP-specific optimizations
        media.addOption("--intf=dummy")
        media.addOption("--no-network-synchronisation")
        media.addOption("--video-filter=")
        media.addOption("--deinterlace=0")
        media.addOption("--no-spu")
        media.addOption("--no-osd")
        
        // SOFTWARE RENDERING - 하드웨어 디코딩 비활성화
        // REMOVED: media.addOption("--avcodec-hw=videotoolbox")
        // REMOVED: media.addOption("--videotoolbox-temporal-deinterlacing")
        
        print("⚡ Applied SOFTWARE RENDERING optimizations with \(caching)ms caching (PiP compatible)")
    }
    
    private func setupPiPAfterDelay() {
        // Wait for stream to stabilize before setting up PiP
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.setupPiP()
        }
    }
    
    private func setupPiP() {
        guard let mediaPlayer = mediaPlayer,
              let containerView = videoContainerView,
              mediaPlayer.isPlaying,
              !isPiPConnected else { 
            print("⚠️ Cannot setup PiP - requirements not met")
            return 
        }
        
        print("🔗 Setting up enhanced PiP with SOFTWARE RENDERING...")
        
        // Connect PiP manager to VLC player
        pipManager.connectToVLCPlayer(mediaPlayer, containerView: containerView)
        isPiPConnected = true
        
        print("✅ Enhanced PiP setup completed (software rendering mode)")
    }
    
    // MARK: - Playback Control
    
    func stop() {
        print("⏹️ Stopping playback...")
        
        // Clean up PiP first
        if isPiPConnected {
            pipManager.stopPiP()
            isPiPConnected = false
        }
        
        // Stop VLC player
        mediaPlayer?.stop()
        media = nil
        currentStreamURL = nil
        streamInfo = nil
        
        // Clean up video container
        videoContainerView?.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        
        print("✅ Playback stopped and cleaned up")
    }
    
    func pause() {
        mediaPlayer?.pause()
        print("⏸️ Playback paused")
    }
    
    func resume() {
        mediaPlayer?.play()
        print("▶️ Playback resumed")
    }
    
    func setVolume(_ volume: Int32) {
        mediaPlayer?.audio?.volume = volume
    }
    
    func isPlaying() -> Bool {
        return mediaPlayer?.isPlaying ?? false
    }
    
    // MARK: - Advanced Features
    
    func updateNetworkCaching(_ caching: Int) {
        guard let currentURL = currentStreamURL else { return }
        
        print("🔄 Updating network caching to \(caching)ms")
        
        let wasPlaying = isPlaying()
        if wasPlaying {
            stop()
            
            // Restart with new settings after brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.play(url: currentURL, networkCaching: caching)
            }
        }
    }
    
    func getStreamInfo() -> StreamInfo? {
        guard let mediaPlayer = mediaPlayer, mediaPlayer.isPlaying else { return nil }
        
        var info = StreamInfo()
        
        // Video information
        let videoSize = mediaPlayer.videoSize
        info.resolution = CGSize(width: CGFloat(videoSize.width), height: CGFloat(videoSize.height))
        info.videoCodec = detectVideoCodec()
        
        // Audio information
        if let audioTracks = mediaPlayer.audioTrackNames as? [String],
           let audioTrack = audioTracks.first {
            info.audioTrack = audioTrack
        }
        
        // Playback information
        info.position = mediaPlayer.position
        info.time = TimeInterval(mediaPlayer.time.intValue / 1000)
        
        // State information
        info.isBuffering = mediaPlayer.state == .buffering
        info.droppedFrames = getDroppedFrames()
        
        // Performance metrics
        if let performance = performanceMonitor?.getCurrentMetrics() {
            info.cpuUsage = performance.cpuUsage
            info.memoryUsage = performance.memoryUsage
            info.fps = performance.fps
        }
        
        // PiP information
        info.isPiPActive = pipManager.isPiPActive
        info.isPiPPossible = pipManager.isPiPPossible
        
        self.streamInfo = info
        
        // Trigger callback
        onStreamInfoUpdate?(info)
        
        return info
    }
    
    private func detectVideoCodec() -> String {
        if let media = media {
            let url = media.url?.absoluteString ?? ""
            if url.contains("h264") || url.contains("avc") {
                return "H.264/AVC"
            } else if url.contains("h265") || url.contains("hevc") {
                return "H.265/HEVC"
            }
        }
        
        // Try to detect from stream metadata if available
        if let player = mediaPlayer {
            // Check for video tracks information
            if player.numberOfVideoTracks > 0 {
                return "H.264/AVC" // Most common for RTSP
            }
        }
        
        return "Unknown"
    }
    
    private func getDroppedFrames() -> Int {
        // VLC doesn't expose dropped frames directly
        // Could implement custom frame counting if needed
        return 0
    }
    
    // MARK: - Enhanced PiP Control
    
    func startPictureInPicture() {
        guard isPiPConnected else {
            setupPiP()
            return
        }
        
        pipManager.startPiP()
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
    
    var canStartPiP: Bool {
        return pipManager.canStartPiP
    }
    
    var pipStatus: String {
        return pipManager.pipStatus
    }
    
    // MARK: - Cleanup
    
    deinit {
        print("🧹 Cleaning up RTSPPlayerUIView...")
        
        performanceMonitor?.stopMonitoring()
        stop()
        
        // Clean up constraints
        NSLayoutConstraint.deactivate(containerViewConstraints)
        containerViewConstraints.removeAll()
        
        videoContainerView?.removeFromSuperview()
        videoContainerView = nil
        
        mediaPlayer = nil
        
        print("✅ RTSPPlayerUIView cleanup completed")
    }
}

// MARK: - VLCMediaPlayerDelegate
extension RTSPPlayerUIView: VLCMediaPlayerDelegate {
    
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        DispatchQueue.main.async { [weak self] in
            self?.handlePlayerStateChange(player)
        }
    }
    
    private func handlePlayerStateChange(_ player: VLCMediaPlayer) {
        switch player.state {
        case .opening:
            print("🔄 VLC: Opening stream...")
            streamInfo?.state = "Opening"
            
        case .buffering:
            let bufferPercent = player.position * 100
            print("📡 VLC: Buffering... \(Int(bufferPercent))%")
            streamInfo?.state = "Buffering"
            
        case .playing:
            let videoSize = player.videoSize
            print("▶️ VLC: Playing - Video size: \(videoSize)")
            streamInfo?.state = "Playing"
            
            // Ensure proper rendering
            videoContainerView?.setNeedsLayout()
            setNeedsLayout()
            
            // Setup PiP if not already connected
            if !isPiPConnected {
                setupPiPAfterDelay()
            }
            
        case .paused:
            print("⏸️ VLC: Paused")
            streamInfo?.state = "Paused"
            
        case .stopped:
            print("⏹️ VLC: Stopped")
            streamInfo?.state = "Stopped"
            isPiPConnected = false
            
        case .error:
            print("❌ VLC: Error occurred")
            streamInfo?.state = "Error"
            streamInfo?.lastError = "Stream playback error"
            isPiPConnected = false
            
        case .ended:
            print("🏁 VLC: Ended")
            streamInfo?.state = "Ended"
            isPiPConnected = false
            
        case .esAdded:
            print("📺 VLC: Elementary stream added")
            streamInfo?.state = "ES Added"
            
        @unknown default:
            print("❓ VLC: Unknown state: \(player.state.rawValue)")
        }
        
        // Update stream info
        if let info = getStreamInfo() {
            onStreamInfoUpdate?(info)
        }
    }
    
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        if let player = aNotification.object as? VLCMediaPlayer {
            streamInfo?.time = TimeInterval(player.time.intValue / 1000)
            streamInfo?.position = player.position
        }
    }
}

// MARK: - Enhanced Stream Info Model
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
    
    // Enhanced PiP information
    var isPiPActive: Bool = false
    var isPiPPossible: Bool = false
    
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
    
    var pipStatusDescription: String {
        if isPiPActive {
            return "PiP Active"
        } else if isPiPPossible {
            return "PiP Ready"
        } else {
            return "PiP Unavailable"
        }
    }
}

// MARK: - Enhanced Performance Monitor
class PerformanceMonitor {
    private var timer: Timer?
    private var lastCPUInfo: host_cpu_load_info?
    private var startTime: CFAbsoluteTime = 0
    
    struct Metrics {
        var cpuUsage: Float = 0.0
        var memoryUsage: Float = 0.0
        var fps: Float = 0.0
        var uptime: TimeInterval = 0.0
    }
    
    func startMonitoring() {
        startTime = CFAbsoluteTimeGetCurrent()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
        print("📊 Performance monitoring started")
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        print("📊 Performance monitoring stopped")
    }
    
    func getCurrentMetrics() -> Metrics {
        var metrics = Metrics()
        
        metrics.cpuUsage = getCPUUsage()
        metrics.memoryUsage = getMemoryUsage()
        metrics.fps = 30.0 // Estimated for RTSP streams
        metrics.uptime = CFAbsoluteTimeGetCurrent() - startTime
        
        return metrics
    }
    
    private func updateMetrics() {
        let metrics = getCurrentMetrics()
        
        // Log metrics occasionally for debugging
        if Int(metrics.uptime) % 30 == 0 {
            print("📊 Performance - CPU: \(String(format: "%.1f", metrics.cpuUsage))%, Memory: \(String(format: "%.1f", metrics.memoryUsage))MB")
        }
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
            return Float(info.virtual_size) / Float(1024 * 1024) // Convert to MB
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
            return Float(info.resident_size) / Float(1024 * 1024) // Convert to MB
        }
        
        return 0.0
    }
    
    deinit {
        stopMonitoring()
    }
}

// MARK: - Enhanced SwiftUI Wrapper
struct RTSPPlayerView: UIViewRepresentable {
    @Binding var url: String
    @Binding var isPlaying: Bool
    var username: String?
    var password: String?
    var networkCaching: Int = 150
    
    var onStreamInfo: ((StreamInfo) -> Void)?
    var onPiPStatusChanged: ((Bool) -> Void)?
    
    func makeUIView(context: Context) -> RTSPPlayerUIView {
        let playerView = RTSPPlayerUIView()
        
        // Set up callbacks
        playerView.onStreamInfoUpdate = onStreamInfo
        playerView.onPiPStatusUpdate = onPiPStatusChanged
        
        // Set PiP delegate
        PictureInPictureManager.shared.delegate = context.coordinator
        
        return playerView
    }
    
    func updateUIView(_ uiView: RTSPPlayerUIView, context: Context) {
        // Update callbacks
        uiView.onStreamInfoUpdate = onStreamInfo
        uiView.onPiPStatusUpdate = onPiPStatusChanged
        
        // Handle playback state changes
        if isPlaying {
            if !uiView.isPlaying() && !url.isEmpty {
                uiView.play(url: url, username: username, password: password, networkCaching: networkCaching)
            }
        } else {
            if uiView.isPlaying() {
                uiView.pause()
            }
        }
        
        // Update network caching if needed
        if networkCaching != 150 { // Default value check
            uiView.updateNetworkCaching(networkCaching)
        }
        
        // Provide stream info callback
        if let info = uiView.getStreamInfo() {
            onStreamInfo?(info)
        }
        
        // Provide PiP status callback
        onPiPStatusChanged?(uiView.isPiPActive)
    }
    
    static func dismantleUIView(_ uiView: RTSPPlayerUIView, coordinator: Coordinator) {
        uiView.stop()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PictureInPictureManagerDelegate {
        let parent: RTSPPlayerView
        
        init(_ parent: RTSPPlayerView) {
            self.parent = parent
        }
        
        func pipDidStart() {
            print("🎬 PiP started from coordinator")
            parent.onPiPStatusChanged?(true)
        }
        
        func pipDidStop() {
            print("🎬 PiP stopped from coordinator")
            parent.onPiPStatusChanged?(false)
        }
        
        func pipWillStart() {
            print("🎬 PiP will start")
        }
        
        func pipWillStop() {
            print("🎬 PiP will stop")
        }
        
        func pipRestoreUserInterface(completionHandler: @escaping (Bool) -> Void) {
            print("🔄 Restoring user interface")
            
            DispatchQueue.main.async {
                // Restore UI here if needed
                completionHandler(true)
            }
        }
    }
}
