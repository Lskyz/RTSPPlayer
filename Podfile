platform :ios, '15.0'
use_frameworks!

target 'RTSPPlayer' do
  # GStreamer iOS Framework
  pod 'GStreamer-iOS', '~> 1.22.0'
  
  # 또는 직접 프레임워크 추가 방법:
  # 1. GStreamer.framework를 다운로드
  # 2. 프로젝트에 수동으로 추가
  # 3. Framework Search Paths 설정
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      config.build_settings['ENABLE_BITCODE'] = 'NO'
      
      # GStreamer 특정 설정
      config.build_settings['OTHER_LDFLAGS'] ||= ['$(inherited)']
      config.build_settings['OTHER_LDFLAGS'] << '-ObjC'
      
      # 아키텍처 설정
      config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'arm64'
    end
  end
end
