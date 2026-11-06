import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/helper/chat_wallpaper_helper.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/lrs_theme.dart';

Future<void> showChatWallpaperPicker(
    BuildContext context, String chatId, VoidCallback onSelected) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: LrsTheme.surface,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Container(
        padding: const EdgeInsets.all(16),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              ctx.tr('Выберите обои для чата'),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: LrsTheme.text,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: LrsTheme.peach,
                side: const BorderSide(color: LrsTheme.actionBorder),
              ),
              onPressed: () async {
                try {
                  final picker = ImagePicker();
                  final picked =
                      await picker.pickImage(source: ImageSource.gallery);
                  if (picked != null) {
                    await ChatWallpaperHelper.setWallpaper(chatId, picked.path);
                    Navigator.pop(ctx);
                    onSelected();
                  }
                } catch (_) {}
              },
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(ctx.tr('Выбрать из галереи')),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.7,
                ),
                itemCount: ChatWallpaperHelper.availableWallpapers.length,
                itemBuilder: (context, index) {
                  final path = ChatWallpaperHelper.availableWallpapers[index];
                  return GestureDetector(
                    onTap: () async {
                      await ChatWallpaperHelper.setWallpaper(chatId, path);
                      Navigator.pop(ctx);
                      onSelected();
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset(
                        path,
                        fit: BoxFit.cover,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () async {
                await ChatWallpaperHelper.resetWallpaper(chatId);
                Navigator.pop(ctx);
                onSelected();
              },
              child: Text(ctx.tr('Сбросить (по умолчанию)')),
            ),
          ],
        ),
      ),
    ),
  );
}
