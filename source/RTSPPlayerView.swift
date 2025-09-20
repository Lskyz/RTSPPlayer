import UIKit
import SwiftUI
import VLCKitSPM
import AVKit
import CoreMedia
import CoreVideo

// MARK: - RTSP Player UIView with Direct VLC Frame Processing
class RTSPPlayerUIView: UIView {
    
    // VLC Components
    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?
    
    // Video Layer for proper rendering
    private var videoLayer: CALayer?
    private var videoContainerView: UIView?
    
    // PiP Components
    private let pipManager = PictureInPictureManager.shared
    private var isPiPEnabled = false
    
    // Stream Info
    private var currentStreamURL: String?
    private var streamInfo: StreamInfo?
    
    // Performance Monitoring
    private var performanceMonitor: PerformanceMonitor?
    
    // Layout constraints
    private var containerViewConstraints: [NSLayoutConstraint] = []
    
    // Low Latency Options
    private let lowLatencyOptions: [String: String] = [
        "network-caching": "150",
        "rtsp-caching": "150",
        "tcp-caching": "150",
        "realrtsp-caching": "150",
        "clock-jitter": "150",
        "rtsp-tcp": "",
        "avcodec-hw": "videotoolbox",
        "clock-synchro": "0",
        "avcodec-skiploopfilter": "0",
        "avcodec-skip-frame": "0",
        "avcodec-skip-idct": "0",
        "avcodec-threads": "4",
        "sout-mux-caching": "10",
        "live-caching": "150"
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
        
        // Create video container view
        setupVideoContainer()
        
        // Initialize VLC Media Player with video callbacks
        mediaPlayer = VLCMediaPlayer()
        
        // CRITICAL: Setup direct video frame callbacks
        setupDirectVideoFrameCallbacks()
        
        // Set drawable to the container view
        mediaPlayer?.drawable = videoContainerView
        mediaPlayer?.audio?.volume = 100
        mediaPlayer?.delegate = self
        
        // Configure VLC for proper rendering
        configureVLCPlayer()
        
        print("VLC Player initialized with direct frame callbacks")
    }
    
