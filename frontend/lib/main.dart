import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

const String _kBackendHost = '127.0.0.1';
const int _kBackendPort = 8001;
final Uri _kBackendHealthUri = Uri(
  scheme: 'http',
  host: _kBackendHost,
  port: _kBackendPort,
  path: '/health',
);
const Duration _kHealthPollInterval = Duration(seconds: 1);
const Duration _kHealthWaitTimeout = Duration(seconds: 15);
const Duration _kHealthRequestTimeout = Duration(seconds: 2);

final backendHostProvider = ChangeNotifierProvider<BackendHostController>(
  (ref) => throw StateError('backendHostProvider must be overridden in main()'),
);

Future<bool> isBackendPortAcceptingConnections() async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      _kBackendHost,
      _kBackendPort,
      timeout: const Duration(seconds: 1),
    );
    return true;
  } catch (_) {
    return false;
  } finally {
    socket?.destroy();
  }
}

/// Returns true once the FastAPI app responds with HTTP 200 on `/health`.
Future<bool> pingBackendHealth() async {
  try {
    final response = await http
        .get(_kBackendHealthUri)
        .timeout(_kHealthRequestTimeout);
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// Owns the packaged `backend.exe` child process (Windows), port readiness,
/// and cooperative shutdown when the desktop window closes.
class BackendHostController extends ChangeNotifier {
  Process? _process;
  bool _ownsProcess = false;
  bool _canSendHttp = false;
  String? _bootstrapMessage;

  bool get canSendHttp => _canSendHttp;

  /// Shown when the backend is unavailable or failed to start.
  String? get bootstrapMessage => _bootstrapMessage;

  Future<void> bootstrap() async {
    _canSendHttp = false;

    if (!Platform.isWindows) {
      _ownsProcess = false;
      _bootstrapMessage = null;
      notifyListeners();
      return;
    }

    if (await isBackendPortAcceptingConnections()) {
      _ownsProcess = false;
      _bootstrapMessage = null;
      notifyListeners();
      return;
    }

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final backendExe = p.join(exeDir, 'backend.exe');
    if (!await File(backendExe).exists()) {
      _bootstrapMessage =
          'backend.exe was not found next to the application:\n$backendExe';
      notifyListeners();
      return;
    }

    try {
      _process = await Process.start(
        backendExe,
        const <String>[],
        workingDirectory: exeDir,
        mode: ProcessStartMode.normal,
      );
      _ownsProcess = true;
    } catch (e) {
      _bootstrapMessage = 'Failed to start backend.exe: $e';
      notifyListeners();
      return;
    }

    _bootstrapMessage = null;
    notifyListeners();
  }

  /// Polls [pingBackendHealth] until success or [_kHealthWaitTimeout] elapses.
  Future<bool> waitForBackendHttpReady() async {
    final deadline = DateTime.now().add(_kHealthWaitTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await pingBackendHealth()) {
        _canSendHttp = true;
        _bootstrapMessage = null;
        notifyListeners();
        return true;
      }
      await Future<void>.delayed(_kHealthPollInterval);
    }
    _canSendHttp = false;
    _bootstrapMessage =
        'Failed to initialize the local engine. Please restart the application or check if port 8001 is in use.';
    if (_ownsProcess) {
      await shutdownOwned();
    }
    notifyListeners();
    return false;
  }

  /// Stops [backend.exe] if this app started it (avoids killing a separately
  /// launched dev server).
  Future<void> shutdownOwned() async {
    if (!_ownsProcess || _process == null) {
      return;
    }
    final proc = _process!;
    _process = null;
    _ownsProcess = false;
    try {
      proc.kill(ProcessSignal.sigterm);
    } catch (_) {
      // Already exited.
    }
    try {
      await proc.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
  }

  final backendHost = BackendHostController();

  runApp(
    ProviderScope(
      overrides: [backendHostProvider.overrideWith((ref) => backendHost)],
      child: const App(),
    ),
  );
}

class ImagePathsNotifier extends StateNotifier<List<String>> {
  ImagePathsNotifier() : super(const []);

  String _normalizePath(String rawPath) => p.normalize(rawPath);

  Future<void> pickFolderAndLoadJpegs() async {
    final selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Folder with JPEG Images',
    );
    if (selectedDirectory == null) {
      return;
    }

    final directory = Directory(selectedDirectory);
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => _isJpeg(file.path))
            .map((file) => _normalizePath(file.path))
            .toList()
          ..sort();

    state = files;
  }

  bool _isJpeg(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    return ext == '.jpg' || ext == '.jpeg';
  }
}

