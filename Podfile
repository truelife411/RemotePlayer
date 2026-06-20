# RemotePlayer Podfile
# 依赖：MobileVLCKit (播放器内核) + AMSMB2 (SMB2/3) + Telegraph (本地 HTTP 代理)

platform :ios, '17.0'
use_frameworks!
inhibit_all_warnings!

target 'RemotePlayer' do
  # 全格式视频解码内核（使用本地已下载的 3.7.3）
  pod 'MobileVLCKit', :podspec => 'LocalPods/MobileVLCKit.podspec.json'

  # SMB2/3 协议访问（基于 libsmb2，稳定版 2.7.1）
  pod 'AMSMB2', '~> 2.7.1'

  # 本地 HTTP 代理服务器，桥接 SMB 字节流到 VLCKit（稳定版 0.30）
  pod 'Telegraph', '~> 0.30'
end

post_install do |installer|
  # VLCKit 为二进制 xcframework，需关闭 bitcode
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['ENABLE_BITCODE'] = 'NO'
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
      config.build_settings['EXPANDED_CODE_SIGN_IDENTITY'] = ''
      config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
      config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    end
  end
end
