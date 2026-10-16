import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppIconVariant {
  classic('classic', '经典绿'),
  midnight('midnight', '午夜蓝'),
  sky('sky', '晴空蓝'),
  lavender('lavender', '雾紫'),
  mint('mint', '薄荷青'),
  peach('peach', '暖桃粉');

  const AppIconVariant(this.code, this.label);

  final String code;
  final String label;
  String get previewAsset => 'assets/app_icons/$code.png';

  static AppIconVariant fromCode(String? code) =>
      values.firstWhere((icon) => icon.code == code, orElse: () => classic);
}

// iOS 走 setAlternateIconName，图标必须预打包并在 Info.plist 的
// CFBundleAlternateIcons 里声明（见 ios/Runner/Info.plist）。
// 与 Android 的差别：切换时系统会弹一次提示，无法绕过。
bool get supportsCustomAppIcons {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

final appIconProvider =
    AsyncNotifierProvider<AppIconController, AppIconVariant>(
      AppIconController.new,
    );

class AppIconController extends AsyncNotifier<AppIconVariant> {
  static const _channel = MethodChannel('cy_shine_music/app_icon');

  @override
  Future<AppIconVariant> build() async {
    if (!supportsCustomAppIcons) return AppIconVariant.classic;
    return AppIconVariant.fromCode(
      await _channel.invokeMethod<String>('getCurrentIcon'),
    );
  }

  Future<bool> select(AppIconVariant icon) async {
    if (!supportsCustomAppIcons || state.isLoading) return false;
    if (state.valueOrNull == icon) return false;
    final previous = state;
    state = const AsyncLoading<AppIconVariant>().copyWithPrevious(previous);
    try {
      final code = await _channel.invokeMethod<String>('setIcon', {
        'icon': icon.code,
      });
      state = AsyncData(AppIconVariant.fromCode(code));
      return true;
    } catch (error, stack) {
      state = previous;
      Error.throwWithStackTrace(error, stack);
    }
  }
}
