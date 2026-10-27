import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

abstract class CameraAvailability {
  /// True when the device has a usable back camera.
  Future<bool> hasCamera();
}

class DeviceCameraAvailability implements CameraAvailability {
  const DeviceCameraAvailability();

  @override
  Future<bool> hasCamera() async {
    try {
      final cameras = await availableCameras();
      return cameras.any((c) => c.lensDirection == CameraLensDirection.back);
    } catch (e) {
      debugPrint('Camera availability check failed: $e');
      return false;
    }
  }
}

/// Result of the launch-time camera check. [hasCamera] is null while it runs,
/// so the UI shows nothing until the answer is known.
class CameraAvailabilityProvider extends ChangeNotifier {
  CameraAvailabilityProvider(this._availability);

  final CameraAvailability _availability;
  bool? _hasCamera;
  bool _disposed = false;

  bool? get hasCamera => _hasCamera;

  Future<void> check() async {
    final result = await _availability.hasCamera();
    if (_disposed) return;
    _hasCamera = result;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