class SelectedImagesNotifier extends StateNotifier<Set<String>> {
  SelectedImagesNotifier() : super(<String>{});

  String _normalizePath(String rawPath) => p.normalize(rawPath);

  void toggle(String filePath) {
    final normalizedPath = _normalizePath(filePath);
    final next = {...state};
    if (next.contains(normalizedPath)) {
      next.remove(normalizedPath);
    } else {
      next.add(normalizedPath);
    }
    state = next;
  }

  void clear() {
    state = <String>{};
  }
}

class TagsNotifier extends StateNotifier<Map<String, String>> {
  TagsNotifier() : super(<String, String>{});

  String _normalizePath(String rawPath) => p.normalize(rawPath);

  void assignTagToSelection({
    required Set<String> selectedPaths,
    required String vipName,
  }) {
    if (vipName.trim().isEmpty || selectedPaths.isEmpty) {
      return;
    }

    final normalizedVip = vipName.trim();
    final next = {...state};
    for (final filePath in selectedPaths) {
      next[_normalizePath(filePath)] = normalizedVip;
    }
    state = next;
  }

  Map<String, String> filenameToVipMap() {
    return {
      for (final entry in state.entries) p.basename(entry.key): entry.value,
    };
  }

  void clear() {
    state = <String, String>{};
  }
}

final loadedFilesProvider =
    StateNotifierProvider<ImagePathsNotifier, List<String>>(
      (ref) => ImagePathsNotifier(),
    );

final selectedFilesProvider =
    StateNotifierProvider<SelectedImagesNotifier, Set<String>>(
      (ref) => SelectedImagesNotifier(),
    );

final taggedFilesProvider =
    StateNotifierProvider<TagsNotifier, Map<String, String>>(
      (ref) => TagsNotifier(),
    );

// Backward-compatible aliases for existing references.
final imagePathsProvider = loadedFilesProvider;
final selectedImagesProvider = selectedFilesProvider;
final tagsProvider = taggedFilesProvider;

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> with WindowListener {
  static bool get _manageWindowClose => !kIsWeb && Platform.isWindows;

  @override
  void initState() {
    super.initState();
    if (_manageWindowClose) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    if (_manageWindowClose) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() {
    if (!_manageWindowClose) {
      return;
    }
    unawaited(_shutdownBackendAndCloseWindow());
  }

  Future<void> _shutdownBackendAndCloseWindow() async {
    await ref.read(backendHostProvider).shutdownOwned();
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'VIP Tagger',
      theme: ThemeData.dark(),
      home: const StartupGate(child: HomePage()),
    );
  }
}

enum _StartupGatePhase { loading, ready, error }

