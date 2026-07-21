/// Um computador pareado, como retornado por GET /api/v1/devices.
class Device {
  const Device({
    required this.deviceId,
    required this.name,
    required this.os,
    required this.hostname,
  });

  final String deviceId;
  final String name;
  final String os;
  final String hostname;

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(
      deviceId: json['device_id'] as String,
      name: json['name'] as String,
      os: json['os'] as String,
      hostname: json['hostname'] as String,
    );
  }
}
