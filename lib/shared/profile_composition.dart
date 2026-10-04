import 'package:wbrs/core/utils/account_destination.dart'
    show savedAccountGroup;
import 'package:wbrs/shared/translatable_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'clrs_screen.dart';
import 'group_badge.dart';
import 'lrs_theme.dart';
import 'clrs_brand.dart';

/// Live profile content, arranged like the late reference portraits. Text is
/// grows naturally over the photo, so long names and system text scaling fit.
class ProfilePortrait extends StatelessWidget {
  const ProfilePortrait({
    super.key,
    required this.photo,
    required this.name,
    required this.group,
    required this.location,
    required this.online,
    this.age = '',
    this.status = '',
    this.own = false,
    this.gender = '',
    this.photoContent,
    this.onPhoto,
  });
  final String photo, name, group, location, age, status;
  final bool? online;
  final bool own;
  final String gender;
  final Widget? photoContent;
  final VoidCallback? onPhoto;
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child:
            photoContent ??
            (photo.isEmpty
                ? const ColoredBox(
                    color: Color(0x4431241D),
                    child: Icon(
                      Icons.person_outline,
                      size: 90,
                      color: LrsTheme.peachLight,
                    ),
                  )
                : ColoredBox(
                    color: const Color(0xFF211911),
                    child: CachedNetworkImage(
                      imageUrl: photo,
                      fit: BoxFit.contain,
                      alignment: Alignment.topCenter,
                      memCacheWidth: (MediaQuery.sizeOf(context).width * 2)
                          .round(),
                      maxWidthDiskCache: 1440,
                      fadeInDuration: const Duration(milliseconds: 120),
                      placeholder: (_, __) =>
                          const Center(child: CircularProgressIndicator()),
                      errorWidget: (_, __, ___) =>
                          const Icon(Icons.person_outline, size: 80),
                    ),
                  )),
      ),
      Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black.withValues(alpha: .12),
                const Color(0xED1D160F),
              ],
              stops: const [0, .45, 1],
            ),
          ),
        ),
      ),
      if (MediaQuery.textScalerOf(context).scale(1) < 1.4)
        Positioned(
          top: MediaQuery.paddingOf(context).top + 8,
          right: 16,
          child: const SizedBox(
            width: 128,
            height: 46,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(width: 128, child: ClrsMotto(size: 18)),
            ),
          ),
        ),
      Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPhoto,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height:
                      MediaQuery.paddingOf(context).top +
                      (MediaQuery.sizeOf(context).width * .62).clamp(
                        190.0,
                        300.0,
                      ),
                ),
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (online != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.circle,
                            size: 8,
                            color: online == true
                                ? LrsTheme.success
                                : LrsTheme.muted,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            context.tr(online == true ? 'В сети' : 'Не в сети'),
                          ),
                        ],
                      ),
                    if (status.isNotEmpty) Text(context.tr(status)),
                  ],
                ),
                const SizedBox(height: 5),
                Wrap(
                  spacing: 6,
                  runSpacing: 3,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: name),
                          if (age.isNotEmpty)
                            TextSpan(text: '${name.isEmpty ? '' : ', '}$age'),
                        ],
                      ),
                      style: const TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w700,
                        color: LrsTheme.text,
                      ),
                    ),
                    if (groupColors(group).isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GroupRing(group: group, size: 24),
                          const SizedBox(width: 7),
                          Flexible(
                            child: GroupCaption(
                              group: group,
                              own: own,
                              gender: gender,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                if (location.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.location_on_outlined, size: 18),
                        const SizedBox(width: 5),
                        Expanded(child: Text(location)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class ProfileSection extends StatelessWidget {
  const ProfileSection({
    super.key,
    required this.title,
    required this.child,
    this.action,
  });
  final String title;
  final Widget child;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: ClrsPanel(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (action != null) action!,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

class ProfileFacts extends StatelessWidget {
  const ProfileFacts({
    super.key,
    required this.data,
    this.showInterests = true,
  });
  final Map<String, dynamic> data;
  final bool showInterests;
  @override
  Widget build(BuildContext context) {
    final entries = <(IconData, String, String)>[
      (Icons.calendar_today_outlined, 'Возраст', '${data['age'] ?? ''}'),
      (Icons.height, 'Рост', '${data['rost'] ?? ''}'),
      (
        Icons.location_on_outlined,
        'Регион',
        profileLocation(data, context: context),
      ),
      (
        Icons.people_outline,
        'Группа',
        savedAccountGroup(data) ?? '${data['группа'] ?? ''}',
      ),
      if (data['deti'] is bool)
        (
          Icons.family_restroom_outlined,
          'Дети',
          context.tr(data['deti'] == true ? 'Есть' : 'Нет'),
        ),
      if (data['education'] != null)
        (Icons.school_outlined, 'Образование', '${data['education']}'),
      if (data['work'] != null)
        (Icons.work_outline, 'Работа', '${data['work']}'),
      if (showInterests)
        (
          Icons.favorite_border,
          'Интересы и увлечения',
          '${data['hobbi'] ?? ''}',
        ),
      (Icons.chat_bubble_outline, 'О себе', '${data['about'] ?? ''}'),
    ].where((entry) => entry.$3.trim().isNotEmpty).toList();
    return LayoutBuilder(
      builder: (context, box) {
        final columns =
            box.maxWidth >= 290 &&
                MediaQuery.textScalerOf(context).scale(14) <= 20
            ? 2
            : 1;
        final width = (box.maxWidth - (columns - 1) * 16) / columns;
        return Wrap(
          spacing: 16,
          runSpacing: 2,
          children: [
            for (final entry in entries)
              SizedBox(
                width: width,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(entry.$1, size: 19),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.tr(entry.$2),
                              style: const TextStyle(
                                fontSize: 11,
                                color: LrsTheme.peachLight,
                              ),
                            ),
                            const SizedBox(height: 3),
                            entry.$2 == 'Группа'
                                ? GroupNameText(group: entry.$3)
                                : const {
                                    'Образование',
                                    'Работа',
                                    'Интересы и увлечения',
                                    'О себе',
                                  }.contains(entry.$2)
                                ? TranslatableText(
                                    entry.$3,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      height: 1.3,
                                    ),
                                  )
                                : Text(
                                    entry.$3,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      height: 1.3,
                                    ),
                                  ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class ProfilePhotoStrip extends StatelessWidget {
  const ProfilePhotoStrip({
    super.key,
    required this.urls,
    required this.onTap,
    this.thumbnailUrls,
    this.photoBuilder,
  });
  final List<String> urls;
  final List<String>? thumbnailUrls;
  final ValueChanged<int> onTap;
  final Widget Function(BuildContext context, int index)? photoBuilder;
  @override
  Widget build(BuildContext context) {
    final width = ((MediaQuery.sizeOf(context).width - 84) / 5).clamp(
      48.0,
      72.0,
    );
    return urls.isEmpty
        ? Text(context.tr('Нет фотографий'))
        : SizedBox(
            height: 80,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: urls.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) => Semantics(
                button: true,
                label: context.tr('Фото {number}', args: {'number': index + 1}),
                child: InkWell(
                  onTap: () => onTap(index),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: photoBuilder != null
                        ? SizedBox(
                            width: width,
                            height: 80,
                            child: photoBuilder!(context, index),
                          )
                        : CachedNetworkImage(
                            imageUrl:
                                thumbnailUrls != null &&
                                    index < thumbnailUrls!.length
                                ? thumbnailUrls![index]
                                : urls[index],
                            width: width,
                            height: 80,
                            fit: BoxFit.cover,
                            memCacheWidth: 250,
                            maxWidthDiskCache: 360,
                            errorWidget: (_, __, ___) => SizedBox(
                              width: width,
                              child: Icon(Icons.broken_image_outlined),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          );
  }
}

String profileLocation(Map data, {BuildContext? context}) => [
  if (data['country'] != null)
    context?.tr('${data['country']}') ?? data['country'],
  data['region'],
].where((e) => e != null && '$e'.trim().isNotEmpty).join(' · ');

String relationshipLabel(Object? raw) => '$raw'.startsWith('занят')
    ? 'Занят'
    : '$raw'.startsWith('свобод')
    ? 'Свободен'
    : '';
