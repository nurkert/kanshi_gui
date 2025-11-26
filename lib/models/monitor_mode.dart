class MonitorMode {
  final double width;
  final double height;
  final double refresh; // Hz

  const MonitorMode({
    required this.width,
    required this.height,
    required this.refresh,
  });

  String get label => _formatHz('${width.toInt()}x${height.toInt()}', refresh);

  String _formatHz(String base, double hz) {
    final isInt = (hz - hz.round()).abs() < 0.01;
    final hzText = isInt ? hz.round().toString() : hz.toStringAsFixed(3);
    return '$base@${hzText}Hz';
  }
}
