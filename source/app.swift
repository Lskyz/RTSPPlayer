import SwiftUI
import AVKit
import VLCKitSPM
import UIKit

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
            print("App moved to background - System PiP should continue")
            // System PiP는 백그라운드에서도 계속 실행됨
            
        case .inactive:
            print("App is inactive")
            
        case .active:
            print("App is active")
            // 필요시 스트림 상태 확인
            
        @unknown default:
            break
        }
    }
}

// MARK: - Enhanced App Delegate for System PiP
class AppDelegate: NSObject, UIApplicationDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // System PiP를 위한 오디오 세션 설정
        configureAudioSessionForSystemPiP()
        
        // VLC 로깅 설정
        configureVLCLogging()
        
        // 화면 자동 잠금 방지 (비디오 재생 중)
        UIApplication.shared.isIdleTimerDisabled = true
        
        // Background Tasks 등록
        registerBackgroundTasks()
        
        print("App launched with System PiP support")
        
        return true
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // 모든 방향 지원
        return .all
    }
    
    // MARK: - Background App Refresh
    func applicationDidEnterBackground(_ application: UIApplication) {
        print("App entered background - Background modes active")
        
        // System PiP가 활성화된 상태라면 백그라운드에서 계속 실행
        let pipManager = PictureInPictureManager.shared
        if pipManager.isPiPActive {
            print("System PiP active - maintaining background execution")
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        print("App will enter foreground")
        
        // 오디오 세션 재활성화
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            print("Audio session reactivated")
        } catch {
            print("Failed to reactivate audio session: \(error)")
        }
    }
    
    // MARK: - Private Methods
    
    private func configureAudioSessionForSystemPiP() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // System PiP를 위한 강화된 오디오 세션 설정
            try audioSession.setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.mixWithOthers, .allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
            )
            
            // 오디오 세션 활성화
            try audioSession.setActive(true)
            
            print("Enhanced audio session configured for System PiP")
            
            // 오디오 인터럽션 관찰
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleAudioInterruption(notification)
            }
            
        } catch {
            print("Failed to configure audio session for System PiP: \(error)")
        }
    }
    
    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            print("Audio interruption began - System PiP may pause")
            
        case .ended:
            print("Audio interruption ended - System PiP resuming")
            
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    // 오디오 세션 재활성화
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        print("Audio session resumed after interruption")
                    } catch {
                        print("Failed to resume audio session: \(error)")
                    }
                }
            }
            
        @unknown default:
            break
        }
    }
    
    private func configureVLCLogging() {
        #if DEBUG
        // 디버그 모드에서는 상세 로깅
        let consoleLogger = VLCConsoleLogger()
        VLCLibrary.shared().setLogger(consoleLogger)
        print("VLC debug logging enabled")
        #else
        // 릴리즈 모드에서는 최소 로깅
        print("VLC logging configured for release")
        #endif
    }
    
    private func registerBackgroundTasks() {
        // Background App Refresh 등록 (iOS 13+)
        if #available(iOS 13.0, *) {
            // Background processing identifier는 Info.plist에 등록되어야 함
            let identifier = "com.sky.RTSPPlayer.background-refresh"
            
            let success = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier,
                using: nil
            ) { task in
                self.handleBackgroundRefresh(task as! BGAppRefreshTask)
            }
            
            if success {
                print("Background task registered successfully")
            } else {
                print("Failed to register background task")
            }
        }
    }
    
    @available(iOS 13.0, *)
    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        print("Background refresh task executed")
        
        // System PiP 상태 확인 및 유지
        let pipManager = PictureInPictureManager.shared
        if pipManager.isPiPActive {
            print("Maintaining System PiP in background")
            // 필요한 경우 여기서 추가 작업 수행
        }
        
        // 작업 완료 표시
        task.setTaskCompleted(success: true)
    }
    
    // MARK: - Cleanup
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Scene Delegate for System PiP
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    
    var window: UIWindow?
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        // System PiP를 위한 윈도우 설정
        setupWindowForSystemPiP(windowScene: windowScene)
        
        print("Scene connected with System PiP support")
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {
        print("Scene disconnected")
    }
    
    func sceneDidBecomeActive(_ scene: UIScene) {
        print("Scene became active")
        
        // System PiP 상태 확인
        let pipManager = PictureInPictureManager.shared
        if pipManager.isPiPActive {
            print("Scene active with System PiP running")
        }
    }
    
    func sceneWillResignActive(_ scene: UIScene) {
        print("Scene will resign active")
    }
    
    func sceneWillEnterForeground(_ scene: UIScene) {
        print("Scene will enter foreground")
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        print("Scene entered background")
        
        // System PiP가 활성화되어 있으면 백그라운드 실행 계속
        let pipManager = PictureInPictureManager.shared
        if pipManager.isPiPActive {
            print("System PiP active - background execution maintained")
        }
    }
    
    // MARK: - Private Methods
    
    private func setupWindowForSystemPiP(windowScene: UIWindowScene) {
        // System PiP를 위한 윈도우 최적화 설정
        if let window = windowScene.windows.first {
            // 윈도우 레벨 설정 (필요한 경우)
            window.windowLevel = UIWindow.Level.normal
            
            print("Window configured for System PiP")
        }
    }
}

// MARK: - Background Task Scheduler Import
import BackgroundTasks

// MARK: - Extensions for System PiP
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
    
    /// System PiP 상태 확인
    var isSystemPiPActive: Bool {
        return PictureInPictureManager.shared.isPiPActive
    }
}
