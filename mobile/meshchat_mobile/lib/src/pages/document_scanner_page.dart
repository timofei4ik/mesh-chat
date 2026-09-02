import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as imglib;
import 'package:image_picker/image_picker.dart';
import 'package:pdf/widgets.dart' as pw;

import '../utils/mesh_page_route.dart';
import '../widgets/mesh_settings_surface.dart';

class ScannedAttachment {
  const ScannedAttachment({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;
}

class ScannerImageInput {
  const ScannerImageInput({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

enum _ScanFilter { original, document, monochrome }

class _ScanPageData {
  const _ScanPageData({
    required this.originalBytes,
    required this.bytes,
    required this.name,
    this.filter = _ScanFilter.document,
  });

  final Uint8List originalBytes;
  final Uint8List bytes;
  final String name;
  final _ScanFilter filter;

  _ScanPageData copyWith({
    Uint8List? originalBytes,
    Uint8List? bytes,
    _ScanFilter? filter,
  }) => _ScanPageData(
    originalBytes: originalBytes ?? this.originalBytes,
    bytes: bytes ?? this.bytes,
    name: name,
    filter: filter ?? this.filter,
  );
}

Uint8List _applyScanFilter(Map<String, Object> request) {
  final source = request['bytes']! as Uint8List;
  final mode = _ScanFilter.values[request['mode']! as int];
  final decoded = imglib.decodeImage(source);
  if (decoded == null) return source;
  final oriented = imglib.bakeOrientation(decoded);
  final result = switch (mode) {
    _ScanFilter.original => oriented,
    _ScanFilter.document => imglib.adjustColor(
      oriented,
      contrast: 1.18,
      brightness: 1.04,
      saturation: 0.82,
      gamma: 0.96,
    ),
    _ScanFilter.monochrome => imglib.adjustColor(
      imglib.grayscale(oriented),
      contrast: 1.34,
      brightness: 1.06,
      gamma: 0.92,
    ),
  };
  return Uint8List.fromList(imglib.encodeJpg(result, quality: 94));
}

Uint8List _rotateScan(Uint8List source) {
  final decoded = imglib.decodeImage(source);
  if (decoded == null) return source;
  return Uint8List.fromList(
    imglib.encodeJpg(imglib.copyRotate(decoded, angle: 90), quality: 94),
  );
}

Uint8List _rectifyScan(Map<String, Object> request) {
  final source = request['bytes']! as Uint8List;
  final values = request['corners']! as List<double>;
  final corners = <Offset>[
    for (var i = 0; i < values.length; i += 2) Offset(values[i], values[i + 1]),
  ];
  final decoded = imglib.decodeImage(source);
  if (decoded == null || corners.length != 4) return source;
  final oriented = imglib.bakeOrientation(decoded);

  double distance(Offset a, Offset b) {
    final dx = (a.dx - b.dx) * oriented.width;
    final dy = (a.dy - b.dy) * oriented.height;
    return math.sqrt(dx * dx + dy * dy);
  }

  final width = math
      .max(
        280,
        ((distance(corners[0], corners[1]) + distance(corners[2], corners[3])) /
                2)
            .round(),
      )
      .clamp(280, oriented.width * 2);
  final height = math
      .max(
        280,
        ((distance(corners[0], corners[2]) + distance(corners[1], corners[3])) /
                2)
            .round(),
      )
      .clamp(280, oriented.height * 2);
  final imageCorners = corners
      .map(
        (point) => imglib.Point(
          (point.dx * (oriented.width - 1)).clamp(0, oriented.width - 1),
          (point.dy * (oriented.height - 1)).clamp(0, oriented.height - 1),
        ),
      )
      .toList(growable: false);
  final output = imglib.copyRectify(
    oriented,
    topLeft: imageCorners[0],
    topRight: imageCorners[1],
    bottomLeft: imageCorners[2],
    bottomRight: imageCorners[3],
    interpolation: imglib.Interpolation.linear,
    toImage: imglib.Image(width: width.toInt(), height: height.toInt()),
  );
  return Uint8List.fromList(imglib.encodeJpg(output, quality: 94));
}

Future<Uint8List> _createScanPdf(List<Uint8List> pages) async {
  final document = pw.Document();
  for (final bytes in pages) {
    final image = pw.MemoryImage(bytes);
    document.addPage(
      pw.Page(
        build: (_) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
      ),
    );
  }
  return document.save();
}

class DocumentScannerPage extends StatefulWidget {
  const DocumentScannerPage({
    super.key,
    this.initialImages = const [],
    this.photoEditor = false,
  });

  final List<ScannerImageInput> initialImages;
  final bool photoEditor;

  @override
  State<DocumentScannerPage> createState() => _DocumentScannerPageState();
}

class _DocumentScannerPageState extends State<DocumentScannerPage> {
  final picker = ImagePicker();
  final pages = <_ScanPageData>[];
  int selectedIndex = 0;
  bool working = false;

  _ScanPageData? get selected => pages.isEmpty ? null : pages[selectedIndex];

  _ScanFilter get defaultFilter =>
      widget.photoEditor ? _ScanFilter.original : _ScanFilter.document;

  @override
  void initState() {
    super.initState();
    if (widget.initialImages.isNotEmpty) {
      working = true;
      Future<void>.microtask(
        () => _addImages(widget.initialImages, alreadyWorking: true),
      );
    }
  }

  void status(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> addFromGallery() async {
    try {
      final picked = await picker.pickMultiImage(
        imageQuality: 92,
        maxWidth: 2200,
        requestFullMetadata: false,
      );
      await _addPicked(picked);
    } on PlatformException catch (error) {
      status(error.message ?? 'Could not open the gallery');
    }
  }

  Future<void> addFromCamera() async {
    try {
      final picked = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 92,
        maxWidth: 2200,
        requestFullMetadata: false,
      );
      if (picked != null) await _addPicked([picked]);
    } on PlatformException catch (error) {
      status(error.message ?? 'Camera is unavailable on this device');
    }
  }

  Future<void> _addPicked(List<XFile> picked) async {
    if (picked.isEmpty) return;
    final images = <ScannerImageInput>[];
    for (final image in picked) {
      images.add(
        ScannerImageInput(name: image.name, bytes: await image.readAsBytes()),
      );
    }
    await _addImages(images);
  }

  Future<void> _addImages(
    List<ScannerImageInput> images, {
    bool alreadyWorking = false,
  }) async {
    if (images.isEmpty || (working && !alreadyWorking)) return;
    if (!alreadyWorking) setState(() => working = true);
    try {
      for (final image in images) {
        final original = image.bytes;
        final processed = await compute(_applyScanFilter, <String, Object>{
          'bytes': original,
          'mode': defaultFilter.index,
        });
        pages.add(
          _ScanPageData(
            originalBytes: original,
            bytes: processed,
            name: image.name.trim().isEmpty
                ? 'Page ${pages.length + 1}'
                : image.name,
            filter: defaultFilter,
          ),
        );
      }
      selectedIndex = pages.length - 1;
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> setFilter(_ScanFilter filter) async {
    final page = selected;
    if (page == null || working || page.filter == filter) return;
    setState(() => working = true);
    try {
      final bytes = await compute(_applyScanFilter, <String, Object>{
        'bytes': page.originalBytes,
        'mode': filter.index,
      });
      if (!mounted || selected != page) return;
      setState(
        () =>
            pages[selectedIndex] = page.copyWith(bytes: bytes, filter: filter),
      );
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> rotateSelected() async {
    final page = selected;
    if (page == null || working) return;
    setState(() => working = true);
    try {
      final original = await compute(_rotateScan, page.originalBytes);
      final bytes = await compute(_applyScanFilter, <String, Object>{
        'bytes': original,
        'mode': page.filter.index,
      });
      if (!mounted || selected != page) return;
      setState(() {
        pages[selectedIndex] = page.copyWith(
          originalBytes: original,
          bytes: bytes,
        );
      });
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> alignSelected() async {
    final page = selected;
    if (page == null || working) return;
    final aligned = await Navigator.of(context).push<Uint8List>(
      meshPageRoute<Uint8List>(
        builder: (_) => _DocumentAlignPage(bytes: page.originalBytes),
        fullWidthSlide: true,
      ),
    );
    if (aligned == null || !mounted) return;
    setState(() => working = true);
    try {
      final bytes = await compute(_applyScanFilter, <String, Object>{
        'bytes': aligned,
        'mode': page.filter.index,
      });
      if (!mounted) return;
      setState(() {
        pages[selectedIndex] = page.copyWith(
          originalBytes: aligned,
          bytes: bytes,
        );
      });
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void moveSelected(int delta) {
    if (pages.length < 2) return;
    final target = (selectedIndex + delta).clamp(0, pages.length - 1);
    if (target == selectedIndex) return;
    setState(() {
      final page = pages.removeAt(selectedIndex);
      pages.insert(target, page);
      selectedIndex = target;
    });
  }

  void removeSelected() {
    if (pages.isEmpty) return;
    setState(() {
      pages.removeAt(selectedIndex);
      selectedIndex = pages.isEmpty
          ? 0
          : selectedIndex.clamp(0, pages.length - 1);
    });
  }

  Future<void> sendImage() async {
    final page = selected;
    if (page == null) return;
    Navigator.pop(
      context,
      ScannedAttachment(
        fileName: 'scan_${DateTime.now().millisecondsSinceEpoch}.jpg',
        bytes: page.bytes,
      ),
    );
  }

  Future<void> sendPdf() async {
    if (pages.isEmpty || working) return;
    setState(() => working = true);
    try {
      final bytes = await compute(
        _createScanPdf,
        pages.map((page) => page.bytes).toList(growable: false),
      );
      if (!mounted) return;
      Navigator.pop(
        context,
        ScannedAttachment(
          fileName: 'scan_${DateTime.now().millisecondsSinceEpoch}.pdf',
          bytes: bytes,
        ),
      );
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = selected;
    return MeshSettingsSurface(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.photoEditor ? 'Photo editor' : 'Document scanner',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              Text(
                widget.photoEditor
                    ? 'Edit the photo before sending'
                    : 'Prepare a document before sending',
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Add from gallery',
              onPressed: working ? null : addFromGallery,
              icon: const Icon(Icons.add_photo_alternate_rounded),
            ),
            IconButton(
              tooltip: 'Scan with camera',
              onPressed: working ? null : addFromCamera,
              icon: const Icon(Icons.camera_alt_rounded),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 820;
              final preview = _previewPane(page);
              final controls = _controlsPane(page, compact: !wide);
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: wide
                    ? Row(
                        children: [
                          Expanded(flex: 7, child: preview),
                          const SizedBox(width: 16),
                          SizedBox(width: 330, child: controls),
                        ],
                      )
                    : Column(
                        children: [
                          Expanded(child: preview),
                          const SizedBox(height: 12),
                          controls,
                        ],
                      ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _previewPane(_ScanPageData? page) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0B1724),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (page == null)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.document_scanner_outlined,
                    size: 64,
                    color: Color(0xFF72D8FF),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Add the first page',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Use the camera or choose photos',
                    style: TextStyle(color: Colors.white60),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: addFromGallery,
                    icon: const Icon(Icons.photo_library_rounded),
                    label: const Text('Choose photos'),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(10),
              child: Image.memory(
                page.bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
          if (working)
            const ColoredBox(
              color: Color(0x6607111E),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _controlsPane(_ScanPageData? page, {required bool compact}) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pages.isNotEmpty) _pageStrip(),
        if (pages.isNotEmpty) const SizedBox(height: 10),
        SegmentedButton<_ScanFilter>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: _ScanFilter.original,
              icon: Icon(Icons.image_outlined),
              label: Text('Original'),
            ),
            ButtonSegment(
              value: _ScanFilter.document,
              icon: Icon(Icons.auto_fix_high_rounded),
              label: Text('Clean'),
            ),
            ButtonSegment(
              value: _ScanFilter.monochrome,
              icon: Icon(Icons.contrast_rounded),
              label: Text('B&W'),
            ),
          ],
          selected: {page?.filter ?? _ScanFilter.document},
          onSelectionChanged: page == null || working
              ? null
              : (value) => setFilter(value.first),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ToolButton(
                icon: Icons.crop_free_rounded,
                label: 'Align',
                onPressed: page == null ? null : alignSelected,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ToolButton(
                icon: Icons.rotate_90_degrees_cw_rounded,
                label: 'Rotate',
                onPressed: page == null ? null : rotateSelected,
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Delete page',
              onPressed: page == null ? null : removeSelected,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: page == null || working ? null : sendImage,
                icon: const Icon(Icons.image_rounded),
                label: const Text('Send image'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: page == null || working ? null : sendPdf,
                icon: const Icon(Icons.picture_as_pdf_rounded),
                label: Text(
                  pages.length > 1
                      ? 'Send ${pages.length}-page PDF'
                      : 'Send PDF',
                ),
              ),
            ),
          ],
        ),
      ],
    );
    return compact ? content : SingleChildScrollView(child: content);
  }

  Widget _pageStrip() {
    return SizedBox(
      height: 76,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Move page earlier',
            onPressed: selectedIndex > 0 ? () => moveSelected(-1) : null,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: pages.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => InkWell(
                onTap: () => setState(() => selectedIndex = index),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 58,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: index == selectedIndex
                          ? const Color(0xFF72D8FF)
                          : Colors.white24,
                      width: index == selectedIndex ? 2 : 1,
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.memory(
                          pages[index].bytes,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        right: 2,
                        bottom: 2,
                        child: CircleAvatar(
                          radius: 9,
                          backgroundColor: const Color(0xCC07111E),
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Move page later',
            onPressed: selectedIndex < pages.length - 1
                ? () => moveSelected(1)
                : null,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    icon: Icon(icon),
    label: Text(label),
  );
}

class _DocumentAlignPage extends StatefulWidget {
  const _DocumentAlignPage({required this.bytes});

  final Uint8List bytes;

  @override
  State<_DocumentAlignPage> createState() => _DocumentAlignPageState();
}

class _DocumentAlignPageState extends State<_DocumentAlignPage> {
  late List<Offset> corners;
  bool working = false;

  @override
  void initState() {
    super.initState();
    corners = _detectCorners(widget.bytes);
  }

  Future<void> apply() async {
    if (working) return;
    setState(() => working = true);
    final output = await compute(_rectifyScan, <String, Object>{
      'bytes': widget.bytes,
      'corners': <double>[
        for (final point in corners) ...[point.dx, point.dy],
      ],
    });
    if (mounted) Navigator.pop(context, output);
  }

  Rect _imageRect(Size box, Size image) {
    final boxRatio = box.width / box.height;
    final imageRatio = image.width / image.height;
    if (imageRatio > boxRatio) {
      final height = box.width / imageRatio;
      return Rect.fromLTWH(0, (box.height - height) / 2, box.width, height);
    }
    final width = box.height * imageRatio;
    return Rect.fromLTWH((box.width - width) / 2, 0, width, box.height);
  }

  @override
  Widget build(BuildContext context) {
    final decoded = imglib.decodeImage(widget.bytes);
    final imageSize = decoded == null
        ? const Size(1, 1)
        : Size(decoded.width.toDouble(), decoded.height.toDouble());
    return MeshSettingsSurface(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: const Text(
            'Align document',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          actions: [
            IconButton(
              tooltip: 'Reset corners',
              onPressed: () =>
                  setState(() => corners = _detectCorners(widget.bytes)),
              icon: const Icon(Icons.restart_alt_rounded),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                const Text(
                  'Move the four handles to the page corners.',
                  style: TextStyle(color: Colors.white60),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final imageRect = _imageRect(
                        Size(constraints.maxWidth, constraints.maxHeight),
                        imageSize,
                      );
                      return Stack(
                        children: [
                          Positioned.fromRect(
                            rect: imageRect,
                            child: Image.memory(widget.bytes, fit: BoxFit.fill),
                          ),
                          Positioned.fromRect(
                            rect: imageRect,
                            child: CustomPaint(
                              painter: _CornerPainter(corners),
                            ),
                          ),
                          for (var i = 0; i < corners.length; i++)
                            Positioned(
                              left:
                                  imageRect.left +
                                  corners[i].dx * imageRect.width -
                                  22,
                              top:
                                  imageRect.top +
                                  corners[i].dy * imageRect.height -
                                  22,
                              child: GestureDetector(
                                onPanUpdate: (details) => setState(() {
                                  corners[i] = Offset(
                                    (corners[i].dx +
                                            details.delta.dx / imageRect.width)
                                        .clamp(0.0, 1.0),
                                    (corners[i].dy +
                                            details.delta.dy / imageRect.height)
                                        .clamp(0.0, 1.0),
                                  );
                                }),
                                child: Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: const Color(0xCC17324A),
                                    border: Border.all(
                                      color: const Color(0xFF72D8FF),
                                      width: 2,
                                    ),
                                  ),
                                  child: Center(
                                    child: Text(
                                      '${i + 1}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (working)
                            const Positioned.fill(
                              child: ColoredBox(
                                color: Color(0x6607111E),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: working ? null : apply,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Apply alignment'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

List<Offset> _detectCorners(Uint8List bytes) {
  const fallback = [
    Offset(0.08, 0.08),
    Offset(0.92, 0.08),
    Offset(0.08, 0.92),
    Offset(0.92, 0.92),
  ];
  final decoded = imglib.decodeImage(bytes);
  if (decoded == null || decoded.width < 32 || decoded.height < 32) {
    return [...fallback];
  }
  final image = imglib.bakeOrientation(decoded);
  final width = image.width;
  final height = image.height;
  final step = math.max(2, (math.max(width, height) / 360).round());

  double luminanceAt(int x, int y) {
    final pixel = image.getPixel(x.clamp(0, width - 1), y.clamp(0, height - 1));
    return pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114;
  }

  var edgeTotal = 0.0;
  var edgeCount = 0;
  for (var x = 0; x < width; x += step) {
    edgeTotal += luminanceAt(x, 0) + luminanceAt(x, height - 1);
    edgeCount += 2;
  }
  for (var y = 0; y < height; y += step) {
    edgeTotal += luminanceAt(0, y) + luminanceAt(width - 1, y);
    edgeCount += 2;
  }
  final edgeLum = edgeTotal / math.max(1, edgeCount);
  var minX = width;
  var minY = height;
  var maxX = 0;
  var maxY = 0;
  var hits = 0;
  for (var y = 0; y < height; y += step) {
    for (var x = 0; x < width; x += step) {
      final lum = luminanceAt(x, y);
      final likelyPaper = edgeLum < 140
          ? lum > edgeLum + 24
          : lum < edgeLum - 24;
      if ((lum - edgeLum).abs() > 34 || likelyPaper) {
        minX = math.min(minX, x);
        minY = math.min(minY, y);
        maxX = math.max(maxX, x);
        maxY = math.max(maxY, y);
        hits++;
      }
    }
  }
  final area = ((maxX - minX) * (maxY - minY)) / (width * height);
  if (hits < 24 || area < 0.12) return [...fallback];
  final left = ((minX - width * 0.015) / width).clamp(0.0, 1.0);
  final top = ((minY - height * 0.015) / height).clamp(0.0, 1.0);
  final right = ((maxX + width * 0.015) / width).clamp(0.0, 1.0);
  final bottom = ((maxY + height * 0.015) / height).clamp(0.0, 1.0);
  if (right - left < 0.25 || bottom - top < 0.25) return [...fallback];
  return [
    Offset(left, top),
    Offset(right, top),
    Offset(left, bottom),
    Offset(right, bottom),
  ];
}

class _CornerPainter extends CustomPainter {
  const _CornerPainter(this.corners);

  final List<Offset> corners;

  @override
  void paint(Canvas canvas, Size size) {
    final points = corners
        .map((point) => Offset(point.dx * size.width, point.dy * size.height))
        .toList();
    final path = Path()
      ..moveTo(points[0].dx, points[0].dy)
      ..lineTo(points[1].dx, points[1].dy)
      ..lineTo(points[3].dx, points[3].dy)
      ..lineTo(points[2].dx, points[2].dy)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0x2272D8FF));
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF72D8FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _CornerPainter oldDelegate) => true;
}