    private func setupVideoContainer() {
        // Create container view for video
        videoContainerView = UIView()
        videoContainerView?.backgroundColor = .black
        videoContainerView?.translatesAutoresizingMaskIntoConstraints = false
        
        guard let containerView = videoContainerView else { return }
        
        addSubview(containerView)
        
        // Set up constraints to fill the entire view
        containerViewConstraints = [
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        
        NSLayoutConstraint.activate(containerViewConstraints)
        
        print("Video container setup completed")
    }
    
    // MARK: - CRITICAL: Direct VLC Video Frame Callbacks
    private func setupDirectVideoFrameCallbacks() {
        guard let player = mediaPlayer else { return }
        
        // Set video format callback
        player.setVideoFormatCallback { (chroma, width, height, pitches, lines) -> Unmanaged<AnyObject>? in
            print("VLC Video format: \(String(cString: chroma!)) \(width)x\(height)")
            
            // Configure for BGRA format which is optimal for iOS
            let format = "BGRA"
            strcpy(chroma, format)
            
            return nil
        }
        
        // Set video callbacks for direct frame access
        player.setVideoCallbacks(
            lock: { (opaque, planes) -> UnsafeMutableRawPointer? in
                // Lock callback - prepare buffer for writing
                return opaque
            },
            unlock: { (opaque, picture, planes) in
                // Unlock callback - frame is ready
                guard let opaque = opaque else { return }
                
                let playerView = Unmanaged<RTSPPlayerUIView>.fromOpaque(opaque).takeUnretainedValue()
                playerView.processDirectVideoFrame(picture: picture, planes: planes)
            },
            display: { (opaque, picture) in
                // Display callback - frame should be displayed
                // This is called after unlock
            },
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )
        
        print("Direct VLC video callbacks configured")
    }
    
    // MARK: - Direct Frame Processing
    private func processDirectVideoFrame(picture: UnsafeMutableRawPointer?, planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) {
        // This method is called directly from VLC with raw frame data
        guard let picture = picture, let planes = planes else { return }
        
        // Get video dimensions from VLC
        guard let player = mediaPlayer else { return }
        let videoSize = player.videoSize
        
        guard videoSize.width > 0 && videoSize.height > 0 else { return }
        
        let width = Int(videoSize.width)
        let height = Int(videoSize.height)
        
        // Create CVPixelBuffer from VLC frame data
        if let pixelBuffer = createPixelBufferFromVLCFrame(
            planes: planes,
            width: width,
            height: height
        ) {
            // Convert to CMSampleBuffer and send to PiP
            if let sampleBuffer = createSampleBufferFromPixelBuffer(pixelBuffer, width: width, height: height) {
                DispatchQueue.main.async { [weak self] in
                    self?.pipManager.receivedDirectFrame(sampleBuffer)
                }
            }
        }
    }
    
    private func createPixelBufferFromVLCFrame(
        planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            print("Failed to create pixel buffer")
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer),
              let sourceData = planes[0] else {
            print("Failed to get buffer addresses")
            return nil
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let sourceBytes = width * 4 // BGRA = 4 bytes per pixel
        
        // Copy frame data from VLC to CVPixelBuffer
        for row in 0..<height {
            let sourceRow = sourceData.advanced(by: row * sourceBytes)
            let destRow = baseAddress.advanced(by: row * bytesPerRow)
            memcpy(destRow, sourceRow, sourceBytes)
        }
        
        return buffer
    }
    
    private func createSampleBufferFromPixelBuffer(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard status == noErr, let format = formatDescription else {
            print("Failed to create format description")
            return nil
        }
        
        // Use host time for proper synchronization
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let duration = CMTime(value: 1, timescale: 30) // 30 FPS
        
        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: hostTime,
            decodeTimeStamp: .invalid
        )
        
        var sampleBuffer: CMSampleBuffer?
        let result = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        guard result == noErr else {
            print("Failed to create sample buffer: \(result)")
            return nil
        }
        
        return sampleBuffer
    }
    
    private func configureVLCPlayer() {
        guard let player = mediaPlayer else { return }
        
        // Configure video aspect ratio and scaling
        player.videoAspectRatio = nil // Let VLC auto-detect
        
        // Enable hardware decoding
        if let videoView = videoContainerView {
            videoView.contentMode = .scaleAspectFit
        }
        
        print("VLC Player configured for direct frame capture")
    }
    
    private func setupPerformanceMonitoring() {
        performanceMonitor = PerformanceMonitor()
        performanceMonitor?.startMonitoring()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // Update video container bounds
        videoContainerView?.frame = bounds
        
        // Force VLC to redraw if playing
        if let player = mediaPlayer, player.isPlaying {
            // Trigger a layout update
            DispatchQueue.main.async {
                player.drawable = self.videoContainerView
            }
        }
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
        
        // Ensure proper setup before playing
        DispatchQueue.main.async { [weak self] in
            self?.mediaPlayer?.drawable = self?.videoContainerView
            self?.mediaPlayer?.play()
            
            print("Starting stream with direct frame capture: \(url)")
            
            // Setup PiP after a delay
            self?.setupPiPAfterDelay()
        }
    }
    
