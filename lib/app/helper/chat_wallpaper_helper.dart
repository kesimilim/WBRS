import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';

class ChatWallpaperHelper {
  static const String defaultWallpaper = 'assets/wallpaper/8.jpg';

  static final List<String> availableWallpapers = [
    'assets/wallpaper/1.jpg',
    'assets/wallpaper/2.jpg',
    'assets/wallpaper/3.jpg',
    'assets/wallpaper/4.jpg',
    'assets/wallpaper/5.jpg',
    'assets/wallpaper/6.jpg',
    'assets/wallpaper/7.jpg',
    'assets/wallpaper/8.jpg',
    'assets/wallpaper/9.jpg',
    'assets/wallpaper/10.jpg',
    'assets/wallpaper/11.jpg',
  ];

  static Future<String> getWallpaper(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('chat_wallpaper_$chatId') ?? defaultWallpaper;
  }

  static Future<bool> setWallpaper(
    String chatId,
    String assetPath, {
    TimewebAppRuntime? runtime,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat_wallpaper_$chatId', assetPath);
    // Local fallback persistence is active; server sync will activate once deployed.
    return false;
  }

  static Future<bool> resetWallpaper(
    String chatId, {
    TimewebAppRuntime? runtime,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('chat_wallpaper_$chatId');
    return false;
  }
}
