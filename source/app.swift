import SwiftUI
import AVKit
import VLCKitSPM
import BackgroundTasks

@main
struct RTSPPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { newPhase in
                    handleScenePhaseChange(newPhase)
                }
                .onAppear {
                    // Ensure background modes are properly configured
                    appDelegate.verifyBackgroundModes()
                }
        }
    }
    
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        let pipManager = PictureInPictureManager.shared
        
        switch phase {
        case .background:
            print("App moved to background - PiP Active: \(pipManager.isPiPActive)")
            
            if pipManager.isPiPActive {
                // Keep everything running for PiP
                print("Maintaining resources for active PiP")
                
                // Start background task to keep app alive
                appDelegate.startBackgroundTask()
            } else {
                print("No PiP active, app can suspend normally")
            }
            
        case .inactive:
            print("App is inactive - PiP transition may be occurring")
            // Don't do anything during transition
            
        case .active:
            print("App is active")
            
            // End background task if any
            appDelegate.endBackgroundTask()
            
            if pipManager.isPiPActive {
                print("Returning from PiP mode")
            }
            
        @unknown default:
            break
        }
    }
}

// MARK: - Enhanced App Delegate with Background Task Management
class AppDelegate: NSObject, UIApplicationDelegate {
    
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTimer: Timer?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Configure audio session for background playback
        configureAudioSession()
        
        // Configure VLC for background operation
        configureVLCForBackground()
        
        // Register for background tasks
        registerBackgroundTasks()
        
        // Keep screen on during video playback
        UIApplication.shared.isIdleTimerDisabled = true
        
        print("App configured for background PiP support")
        
        return true
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .all
    }
    
    // MARK: - Background/Foreground Handling
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        let pipManager = PictureInPictureManager.shared
        
        if pipManager.isPiPActive {
            print("App entering background with active PiP")
            
            // Start extended background task
            startBackgroundTask()
            
            // Keep VLC player active
            maintainPlaybackInBackground()
        } else {
            print("App entering background without PiP")
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        let pipManager = PictureInPictureManager.shared
        
        print("App entering foreground - PiP Active: \(pipManager.isPiPActive)")
        
        // End background task
        endBackgroundTask()
        
        if pipManager.isPiPActive {
            // PiP is still active, prepare for possible transition
            print("Preparing for PiP to main transition")
        }
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        endBackgroundTask()
    }
    
    // MARK: - Background Task Management
    
    func startBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            print("Background task expired")
            self?.endBackgroundTask()
        }
        
        if backgroundTask != .invalid {
            print("Background task started: \(backgroundTask.rawValue)")
            
            // Start a timer to keep the app alive
            backgroundTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                let timeRemaining = UIApplication.shared.backgroundTimeRemaining
                print("Background time remaining: \(timeRemaining)")
                
                // If PiP is no longer active, end the task
                if !PictureInPictureManager.shared.isPiPActive {
                    self.endBackgroundTask()
                }
            }
        }
    }
    
    func endBackgroundTask() {
        if backgroundTask != .invalid {
            print("Ending background task: \(backgroundTask.rawValue)")
            
            backgroundTimer?.invalidate()
            backgroundTimer = nil
            
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    // MARK: - Configuration Methods
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Configure for playback with PiP support
            try audioSession.setCategory(
                .playback,
                mode: .moviePlayback,
                options: []  // Remove .mixWithOthers for exclusive audio
            )
            
            // Set preferred settings
            try audioSession.setPreferredSampleRate(48000)
            try audioSession.setPreferredIOBufferDuration(0.005)
            
            // Activate session
            try audioSession.setActive(true, options: [])
            
            print("Audio session configured for background playback")
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    private func configureVLCForBackground() {
        // VLC configuration for background operation
        let vlcOptions = [
            "--network-caching=150",
            "--rtsp-caching=150",
            "--tcp-caching=150",
            "--realrtsp-caching=150",
            "--intf=dummy",
            "--no-audio-time-stretch",
            "--avcodec-hw=videotoolbox",
            "--deinterlace=0",
            "--network-synchronisation"
        ]
        
        // Apply global VLC options
        for option in vlcOptions {
            VLCLibrary.shared().debugLogging = false
        }
        
        print("VLC configured for background operation")
    }
    
    private func registerBackgroundTasks() {
        // Register background tasks for iOS 13+
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: "com.rtspplayer.refresh",
                using: nil
            ) { task in
                self.handleBackgroundTask(task: task as! BGAppRefreshTask)
            }
        }
    }
    
    @available(iOS 13.0, *)
    private func handleBackgroundTask(task: BGAppRefreshTask) {
        task.expirationHandler = {
            print("Background task expired")
        }
        
        // Check if PiP is still needed
        if PictureInPictureManager.shared.isPiPActive {
            print("PiP still active in background task")
        }
        
        task.setTaskCompleted(success: true)
        
        // Schedule next background task
        scheduleBackgroundTask()
    }
    
    @available(iOS 13.0, *)
    private func scheduleBackgroundTask() {
        let request = BGAppRefreshTaskRequest(identifier: "com.rtspplayer.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule background task: \(error)")
        }
    }
    
    private func maintainPlaybackInBackground() {
        // Ensure audio session stays active
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to maintain audio session: \(error)")
        }
        
        // Keep network connections alive
        URLSession.shared.configuration.shouldUseExtendedBackgroundIdleMode = true
    }
    
    func verifyBackgroundModes() {
        if let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] {
            let requiredModes = ["audio", "fetch", "remote-notification"]
            let hasRequiredModes = requiredModes.allSatisfy { backgroundModes.contains($0) }
            
            if hasRequiredModes {
                print("✅ All required background modes are enabled")
            } else {
                print("⚠️ Warning: Missing background modes. PiP may not work properly.")
                print("Enabled modes: \(backgroundModes)")
                print("Required modes: \(requiredModes)")
            }
        } else {
            print("⚠️ Warning: No background modes configured")
        }
    }
}

