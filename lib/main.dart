import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/services/app_logger.dart';
import 'core/debug/debug_paint_guard.dart';
import 'core/storage/settings_store.dart';
import 'features/player/player_audio_handler.dart';
import 'features/player/live_activity_service.dart';
import 'features/player/music_home_widget_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.logEnvironment();
  DebugPaintGuard.install();
  if (Platform.isAndroid) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarContrastEnforced: false,
      ),
    );
    // A widget or media service can start this engine without an Activity.
    // Android's platform channel then has no UI handler and never replies;
    // waiting here would prevent the player and widget controls from starting.
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }
  final prefs = await SharedPreferences.getInstance();
  hydrateNetworkAdapterPreference(prefs);
  final audioHandler = await initializePlayerAudioHandler(
    allowMixWithOthers: readAllowMixWithOthersPreference(prefs),
  );
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      playerAudioHandlerProvider.overrideWithValue(audioHandler),
    ],
  );
  // The media-service engine can start without an Activity or a rendered
  // frame. Install widget controls before runApp, using the same providers.
  await container.read(musicHomeWidgetProvider).initialize();
  // iOS 的灵动岛 / 锁屏实时活动：与桌面小组件同理，尽早建立通道监听，
  // 免得从锁屏直接点播放时错过第一次状态变化。
  await container.read(liveActivityProvider).initialize();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CyShineMusicApp(),
    ),
  );
}
