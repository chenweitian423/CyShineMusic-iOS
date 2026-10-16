Pod::Spec.new do |s|
  s.name             = 'music_home_widget'
  s.version          = '0.1.0'
  s.summary          = 'iOS home-screen music card bridge for CyShineMusic.'
  s.description      = <<-DESC
iOS 侧桌面音乐卡片桥。与 Android 的 packages/music_home_widget 保持相同的
MethodChannel 契约（cy_shine_music/home_widget）。

架构差异：Android 用 AppWidget 由主 App 直接渲染；iOS 用 WidgetKit Extension
（独立进程），主 App 把播放状态写入 App Group UserDefaults 并触发
WidgetCenter 刷新，卡片 UI 在 ios/CyShineMusicWidget/ 里读取同一份数据。
                       DESC
  s.homepage         = 'https://github.com/KevinllBin/CyShineMusic'
  s.license          = { :type => 'MIT' }
  s.author           = { 'CyShineMusic iOS port' => 'noreply@localhost' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.frameworks       = 'WidgetKit'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
