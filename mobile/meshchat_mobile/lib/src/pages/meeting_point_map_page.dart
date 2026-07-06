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

class MeetingPointMapDeleteResult {
  const MeetingPointMapDeleteResult({required this.messageId});

  final String messageId;
}

class MeetingPointMapPin {
  const MeetingPointMapPin({
    required this.title,
    required this.latitude,
    required this.longitude,
    this.note = '',
    this.senderName = '',
    this.timestamp = '',
    this.messageId,
  });

  final String title;
  final double latitude;
  final double longitude;
  final String note;
  final String senderName;
  final String timestamp;
  final String? messageId;

  LatLng get point => LatLng(latitude, longitude);
}

class MeetingPointMapPage extends StatefulWidget {
  const MeetingPointMapPage({
    super.key,
    required this.title,
    required this.latitude,
    required this.longitude,
    this.note = '',
    this.picking = false,
    this.pins = const [],
    this.initialPinIndex = 0,
    this.routeOnOpen = false,
    this.allowMeetingPointCreation = false,
  });

  final String title;
  final double latitude;
  final double longitude;
  final String note;
  final bool picking;
  final List<MeetingPointMapPin> pins;
  final int initialPinIndex;
  final bool routeOnOpen;
  final bool allowMeetingPointCreation;

  @override
  State<MeetingPointMapPage> createState() => _MeetingPointMapPageState();
}

class _MeetingPointMapPageState extends State<MeetingPointMapPage> {
  final mapController = MapController();
  late LatLng selected = LatLng(widget.latitude, widget.longitude);
  late int selectedPinIndex = widget.initialPinIndex.clamp(
    0,
    widget.pins.isEmpty ? 0 : widget.pins.length - 1,
  );
  LatLng? current;
  LatLng? proposedMeetingPoint;
  var locating = false;
  var routeMode = _RouteMode.walk;
  String? error;

  bool get hasPins => !widget.picking && widget.pins.isNotEmpty;

  MeetingPointMapPin? get selectedPin {
    if (!hasPins) return null;
    return widget.pins[selectedPinIndex];
  }

