import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Live camera preview scaled to cover its parent without stretching.
class CameraPreviewCover extends StatelessWidget {
  const CameraPreviewCover({super.key, required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CameraValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final preview = value.previewSize;
        if (!value.isInitialized || preview == null) {
          return const SizedBox.shrink();
        }
        // previewSize is landscape; the screen is portrait, so swap.
        return ClipRect(
          child: SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: preview.height,
                height: preview.width,
                child: CameraPreview(controller),
              ),
            ),
          ),
        );
      },
    );
  }
}
