import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class ImagePickerGrid extends StatelessWidget {
  const ImagePickerGrid({
    super.key,
    required this.existingUrls,
    required this.newFiles,
    required this.onRemoveExisting,
    required this.onRemoveNew,
    required this.onAddPressed,
    this.maxImages = 10,
  });

  final List<String> existingUrls;
  final List<XFile> newFiles;
  final ValueChanged<int> onRemoveExisting;
  final ValueChanged<int> onRemoveNew;
  final VoidCallback onAddPressed;
  final int maxImages;

  int get _total => existingUrls.length + newFiles.length;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < existingUrls.length; i++)
          _Thumb(
            child: Image.network(existingUrls[i], fit: BoxFit.cover),
            onRemove: () => onRemoveExisting(i),
          ),
        for (var i = 0; i < newFiles.length; i++)
          _Thumb(
            child: Image.file(File(newFiles[i].path), fit: BoxFit.cover),
            onRemove: () => onRemoveNew(i),
          ),
        if (_total < maxImages) _AddTile(onTap: onAddPressed),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.child, required this.onRemove});

  final Widget child;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      height: 88,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox.expand(child: child),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          color: LrsTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: LrsTheme.actionBorder),
        ),
        child: const Icon(Icons.add_photo_alternate_outlined,
            color: LrsTheme.peach),
      ),
    );
  }
}