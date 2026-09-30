// The attached-images tray above the composer field, ported from
// web/src/components/ImageTray.svelte: a horizontal row of 56dp thumbnails,
// each with a remove control (48dp target, Semantics 'Remove image N'). Only
// mounted while images are attached.

import 'package:flutter/material.dart';

import '../../composer/images.dart';
import '../../theme/tokens.dart';

class ImageTray extends StatelessWidget {
  const ImageTray({super.key, required this.images, required this.onRemove});

  final List<AttachedImage> images;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<OmpTokens>()!;
    return Semantics(
      label: 'Attached images',
      child: SizedBox(
        height: 56 + OmpMetrics.s2,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
          itemCount: images.length,
          separatorBuilder: (_, _) => const SizedBox(width: OmpMetrics.s2),
          itemBuilder: (context, i) {
            final img = images[i];
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(OmpMetrics.radiusMd),
                    border: Border.all(color: tokens.lineStrong),
                  ),
                  child: Image.memory(
                    img.bytes,
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned(
                  // The visible X is small; the touch target is 48dp around it.
                  top: -12,
                  right: -12,
                  child: Semantics(
                    label: 'Remove image ${i + 1}',
                    button: true,
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        onTap: () => onRemove(img.id),
                        customBorder: const CircleBorder(),
                        child: SizedBox(
                          width: OmpMetrics.hit,
                          height: OmpMetrics.hit,
                          child: Icon(
                            Icons.close,
                            size: 14,
                            color: tokens.ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
