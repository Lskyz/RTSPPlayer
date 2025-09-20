import SwiftUI
import AVFoundation

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
        }
    }
    
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            print("📱 App moved to background")
        case .inactive:
            print("📱 App is inactive")
        case .active:
            print("📱 App is active")
        @unknown default:
            break
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    
    func application(_ application: UIApplication, 
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // GStreamer 초기화
        GStreamerBackend.initializeGStreamer()
        
        // 오디오 세션 설정
        configureAudioSession()
        
        // 화면 자동 잠금 방지
        UIApplication.shared.isIdleTimerDisabled = true
        
        print("✅ App initialized with GStreamer")
        return true
    }
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowAirPlay])
            try audioSession.setActive(true)
            print("🔊 Audio session configured")
        } catch {
            print("❌ Audio session error: \(error)")
        }
    }
}
