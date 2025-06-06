class MonitorMode {
  final double width;
  final double height;
  final int refresh; // Hz

  const MonitorMode({
    required this.width,
    required this.height,
    required this.refresh,
  });

  String get label =>
      '${width.toInt()}x${height.toInt()}@${refresh}Hz';
}
