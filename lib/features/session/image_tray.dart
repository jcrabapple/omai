// The attached-images tray above the composer field, ported from
// web/src/components/ImageTray.svelte: a row of 56dp thumbnails, each with a
// remove control (48dp target, Semantics 'Remove image N'). Each item is a
// 68x68 box: the 56dp thumb sits bottom-left and the full 48dp target sits
// in the top-right corner overlapping the thumb, entirely INSIDE the item
// (hit testing stops at the item's bounds, review triage #9), and adjacent
// items never overlap. Only mounted while images are attached.

import 'package:flutter/material.dart';

import '../../composer/images.dart';
import '../../theme/tokens.dart';

/// The item box: 56dp thumb plus room for the 48dp corner target.
const double _itemSize = 68;
const double _thumbSize = 56;

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
        height: _itemSize + OmpMetrics.s2,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: OmpMetrics.s2),
          itemCount: images.length,
          separatorBuilder: (_, _) => const SizedBox(width: OmpMetrics.s2),
          itemBuilder: (context, i) {
            final img = images[i];
            return SizedBox(
              key: ValueKey('image-tray-item-$i'),
              width: _itemSize,
              height: _itemSize,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: Container(
                      width: _thumbSize,
                      height: _thumbSize,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(OmpMetrics.radiusMd),
                        border: Border.all(color: tokens.lineStrong),
                      ),
                      child: Image.memory(
                        img.bytes,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  Positioned(
                    // The visible X is small; the whole 48dp touch target sits
                    // inside the item box, in the corner over the thumb.
                    top: 0,
                    right: 0,
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
              ),
            );
          },
        ),
      ),
    );
  }
}
