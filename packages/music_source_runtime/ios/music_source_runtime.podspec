Pod::Spec.new do |s|
  s.name             = 'music_source_runtime'
  s.version          = '0.1.0'
  s.summary          = 'JavaScript source runtime bridge for CyShineMusic.'
  s.description      = <<-DESC
iOS 侧自定义音源运行时。与 Android 的 packages/music_source_runtime 保持完全相同的
MethodChannel 契约（cy_shine_music/music_source_runtime 与
cy_shine_music/music_source_update_runtime），JS 侧共用同一份
music_source_preload.js，因此 lib/ 层不需要任何改动。

JS 引擎使用系统自带的 JavaScriptCore，无外部依赖。
                       DESC
  s.homepage         = 'https://github.com/KevinllBin/CyShineMusic'
  s.license          = { :type => 'MIT' }
  s.author           = { 'CyShineMusic iOS port' => 'noreply@localhost' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.resources        = 'Resources/**'
  s.frameworks       = 'JavaScriptCore', 'Security', 'CommonCrypto'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
