Pod::Spec.new do |s|
  s.name             = 'bass_player'
  s.version          = '0.1.0'
  s.summary          = 'Native BASS playback engine for CyShineMusic.'
  s.description      = <<-DESC
iOS 侧 BASS 播放引擎。与 Android 端的 packages/bass_player 保持完全相同的
MethodChannel / EventChannel 契约（com.cyshine.music/bass_player/methods 与
com.cyshine.music/bass_player/events），因此 lib/ 层不需要任何改动。
                       DESC
  s.homepage         = 'https://github.com/KevinllBin/CyShineMusic'
  s.license          = { :type => 'MIT' }
  s.author           = { 'CyShineMusic iOS port' => 'noreply@localhost' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/*.{swift,h,c}'
  s.preserve_paths   = 'Classes/CHeaders/**', 'Frameworks/**'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'

  # BASS 二进制不入库：由 tool/fetch_bass_ios.sh 在 pod install 之前下载填入。
  # 缺失时直接给出可操作的中文报错，而不是让编译在别处以晦涩信息失败。
  frameworks = Dir.glob(File.join(__dir__, 'Frameworks', '*.xcframework'))
  if frameworks.empty?
    raise <<-MSG

[bass_player] 未找到 BASS iOS 二进制。

  请先在项目根目录执行：
      bash tool/fetch_bass_ios.sh

  该脚本会从 un4seen.com 下载 bass / bassflac / bassape / bassopus / basswv /
  bassdsd 的 xcframework 与头文件。BASS 自用免费、商用需自行购买授权，
  二进制按官方要求不入库。

    MSG
  end
  s.vendored_frameworks = 'Frameworks/*.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # 让 Swift 能 import CBass（module.modulemap 位于 Classes/CHeaders）。
    'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/Classes/CHeaders',
    'HEADER_SEARCH_PATHS' => '$(PODS_TARGET_SRCROOT)/Classes/CHeaders',
    # BASS 的 xcframework 只带 arm64（真机）与 arm64+x86_64（模拟器）切片。
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 armv7',
    'CLANG_WARN_DOCUMENTATION_COMMENTS' => 'NO'
  }
end