/// Runs [BackendHostController.bootstrap], then HTTP health polling before
/// revealing [child].
class StartupGate extends ConsumerStatefulWidget {
  const StartupGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<StartupGate> {
  _StartupGatePhase _phase = _StartupGatePhase.loading;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runStartup());
    });
  }

  Future<void> _runStartup() async {
    final backend = ref.read(backendHostProvider);
    await backend.bootstrap();

    if (!mounted) {
      return;
    }

    if (backend.bootstrapMessage != null) {
      setState(() {
        _phase = _StartupGatePhase.error;
        _errorText = backend.bootstrapMessage;
      });
      return;
    }

    final ok = await backend.waitForBackendHttpReady();
    if (!mounted) {
      return;
    }

    if (ok) {
      setState(() => _phase = _StartupGatePhase.ready);
    } else {
      setState(() {
        _phase = _StartupGatePhase.error;
        _errorText = backend.bootstrapMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _StartupGatePhase.ready:
        return widget.child;
      case _StartupGatePhase.loading:
        return const _FullScreenStartupOverlay(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              SizedBox(height: 24),
              Text(
                'Initializing AI Engine...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        );
      case _StartupGatePhase.error:
        return _FullScreenStartupOverlay(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
                const SizedBox(height: 20),
                Text(
                  _errorText ??
                      'Failed to initialize the local engine. Please restart the application or check if port 8001 is in use.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.4,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        );
    }
  }
}

class _FullScreenStartupOverlay extends StatelessWidget {
  const _FullScreenStartupOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12131A),
      body: Center(child: child),
    );
  }
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  static final Uri _scanBadgeUri = Uri.parse(
    'http://127.0.0.1:8001/scan-badge',
  );
  static final Uri _processBatchUri = Uri.parse(
    'http://127.0.0.1:8001/process-batch',
  );
  static const Set<String> _scanFailureTokens = {
    'ERROR_READING_TEXT',
    'SERVER_ERROR',
  };

  final _tagController = TextEditingController();
  final _leftSidebarWidth = 250.0;
  final _rightSidebarWidth = 300.0;
  bool _isScanning = false;
  bool _isProcessingBatch = false;

  @override
  void dispose() {
    _tagController.dispose();
    super.dispose();
  }

  void _assignTag() {
    final selectedPaths = ref.read(selectedFilesProvider);
    final vipName = _tagController.text;
    ref
        .read(taggedFilesProvider.notifier)
        .assignTagToSelection(selectedPaths: selectedPaths, vipName: vipName);
  }

  void _process() {
    _processBatch();
  }

  void _showScanFailedSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Scan Failed: Please check your internet connection or try a clearer photo.',
        ),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showNoOcrTextSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Scan Failed: No text detected in the image.'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _scanSelectedAnchorPhoto() async {
    final selectedPaths = ref.read(selectedFilesProvider).toList();
    if (selectedPaths.isEmpty) {
      return;
    }

    final selectedPath = selectedPaths.first;
    setState(() {
      _isScanning = true;
    });

    try {
      final request = http.MultipartRequest('POST', _scanBadgeUri)
        ..files.add(await http.MultipartFile.fromPath('file', selectedPath));
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200) {
        throw HttpException(
          'Scan failed with status ${response.statusCode}: ${response.body}',
        );
      }

      final decodedBody = jsonDecode(response.body);
      if (decodedBody is! Map<String, dynamic>) {
        throw const FormatException(
          'Unexpected JSON response from scan endpoint',
        );
      }

      final raw = decodedBody['extracted_text'];
      final extractedText = raw == null ? '' : raw.toString().trim();
      if (!mounted) {
        return;
      }

      if (_scanFailureTokens.contains(extractedText)) {
        _showScanFailedSnackBar();
        return;
      }

      if (extractedText.isEmpty) {
        _showNoOcrTextSnackBar();
        return;
      }

      setState(() {
        _tagController.text = extractedText;
        _tagController.selection = TextSelection.fromPosition(
          TextPosition(offset: _tagController.text.length),
        );
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not scan image. Is FastAPI running on 127.0.0.1:8001?',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  Future<void> _processBatch() async {
    final tags = ref.read(taggedFilesProvider);
    if (tags.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tagged images to process.')),
      );
      return;
    }

    setState(() {
      _isProcessingBatch = true;
    });

    try {
      final payload = {'manifest': tags};
      final response = await http.post(
        _processBatchUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode != 200) {
        throw HttpException(
          'Process batch failed with status ${response.statusCode}: ${response.body}',
        );
      }

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Metadata injected successfully!')),
      );
      // Optional UX: clear after successful processing.
      ref.read(taggedFilesProvider.notifier).clear();
      ref.read(selectedFilesProvider.notifier).clear();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Batch processing failed. Is FastAPI running on 127.0.0.1:8001?',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isProcessingBatch = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final imagePaths = ref.watch(loadedFilesProvider);
    final selected = ref.watch(selectedFilesProvider);
    final tags = ref.watch(taggedFilesProvider);
    final backend = ref.watch(backendHostProvider);
    const sidebarColor = Color(0xFF1E1F24);
    const contentColor = Color(0xFF272932);

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!backend.canSendHttp)
            Material(
              color: Colors.amber.shade900,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Text(
                  backend.bootstrapMessage ??
                      'Backend is not ready on $_kBackendHost:$_kBackendPort. '
                          'Scan and batch actions are disabled.',
                  style: const TextStyle(color: Colors.black87),
                ),
              ),
            ),
          Expanded(
            child: Row(
              children: [
                Container(
                  width: _leftSidebarWidth,
                  color: sidebarColor,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ElevatedButton(
                        onPressed: () async => ref
                            .read(loadedFilesProvider.notifier)
                            .pickFolderAndLoadJpegs(),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: const Text('Select Folder'),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: ListView.separated(
                          itemCount: imagePaths.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final filePath = imagePaths[index];
                            final isSelected = selected.contains(filePath);
                            return ListTile(
                              dense: true,
                              title: Text(
                                p.basename(filePath),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              selected: isSelected,
                              onTap: () => ref
                                  .read(selectedFilesProvider.notifier)
                                  .toggle(filePath),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Container(
                    color: contentColor,
                    padding: const EdgeInsets.all(16),
                    child: imagePaths.isEmpty
                        ? const Center(
                            child: Text(
                              'No JPEG files loaded',
                              style: TextStyle(fontSize: 18),
                            ),
                          )
                        : GridView.builder(
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 260,
                                  childAspectRatio: 0.95,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                ),
                            itemCount: imagePaths.length,
                            itemBuilder: (context, index) {
                              final filePath = imagePaths[index];
                              final fileName = p.basename(filePath);
                              final isSelected = selected.contains(filePath);
                              final assignedTag = tags[filePath];

                              return InkWell(
                                onTap: () => ref
                                    .read(selectedFilesProvider.notifier)
                                    .toggle(filePath),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1B1D24),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isSelected
                                          ? const Color(0xFF1EA7FF)
                                          : Colors.white24,
                                      width: isSelected ? 3 : 1,
                                    ),
                                  ),
                                  padding: const EdgeInsets.all(8),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          child: Image.file(
                                            File(filePath),
                                            fit: BoxFit.cover,
                                            width: double.infinity,
                                            errorBuilder: (_, _, _) =>
                                                Container(
                                                  color: Colors.black38,
                                                  alignment: Alignment.center,
                                                  child: const Text(
                                                    'Preview N/A',
                                                  ),
                                                ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        fileName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        assignedTag == null
                                            ? 'Tag: (none)'
                                            : 'Tag: $assignedTag',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                Container(
                  width: _rightSidebarWidth,
                  color: sidebarColor,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Anchor Scanner',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed:
                            selected.isEmpty ||
                                _isScanning ||
                                !backend.canSendHttp
                            ? null
                            : _scanSelectedAnchorPhoto,
                        child: _isScanning
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Scan Selected Anchor Photo'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _tagController,
                        decoration: const InputDecoration(
                          labelText: 'VIP Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _assignTag,
                        child: const Text('Assign Name to Selected'),
                      ),
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 8),
                      Text(
                        'Loaded: ${imagePaths.length}  Selected: ${selected.length}  Tagged: ${tags.length}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const Spacer(),
                      SizedBox(
                        height: 64,
                        child: ElevatedButton(
                          onPressed: _isProcessingBatch || !backend.canSendHttp
                              ? null
                              : _process,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1EA7FF),
                            foregroundColor: Colors.black,
                            textStyle: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          child: _isProcessingBatch
                              ? const SizedBox(
                                  height: 24,
                                  width: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                  ),
                                )
                              : const Text('Process Batch'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
