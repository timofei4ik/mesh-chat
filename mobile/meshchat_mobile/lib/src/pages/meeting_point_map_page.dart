import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

class MeetingPointMapResult {
  const MeetingPointMapResult({
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;

  String get coordinateText {
    return '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
  }
}

class MeetingPointMapPage extends StatefulWidget {
  const MeetingPointMapPage({
    super.key,
    required this.title,
    required this.latitude,
    required this.longitude,
    this.note = '',
    this.picking = false,
  });

  final String title;
  final double latitude;
  final double longitude;
  final String note;
  final bool picking;

  @override
  State<MeetingPointMapPage> createState() => _MeetingPointMapPageState();
}

class _MeetingPointMapPageState extends State<MeetingPointMapPage> {
  late LatLng selected = LatLng(widget.latitude, widget.longitude);
  LatLng? current;
  var locating = false;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaitedCurrentLocation();
  }

  void unawaitedCurrentLocation() {
    Future<void>(() async {
      final position = await _tryPosition();
      if (!mounted || position == null) return;
      setState(() => current = LatLng(position.latitude, position.longitude));
    });
  }

  Future<Position?> _tryPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      return Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> useCurrentLocation() async {
    setState(() {
      locating = true;
      error = null;
    });
    final position = await _tryPosition();
    if (!mounted) return;
    setState(() {
      locating = false;
      if (position == null) {
        error = 'Could not read current location';
      } else {
        current = LatLng(position.latitude, position.longitude);
        selected = current!;
      }
    });
  }

  Future<void> openNavigation() async {
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${selected.latitude},${selected.longitude}',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Could not open navigation')));
  }

  void finishPicking() {
    Navigator.pop(
      context,
      MeetingPointMapResult(
        latitude: selected.latitude,
        longitude: selected.longitude,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final routePoints = current == null ? <LatLng>[] : [current!, selected];
    return Scaffold(
      backgroundColor: const Color(0xFF07111E),
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              options: MapOptions(
                initialCenter: selected,
                initialZoom: 14,
                minZoom: 3,
                maxZoom: 19,
                onTap: widget.picking
                    ? (_, point) => setState(() => selected = point)
                    : null,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'meshchat.mobile',
                ),
                if (routePoints.length == 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: routePoints,
                        strokeWidth: 5,
                        color: Colors.lightBlueAccent.withValues(alpha: 0.75),
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    if (current != null)
                      Marker(
                        point: current!,
                        width: 42,
                        height: 42,
                        child: const _MapDot(
                          color: Color(0xFF54F2C7),
                          icon: Icons.my_location_rounded,
                        ),
                      ),
                    Marker(
                      point: selected,
                      width: 54,
                      height: 54,
                      child: const _MapDot(
                        color: Color(0xFF8D72FF),
                        icon: Icons.location_on_rounded,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF07111E).withValues(alpha: 0.55),
                      Colors.transparent,
                      const Color(0xFF07111E).withValues(alpha: 0.72),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      _RoundGlassButton(
                        icon: Icons.arrow_back_ios_new_rounded,
                        onTap: () => Navigator.maybePop(context),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _GlassSurface(
                          radius: 22,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.picking
                                      ? 'Choose location'
                                      : widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  widget.picking
                                      ? 'Tap the map to move the marker'
                                      : '${selected.latitude.toStringAsFixed(5)}, ${selected.longitude.toStringAsFixed(5)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  _GlassSurface(
                    radius: 28,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.note.trim().isNotEmpty) ...[
                            Text(
                              widget.note.trim(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(height: 10),
                          ],
                          if (error != null) ...[
                            Text(
                              error!,
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                            const SizedBox(height: 10),
                          ],
                          Row(
                            children: [
                              Expanded(
                                child: _PillButton(
                                  icon: locating
                                      ? Icons.hourglass_top_rounded
                                      : Icons.my_location_rounded,
                                  label: locating ? 'Finding...' : 'My place',
                                  onTap: locating ? null : useCurrentLocation,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _PillButton(
                                  icon: widget.picking
                                      ? Icons.check_rounded
                                      : Icons.near_me_rounded,
                                  label: widget.picking
                                      ? 'Use marker'
                                      : 'Route',
                                  onTap: widget.picking
                                      ? finishPicking
                                      : openNavigation,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapDot extends StatelessWidget {
  const _MapDot({required this.color, required this.icon});

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.22),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 22),
        ],
      ),
      child: Center(
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: onTap == null ? 0.04 : 0.10),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: Colors.white),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundGlassButton extends StatelessWidget {
  const _RoundGlassButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.10),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: Colors.white, size: 18),
        ),
      ),
    );
  }
}

class _GlassSurface extends StatelessWidget {
  const _GlassSurface({required this.child, this.radius = 22});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF172333).withValues(alpha: 0.70),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: child,
        ),
      ),
    );
  }
}
