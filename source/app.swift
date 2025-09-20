import SwiftUI
import AVKit
import MobileVLCKit

@main
struct RTSPPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark) // 다크 모드 선호
                .onChange(of: scenePhase) { newPhase in
                    handleScenePhaseChange(newPhase)
                }
        }
    }
    
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            print("App moved to background")
            // PiP가 활성화되어 있지 않으면 스트림 일시정지 고려
            
        case .inactive:
            print("App is inactive")
            
        case .active:
            print("App is active")
            // 필요시 스트림 재개
            
        @unknown default:
            break
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, UIApplicationDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // 오디오 세션 설정 (백그라운드 재생 및 PiP를 위해)
        configureAudioSession()
        
        // VLC 로깅 설정
        configureVLCLogging()
        
        // 화면 자동 잠금 방지 (비디오 재생 중)
        UIApplication.shared.isIdleTimerDisabled = true
        
        return true
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // 모든 방향 지원
        return .all
    }
    
    // MARK: - Private Methods
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // 백그라운드 재생을 위한 카테고리 설정
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            
            // 오디오 세션 활성화
            try audioSession.setActive(true)
            
            print("Audio session configured successfully")
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    private func configureVLCLogging() {
        // VLC 로깅 설정 (deprecated 메서드 제거)
        #if DEBUG
        // 디버그 모드에서는 콘솔 로거 사용
        let consoleLogger = VLCConsoleLogger()
        VLCLibrary.shared().setLogger(consoleLogger)
        #endif
    }
}

// MARK: - Scene Delegate (필요시 사용)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    
    var window: UIWindow?
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // 씬 연결 시 초기 설정
        guard let _ = (scene as? UIWindowScene) else { return }
        
        // 상태바 스타일은 Info.plist에서 설정
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {
        // 씬 연결 해제 시 정리 작업
    }
    
    func sceneDidBecomeActive(_ scene: UIScene) {
        // 씬이 활성화될 때
    }
    
    func sceneWillResignActive(_ scene: UIScene) {
        // 씬이 비활성화될 때
    }
    
    func sceneWillEnterForeground(_ scene: UIScene) {
        // 포그라운드 진입 시
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        // 백그라운드 진입 시
        // PiP가 활성화되어 있지 않으면 리소스 절약을 위해 일시정지 고려
    }
}

// MARK: - Extensions
extension UIApplication {
    /// 현재 활성 윈도우 씬 가져오기
    var currentScene: UIWindowScene? {
        connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
    }
    
    /// 현재 키 윈도우 가져오기
    var currentKeyWindow: UIWindow? {
        currentScene?.windows.first { $0.isKeyWindow }
    }
}