    private func buildAuthenticatedURL(url: String, username: String?, password: String?) -> String {
        guard let username = username, let password = password else { return url }
        
        if let urlComponents = URLComponents(string: url) {
            let components = urlComponents
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
        
        // Additional codec optimizations for direct frame capture
        media.addOption("--intf=dummy")
        media.addOption("--no-audio-time-stretch")
        media.addOption("--no-network-synchronisation")
        media.addOption("--no-drop-late-frames")
        media.addOption("--no-skip-frames")
        media.addOption("--video-filter=")
        media.addOption("--deinterlace=0")
        
        // Force specific video output format for callbacks
        media.addOption("--vout=ios_window_provider")
        
        print("Applied optimizations with caching: \(caching)ms for direct frame capture")
    }
    
    private func setupPiPAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.setupPiP()
        }
    }
    
    private func setupPiP() {
        guard let mediaPlayer = mediaPlayer,
              let containerView = videoContainerView,
              mediaPlayer.isPlaying,
              !isPiPEnabled else { return }
        
        // Connect PiP manager to the video container view
        pipManager.connectToVLCPlayerDirect(mediaPlayer, containerView: containerView)
        isPiPEnabled = true
        
        print("PiP setup completed with direct frame capture")
    }
    
    func stop() {
        mediaPlayer?.stop()
        media = nil
        currentStreamURL = nil
        isPiPEnabled = false
        streamInfo = nil
        
        // Clean up video container
        videoContainerView?.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        
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
        
        // Audio info
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
        if let media = media {
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
        
        // Clean up constraints
        NSLayoutConstraint.deactivate(containerViewConstraints)
        containerViewConstraints.removeAll()
        
        videoContainerView?.removeFromSuperview()
        videoContainerView = nil
        
        mediaPlayer = nil
        print("RTSPPlayerUIView deinitialized")
    }
}

// MARK: - VLCMediaPlayerDelegate
extension RTSPPlayerUIView: VLCMediaPlayerDelegate {
    
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        switch player.state {
        case .opening:
            print("VLC: Opening stream...")
            streamInfo?.state = "Opening"
            
        case .buffering:
            let bufferPercent = player.position * 100
            print("VLC: Buffering... \(Int(bufferPercent))%")
            streamInfo?.state = "Buffering"
            
        case .playing:
            print("VLC: Playing with direct frame capture - Video size: \(player.videoSize)")
            streamInfo?.state = "Playing"
            
            // Ensure proper video rendering
            DispatchQueue.main.async { [weak self] in
                self?.videoContainerView?.setNeedsLayout()
                self?.setNeedsLayout()
                
                // Setup PiP if not done
                if self?.isPiPEnabled == false {
                    self?.setupPiPAfterDelay()
                }
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
    
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        if let player = aNotification.object as? VLCMediaPlayer {
            streamInfo?.time = TimeInterval(player.time.intValue / 1000)
            streamInfo?.position = player.position
        }
    }
}

// MARK: - Stream Info Model (unchanged)
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

// MARK: - Performance Monitor (unchanged)
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
        
        metrics.cpuUsage = getCPUUsage()
        metrics.memoryUsage = getMemoryUsage()
        metrics.fps = 30.0 // Placeholder
        
        return metrics
    }
    
    private func updateMetrics() {
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
            return Float(info.resident_size) / Float(1024 * 1024)
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
            return Float(info.resident_size) / Float(1024 * 1024 * 1024)
        }
        
        return 0.0
    }
    
    deinit {
        stopMonitoring()
    }
}

// MARK: - SwiftUI Wrapper (unchanged)
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
        
        uiView.updateNetworkCaching(networkCaching)
        
        if let info = uiView.getStreamInfo() {
            onStreamInfo?(info)
        }
        
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
            parent.onPiPStatusChanged?(true)
        }
        
        func pipDidStop() {
            parent.onPiPStatusChanged?(false)
        }
        
        func pipWillStart() {
        }
        
        func pipWillStop() {
        }
        
        func pipRestoreUserInterface(completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }
    }
}

// MARK: - Helper Extensions
extension RTSPPlayerView {
    
    func onStreamInfoUpdate(_ callback: @escaping (StreamInfo) -> Void) -> RTSPPlayerView {
        var view = self
        view.onStreamInfo = callback
        return view
    }
    
    func onPiPStatusUpdate(_ callback: @escaping (Bool) -> Void) -> RTSPPlayerView {
        var view = self
        view.onPiPStatusChanged = callback
        return view
    }
}
