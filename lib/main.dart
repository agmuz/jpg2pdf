import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saf/saf.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

void main() {
  HttpOverrides.global = MyHttpOverrides();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JPG/PNG do PDF (clearOCR)',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();
  final Saf _saf = Saf();
  final List<XFile> _files = [];
  SafDocumentFile? _targetDir;
  bool _busy = false;
  String _status = 'Wybierz zdjecia, potem wskaz folder na PDF-y.';
  int _processedCount = 0;

  // Dane API (ladowane z SharedPreferences)
  String _apiUser = '';
  String _apiKey = '';

  @override
  void initState() {
    super.initState();
    _loadApiCredentials();
  }

  Future<void> _loadApiCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiUser = prefs.getString('clearocr_user') ?? '';
      _apiKey = prefs.getString('clearocr_key') ?? '';
    });
    if (_apiUser.isEmpty || _apiKey.isEmpty) {
      setState(() => _status = 'Najpierw ustaw dane API (kliknij "Ustawienia API").');
    }
  }

  Future<void> _openSettings() async {
    final userCtrl = TextEditingController(text: _apiUser);
    final keyCtrl = TextEditingController(text: _apiKey);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ustawienia API clearOCR'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: userCtrl,
              decoration: const InputDecoration(
                labelText: 'API User (np. prezesib@gmail.com)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: keyCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('clearocr_user', userCtrl.text.trim());
              await prefs.setString('clearocr_key', keyCtrl.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
              setState(() {
                _apiUser = userCtrl.text.trim();
                _apiKey = keyCtrl.text.trim();
                _status = 'Dane API zapisane.';
              });
            },
            child: const Text('Zapisz'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImages() async {
    final picked = await _picker.pickMultiImage();
    if (picked.isEmpty) return;
    setState(() {
      _files
        ..clear()
        ..addAll(picked);
      _status = 'Wybrano ${_files.length} zdjec. Wskaz folder docelowy.';
    });
  }

  Future<void> _pickTargetDir() async {
    final dir = await _saf.pickDirectory();
    if (dir != null) {
      setState(() {
        _targetDir = dir;
        _status = 'Folder docelowy wybrany. Kliknij Konwertuj.';
      });
    }
  }

  Future<String?> _ocrWithClearOcr(String imagePath) async {
    if (_apiKey.isEmpty || _apiUser.isEmpty) {
      throw Exception('Brak danych API. Ustaw je w "Ustawienia API".');
    }

    final uri = Uri.parse('https://clearocr.teamquest.pl:60213/extract-document-parser');
    final request = http.MultipartRequest('POST', uri);
    request.headers['CLEAR-OCR-API-USER'] = _apiUser;
    request.headers['CLEAR-OCR-API-KEY'] = _apiKey;
    request.headers['CLEAR-OCR-API-VERSION'] = '0.1';

    request.files.add(await http.MultipartFile.fromPath(
      'file',
      imagePath,
      filename: imagePath.split('/').last,
    ));

    final streamedResponse = await request.send().timeout(const Duration(seconds: 60));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception('clearOCR error: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body);
    return (data['result']?['text'] ?? data['text'] ?? '').toString().trim();
  }

  Future<void> _convertAll() async {
    if (_files.isEmpty || _targetDir == null) {
      setState(() => _status = 'Najpierw wybierz zdjecia i folder docelowy.');
      return;
    }
    if (_apiKey.isEmpty || _apiUser.isEmpty) {
      setState(() => _status = 'Brak danych API. Ustaw je w "Ustawienia API".');
      return;
    }

    setState(() {
      _busy = true;
      _processedCount = 0;
      _status = 'Rozpoczynam konwersje...';
    });

    try {
      final pdfRegular = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      final pdfBold = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf'));

      for (int i = 0; i < _files.length; i++) {
        final f = _files[i];
        setState(() => _status = 'Przetwarzanie ${i + 1}/${_files.length}: OCR...');

        final ocrText = await _ocrWithClearOcr(f.path);
        if (ocrText == null || ocrText.isEmpty) {
          _processedCount++;
          continue;
        }

        final lines = ocrText.split('\n').map((l) => l.trimRight()).toList();
        int titleIdx = lines.indexWhere((l) => l.trim().isNotEmpty);
        if (titleIdx < 0) titleIdx = 0;
        final title = lines[titleIdx].trim();
        final body = lines.sublist(titleIdx + 1).join('\n').trim();

        final pdf = pw.Document();
        const pageFormat = PdfPageFormat.a4;
        const margin = 40.0;
        final maxWidth = pageFormat.width - margin * 2;
        final maxHeight = pageFormat.height - margin * 2;

        final titleBlock = pw.Text(title, style: pw.TextStyle(font: pdfBold, fontSize: 32));
        final titleHeight = (title.length / 30).ceil() * 40.0 + 20;

        double bodyFontSize = 28;
        while (bodyFontSize > 6) {
          final approxCharsPerLine = (maxWidth / (bodyFontSize * 0.5)).floor();
          final approxLines = body.split('\n').map((l) => l.isEmpty ? 1 : (l.length / approxCharsPerLine).ceil()).fold<int>(0, (a, b) => a + b);
          final approxHeight = approxLines * bodyFontSize * 1.3;
          if (approxHeight + titleHeight <= maxHeight) break;
          bodyFontSize -= 1;
        }

        pdf.addPage(pw.Page(
          pageFormat: pageFormat,
          margin: const pw.EdgeInsets.all(margin),
          build: (ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              titleBlock,
              pw.SizedBox(height: 20),
              pw.Expanded(
                child: pw.Align(
                  alignment: pw.Alignment.topLeft,
                  child: pw.Text(body, style: pw.TextStyle(font: pdfRegular, fontSize: bodyFontSize)),
                ),
              ),
            ],
          ),
        ));

        String safeTitle = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
        if (safeTitle.isEmpty) safeTitle = 'piosenka_${i + 1}';

        String fileName = '$safeTitle.pdf';
        int counter = 2;
        while (true) {
          final existing = await _saf.list(_targetDir!.uri);
          if (!existing.any((e) => e.name == fileName)) break;
          fileName = '${safeTitle}_$counter.pdf';
          counter++;
        }

        final pdfBytes = await pdf.save();
        await _saf.writeFileBytes(_targetDir!.uri, fileName, 'application/pdf', pdfBytes);
        _processedCount++;
      }

      setState(() {
        _busy = false;
        _status = 'Gotowe. Zapisano $_processedCount plikow PDF.';
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _status = 'Blad: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('JPG/PNG do PDF (clearOCR)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Ustawienia API',
            onPressed: _busy ? null : _openSettings,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _pickImages,
              icon: const Icon(Icons.photo_library),
              label: Text(_files.isEmpty ? '1. Wybierz zdjecia z galerii' : 'Wybrano ${_files.length} zdjec'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _pickTargetDir,
              icon: const Icon(Icons.save_alt),
              label: Text(_targetDir == null ? '2. Wskaz folder na PDF-y' : 'Cel: ${_targetDir!.name}'),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: (_busy || _files.isEmpty || _targetDir == null) ? null : _convertAll,
              icon: const Icon(Icons.play_arrow),
              label: const Text('3. Konwertuj'),
            ),
            const SizedBox(height: 20),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Expanded(child: SingleChildScrollView(child: Text(_status))),
          ],
        ),
      ),
    );
  }
}
