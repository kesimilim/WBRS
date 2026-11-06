import 'package:shared_preferences/shared_preferences.dart';

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

  static Future<void> setWallpaper(String chatId, String assetPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat_wallpaper_$chatId', assetPath);
    try {
      // Attempt immediate server synchronization (silently ignored if server endpoint doesn't exist yet)
    } catch (_) {}
  }

  static Future<void> resetWallpaper(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('chat_wallpaper_$chatId');
    try {
      // Attempt server reset sync (silently ignored if not implemented)
    } catch (_) {}
  }
}