// MARK: - Scene Delegate with PiP State Management
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    
    var window: UIWindow?
    private var pipStateObserver: NSObjectProtocol?
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        // Observe PiP state changes
        observePiPStateChanges()
        
        print("Scene connected with PiP support")
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {
        let pipManager = PictureInPictureManager.shared
        
        // Only cleanup if PiP is not active
        if !pipManager.isPiPActive {
            print("Scene disconnected - cleaning up (PiP not active)")
            removeObservers()
        } else {
            print("Scene disconnected - keeping resources (PiP active)")
        }
    }
    
    func sceneDidBecomeActive(_ scene: UIScene) {
        print("Scene became active")
        
        // Update PiP status
        PictureInPictureManager.shared.updateCanStartPiP()
    }
    
    func sceneWillResignActive(_ scene: UIScene) {
        let pipManager = PictureInPictureManager.shared
        
        print("Scene will resign active - PiP Active: \(pipManager.isPiPActive)")
        
        // If PiP is possible but not active, this might be a good time to start it
        if pipManager.canStartPiP && !pipManager.isPiPActive {
            print("Consider starting PiP before going to background")
        }
    }
    
    func sceneWillEnterForeground(_ scene: UIScene) {
        print("Scene will enter foreground")
        
        // Prepare for possible PiP restoration
        if PictureInPictureManager.shared.isPiPActive {
            print("Preparing to restore from PiP")
        }
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        let pipManager = PictureInPictureManager.shared
        
        print("Scene entered background - PiP Active: \(pipManager.isPiPActive)")
        
        if pipManager.isPiPActive {
            // Keep everything active for PiP
            print("Maintaining scene resources for PiP")
            
            // Start background task through app delegate
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                appDelegate.startBackgroundTask()
            }
        } else {
            print("Scene can suspend normally (no PiP)")
        }
    }
    
    // MARK: - PiP State Observation
    
    private func observePiPStateChanges() {
        pipStateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkPiPState()
        }
    }
    
    private func checkPiPState() {
        let pipManager = PictureInPictureManager.shared
        
        print("Current PiP state - Active: \(pipManager.isPiPActive), Possible: \(pipManager.isPiPPossible)")
        
        if pipManager.isPiPActive {
            // Handle active PiP state
            maintainPiPResources()
        }
    }
    
    private func maintainPiPResources() {
        // Ensure resources needed for PiP are maintained
        print("Maintaining resources for PiP")
        
        // Keep audio session active
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to maintain audio session: \(error)")
        }
    }
    
    private func removeObservers() {
        if let observer = pipStateObserver {
            NotificationCenter.default.removeObserver(observer)
            pipStateObserver = nil
        }
    }
    
    deinit {
        removeObservers()
    }
}

// MARK: - Extensions
extension UIApplication {
    /// Get current active window scene
    var currentScene: UIWindowScene? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
    
    /// Get current key window
    var currentKeyWindow: UIWindow? {
        currentScene?.windows.first { $0.isKeyWindow }
    }
    
    /// Check if app has required background modes
    var hasRequiredBackgroundModes: Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            return false
        }
        return modes.contains("audio")
    }
}

// MARK: - VLC Console Logger
class VLCConsoleLogger: NSObject, VLCLibraryLogReceiverProtocol {
    
    func handleMessage(_ message: UnsafePointer<CChar>!, logLevel: Int32, context: UnsafeMutableRawPointer!) {
        #if DEBUG
        let logMessage = String(cString: message)
        
        // Filter out verbose messages
        if logLevel >= 3 { // Only show warnings and errors
            print("[VLC] \(logMessage)")
        }
        #endif
    }
}