  @override
  void initState() {
    super.initState();
    final pin = selectedPin;
    if (pin != null) selected = pin.point;
    unawaitedCurrentLocation();
    if (widget.routeOnOpen && !widget.picking) {
      WidgetsBinding.instance.addPostFrameCallback((_) => openNavigation());
    }
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
        if (widget.allowMeetingPointCreation && !widget.picking) {
          proposedMeetingPoint = current;
        }
      }
    });
    if (position != null) {
      moveMapTo(LatLng(position.latitude, position.longitude), zoom: 15.5);
    }
  }

  Future<void> openNavigation() async {
    final destination = proposedMeetingPoint ?? selectedPin?.point ?? selected;
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${destination.latitude},${destination.longitude}&travelmode=${routeMode.googleValue}',
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

  void moveMapTo(LatLng point, {double? zoom}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        mapController.move(point, zoom ?? mapController.camera.zoom);
      } catch (_) {
        // The native map can briefly be between layouts on iOS; ignore and keep
        // the selected point state instead of crashing the page.
      }
    });
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

  void finishMeetingPointCreation() {
    final point = proposedMeetingPoint;
    if (point == null) return;
    Navigator.pop(
      context,
      MeetingPointMapResult(
        latitude: point.latitude,
        longitude: point.longitude,
      ),
    );
  }

  void selectPin(int index) {
    if (index < 0 || index >= widget.pins.length) return;
    final pin = widget.pins[index];
    setState(() {
      selectedPinIndex = index;
      selected = pin.point;
    });
    moveMapTo(pin.point);
  }

  void openMessage() {
    final id = selectedPin?.messageId;
    if (id == null || id.isEmpty) return;
    Navigator.pop(context, id);
  }

  void deleteSelectedPin() {
    final id = selectedPin?.messageId;
    if (id == null || id.isEmpty) return;
    Navigator.pop(context, MeetingPointMapDeleteResult(messageId: id));
  }

  @override
  Widget build(BuildContext context) {
    final activePoint = proposedMeetingPoint ?? selectedPin?.point ?? selected;
    final routePoints = current == null ? <LatLng>[] : [current!, activePoint];
    final creatingMeeting = proposedMeetingPoint != null;
    final title = creatingMeeting
        ? 'New meeting point'
        : selectedPin?.title ?? widget.title;
    final note = creatingMeeting
        ? 'Send this place to the group as a meeting proposal.'
        : selectedPin?.note ?? widget.note;
    final subtitle = creatingMeeting
        ? 'Tap Add meeting point to notify the group'
        : selectedPin == null
        ? '${activePoint.latitude.toStringAsFixed(5)}, ${activePoint.longitude.toStringAsFixed(5)}'
        : [
            selectedPin!.senderName,
            selectedPin!.timestamp,
          ].where((value) => value.trim().isNotEmpty).join(' - ');
    return Scaffold(
      backgroundColor: const Color(0xFF07111E),
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: mapController,
              options: MapOptions(
                initialCenter: activePoint,
                initialZoom: hasPins ? 12 : 14,
                minZoom: 3,
                maxZoom: 19,
                onTap: widget.picking
                    ? (_, point) => setState(() => selected = point)
                    : widget.allowMeetingPointCreation
                    ? (_, point) {
                        setState(() {
                          proposedMeetingPoint = point;
                          selected = point;
                          error = null;
                        });
                      }
                    : null,
                onLongPress: widget.allowMeetingPointCreation && !widget.picking
                    ? (_, point) {
                        setState(() {
                          proposedMeetingPoint = point;
                          selected = point;
                          error = null;
                        });
                      }
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
                    if (hasPins)
                      ...List.generate(widget.pins.length, (index) {
                        final pin = widget.pins[index];
                        final active = index == selectedPinIndex;
                        return Marker(
                          point: pin.point,
                          width: active ? 68 : 52,
                          height: active ? 68 : 52,
                          child: GestureDetector(
                            onTap: () => selectPin(index),
                            child: _MapDot(
                              color: active
                                  ? const Color(0xFF8D72FF)
                                  : const Color(0xFF45D9FF),
                              icon: active
                                  ? Icons.location_on_rounded
                                  : Icons.place_rounded,
                              active: active,
                            ),
                          ),
                        );
                      })
                    else
                      Marker(
                        point: selected,
                        width: 54,
                        height: 54,
                        child: const _MapDot(
                          color: Color(0xFF8D72FF),
                          icon: Icons.location_on_rounded,
                        ),
                      ),
                    if (proposedMeetingPoint != null)
                      Marker(
                        point: proposedMeetingPoint!,
                        width: 72,
                        height: 72,
                        child: const _MapDot(
                          color: Color(0xFF54F2C7),
                          icon: Icons.add_location_alt_rounded,
                          active: true,
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
                                  widget.picking ? 'Choose location' : title,
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
                                      : subtitle.isEmpty
                                      ? '${activePoint.latitude.toStringAsFixed(5)}, ${activePoint.longitude.toStringAsFixed(5)}'
                                      : subtitle,
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
                  if (hasPins) ...[
                    SizedBox(
                      height: 44,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(bottom: 8),
                        itemCount: widget.pins.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final pin = widget.pins[index];
                          final active = index == selectedPinIndex;
                          return _MapChip(
                            title: pin.title,
                            active: active,
                            onTap: () => selectPin(index),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  _GlassSurface(
                    radius: 28,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (note.trim().isNotEmpty) ...[
                            Text(
                              note.trim(),
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
                          if (!widget.picking && !creatingMeeting) ...[
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final mode in _RouteMode.values)
                                  _RouteModeChip(
                                    mode: mode,
                                    active: mode == routeMode,
                                    onTap: () =>
                                        setState(() => routeMode = mode),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                          ],
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final actions = <Widget>[
                                _PillButton(
                                  icon: locating
                                      ? Icons.hourglass_top_rounded
                                      : Icons.my_location_rounded,
                                  label: locating ? 'Finding...' : 'My place',
                                  onTap: locating ? null : useCurrentLocation,
                                ),
                                _PillButton(
                                  icon: widget.picking
                                      ? Icons.check_rounded
                                      : creatingMeeting
                                      ? Icons.add_location_alt_rounded
                                      : Icons.near_me_rounded,
                                  label: widget.picking
                                      ? 'Use marker'
                                      : creatingMeeting
                                      ? 'Add meeting point'
                                      : 'Route',
                                  onTap: widget.picking
                                      ? finishPicking
                                      : creatingMeeting
                                      ? finishMeetingPointCreation
                                      : openNavigation,
                                ),
                                if (creatingMeeting)
                                  _PillButton(
                                    icon: Icons.close_rounded,
                                    label: 'Cancel',
                                    onTap: () => setState(
                                      () => proposedMeetingPoint = null,
                                    ),
                                  ),
                                if (!creatingMeeting &&
                                    selectedPin?.messageId != null) ...[
                                  _PillButton(
                                    icon: Icons.chat_bubble_outline_rounded,
                                    label: 'Message',
                                    onTap: openMessage,
                                  ),
                                  _PillButton(
                                    icon: Icons.delete_outline_rounded,
                                    label: 'Delete',
                                    onTap: deleteSelectedPin,
                                  ),
                                ],
                              ];
                              final compact = constraints.maxWidth < 620;
                              final width = compact
                                  ? 176.0
                                  : (constraints.maxWidth -
                                            ((actions.length - 1) * 8)) /
                                        actions.length;
                              return SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
                                child: Row(
                                  children: [
                                    for (
                                      var i = 0;
                                      i < actions.length;
                                      i++
                                    ) ...[
                                      SizedBox(width: width, child: actions[i]),
                                      if (i != actions.length - 1)
                                        const SizedBox(width: 8),
                                    ],
                                  ],
                                ),
                              );
                            },
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
  const _MapDot({required this.color, required this.icon, this.active = true});

  final Color color;
  final IconData icon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: active ? 0.24 : 0.16),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: active ? 0.62 : 0.34),
            blurRadius: active ? 26 : 16,
          ),
        ],
      ),
      child: Center(
        child: Container(
          width: active ? 38 : 30,
          height: active ? 38 : 30,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          child: Icon(icon, color: Colors.white, size: active ? 21 : 17),
        ),
      ),
    );
  }
}

class _MapChip extends StatelessWidget {
  const _MapChip({
    required this.title,
    required this.active,
    required this.onTap,
  });

  final String title;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active
          ? const Color(0xFF45D9FF).withValues(alpha: 0.18)
          : Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 190),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active
                  ? Colors.lightBlueAccent.withValues(alpha: 0.38)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: active ? Colors.white : Colors.white70,
              fontWeight: active ? FontWeight.w900 : FontWeight.w700,
              fontSize: 12,
            ),
          ),
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

enum _RouteMode {
  walk(Icons.directions_walk_rounded, 'Walk', 'walking'),
  car(Icons.directions_car_filled_rounded, 'Car', 'driving'),
  transit(Icons.directions_transit_filled_rounded, 'Transit', 'transit');

  const _RouteMode(this.icon, this.label, this.googleValue);

  final IconData icon;
  final String label;
  final String googleValue;
}

class _RouteModeChip extends StatelessWidget {
  const _RouteModeChip({
    required this.mode,
    required this.active,
    required this.onTap,
  });

  final _RouteMode mode;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active
          ? const Color(0xFF45D9FF).withValues(alpha: 0.20)
          : Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active
                  ? const Color(0xFF45D9FF).withValues(alpha: 0.62)
                  : Colors.white.withValues(alpha: 0.10),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                mode.icon,
                size: 15,
                color: active ? const Color(0xFF54DFFF) : Colors.white70,
              ),
              const SizedBox(width: 6),
              Text(
                mode.label,
                style: TextStyle(
                  color: active ? Colors.white : Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
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
