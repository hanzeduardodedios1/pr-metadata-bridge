import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

late final String backendBaseUrl;
late final String _kBackendHost;
late final int _kBackendPort;
late final Uri _kProxyScanUri;
late final Uri _kBackendHealthUri;
late final bool _kSkipHealthCheck;
late final String _kProxyApiKey;
const Duration _kHealthPollInterval = Duration(seconds: 1);
const Duration _kHealthWaitTimeout = Duration(seconds: 15);
const Duration _kHealthRequestTimeout = Duration(seconds: 2);
const Duration _kBackendGracefulShutdownTimeout = Duration(seconds: 2);
const Duration _kBackendForceShutdownTimeout = Duration(seconds: 1);
const Color _kBrutalistBackground = Color(0xFF282828);
const Color _kBrutalistSidebar = Color(0xFF1E1E1E);
const Color _kBrutalistBorder = Color(0xFF2A2A2A);
const Color _kBrutalistPrimaryText = Colors.white;
const Color _kBrutalistSecondaryText = Color(0xFF8B8C90);
const Color _kBrutalistButton = Color(0xFF3D7AB5);
const Color _kStartupBackground = Color(0xFF1E1E1E);
const Color _kStartupDivider = Color(0xFF2A2A2A);
const double _kLabelFontSize = 11;
const double _kInputFontSize = 13;
const double _kSectionHeaderFontSize = 15;
const double _kPanelTitleFontSize = 18;

final backendHostProvider = ChangeNotifierProvider<BackendHostController>(
  (ref) => throw StateError('backendHostProvider must be overridden in main()'),
);

Never _fatalEnvMissing([Object? cause]) {
  final details = cause == null ? '' : '\nCause: $cause';
  throw StateError(
    'ENV FILE MISSING\n'
    'ENV FILE MISSING\n'
    'ENV FILE MISSING\n'
    'Missing required dotenv configuration. '
    'Expected dotenv.env[\'PROXY_URL\'] to be present.$details',
  );
}

void _initializeBackendConfigFromEnv() {
  final proxyUrl = dotenv.env['PROXY_URL']?.trim();
  if (proxyUrl == null || proxyUrl.isEmpty) {
    _fatalEnvMissing('PROXY_URL is null or empty.');
  }

  final parsedBaseUri = Uri.tryParse(proxyUrl);
  if (parsedBaseUri == null ||
      !parsedBaseUri.hasScheme ||
      parsedBaseUri.host.isEmpty) {
    _fatalEnvMissing('PROXY_URL is not a valid absolute URL: $proxyUrl');
  }
  final scheme = parsedBaseUri.scheme.toLowerCase();
  final host = parsedBaseUri.host.toLowerCase();
  final isLocalHost =
      host == 'localhost' || host == '127.0.0.1' || host == '::1';
  if (scheme != 'https' && !isLocalHost) {
    _fatalEnvMissing(
      'PROXY_URL must use https for non-local endpoints. Got: $proxyUrl',
    );
  }

  _kProxyScanUri = parsedBaseUri.replace(queryParameters: const {});
  final origin = Uri(
    scheme: parsedBaseUri.scheme,
    host: parsedBaseUri.host,
    port: parsedBaseUri.hasPort ? parsedBaseUri.port : null,
  );
  backendBaseUrl = origin.toString().replaceFirst(RegExp(r'/+$'), '');
  _kBackendHost = parsedBaseUri.host;
  _kBackendPort = parsedBaseUri.hasPort
      ? parsedBaseUri.port
      : (parsedBaseUri.scheme == 'https' ? 443 : 80);
  _kBackendHealthUri = origin.replace(path: '/', query: '');
  _kSkipHealthCheck = parsedBaseUri.pathSegments.isNotEmpty;
  _kProxyApiKey = dotenv.env['PROXY_API_KEY']?.trim() ?? '';
}

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
    debugPrint(
      'Health check response: status=${response.statusCode}, body=${response.body}',
    );
    return response.statusCode == 200;
  } catch (error) {
    debugPrint('Health check request failed: $error');
    return false;
  }
}

/// Owns the packaged `backend.exe` child process (Windows), port readiness,
/// and cooperative shutdown when the desktop window closes.
class BackendHostController extends ChangeNotifier {
  Process? _process;
  bool _ownsProcess = false;
  bool _isShuttingDown = false;
  Future<void>? _shutdownFuture;
  bool _canSendHttp = false;
  String? _bootstrapMessage;
  StreamSubscription<List<int>>? _stdoutSubscription;
  StreamSubscription<List<int>>? _stderrSubscription;

  bool get canSendHttp => _canSendHttp;

  /// Shown when the backend is unavailable or failed to start.
  String? get bootstrapMessage => _bootstrapMessage;

  /// Explicitly asks the owned backend process to terminate.
  /// This is used by the window close path before destroying the Flutter UI.
  void requestOwnedProcessKill() {
    final proc = _process;
    if (!_ownsProcess || proc == null) {
      return;
    }
    try {
      proc.kill(ProcessSignal.sigterm);
    } catch (_) {
      // Best effort: process may already be gone.
    }
  }

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
    debugPrint('Backend spawn path: $backendExe');
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
      // Drain child process pipes so the backend cannot block on full buffers.
      _stdoutSubscription = _process!.stdout.listen((_) {});
      _stderrSubscription = _process!.stderr.listen((_) {});
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
    if (_kSkipHealthCheck) {
      debugPrint(
        'Health check skipped for endpoint-style PROXY_URL. '
        'Using direct scan URL: $_kProxyScanUri',
      );
      _canSendHttp = true;
      _bootstrapMessage = null;
      notifyListeners();
      return true;
    }

    final deadline = DateTime.now().add(_kHealthWaitTimeout);
    var attempt = 1;
    while (DateTime.now().isBefore(deadline)) {
      final isHealthy = await pingBackendHealth();
      debugPrint('Health check attempt $attempt result: $isHealthy');
      if (isHealthy) {
        _canSendHttp = true;
        _bootstrapMessage = null;
        notifyListeners();
        return true;
      }
      attempt += 1;
      await Future<void>.delayed(_kHealthPollInterval);
    }
    _canSendHttp = false;
    _bootstrapMessage =
        'Failed to initialize the local engine. Please restart the application or check if port $_kBackendPort is in use.';
    if (_ownsProcess) {
      await shutdownOwned();
    }
    notifyListeners();
    return false;
  }

  /// Stops [backend.exe] if this app started it (avoids killing a separately
  /// launched dev server).
  Future<void> shutdownOwned() async {
    if (_shutdownFuture != null) {
      await _shutdownFuture;
      return;
    }
    if (_isShuttingDown || !_ownsProcess || _process == null) {
      return;
    }

    _shutdownFuture = _shutdownOwnedInternal();
    try {
      await _shutdownFuture;
    } finally {
      _shutdownFuture = null;
    }
  }

  Future<void> _shutdownOwnedInternal() async {
    _isShuttingDown = true;
    final proc = _process!;
    _process = null;
    _ownsProcess = false;

    try {
      // Ask the backend to exit gracefully first.
      proc.kill(ProcessSignal.sigterm);
    } catch (_) {
      // Already exited.
    }

    final stdoutSubscription = _stdoutSubscription;
    final stderrSubscription = _stderrSubscription;
    _stdoutSubscription = null;
    _stderrSubscription = null;
    await stdoutSubscription?.cancel();
    await stderrSubscription?.cancel();

    try {
      await proc.exitCode.timeout(_kBackendGracefulShutdownTimeout);
    } on TimeoutException {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {
        // Process may have exited between timeout and kill attempt.
      }
      try {
        await proc.exitCode.timeout(_kBackendForceShutdownTimeout);
      } catch (_) {
        // Best-effort shutdown complete.
      }
    } finally {
      _isShuttingDown = false;
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: 'assets/env/app.env');
  } catch (error) {
    _fatalEnvMissing(error);
  }
  _initializeBackendConfigFromEnv();

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

  Future<bool> pickFolderAndLoadJpegs() async {
    final selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Folder with JPEG Images',
    );
    if (selectedDirectory == null) {
      return false;
    }

    loadJpegsFromDirectory(selectedDirectory);
    return true;
  }

  void loadJpegsFromDirectory(String selectedDirectory) {
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

  void clear() {
    state = const [];
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

Map<String, String> _jsonHeadersWithApiKey() {
  final headers = <String, String>{'Content-Type': 'application/json'};
  if (_kProxyApiKey.isNotEmpty) {
    headers['X-API-Key'] = _kProxyApiKey;
  }
  return headers;
}

Map<String, String> _authHeadersWithApiKey() {
  if (_kProxyApiKey.isEmpty) {
    return const <String, String>{};
  }
  return <String, String>{'X-API-Key': _kProxyApiKey};
}

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App>
    with WindowListener, WidgetsBindingObserver {
  static bool get _manageWindowClose => !kIsWeb && Platform.isWindows;
  bool _isShuttingDown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_manageWindowClose) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_manageWindowClose) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (!_manageWindowClose || _isShuttingDown) {
      return;
    }
    await _beginShutdown();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_beginShutdown());
    }
  }

  Future<void> _beginShutdown() async {
    if (_isShuttingDown) {
      return;
    }
    _isShuttingDown = true;
    try {
      ref.read(backendHostProvider).requestOwnedProcessKill();
      await ref.read(backendHostProvider).shutdownOwned();
      if (_manageWindowClose) {
        await windowManager.setPreventClose(false);
      }
      exit(0);
    } catch (_) {
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'VIP Tagger',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _kBrutalistBackground,
        canvasColor: _kBrutalistBackground,
        colorScheme: const ColorScheme.dark(
          surface: _kBrutalistBackground,
          primary: _kBrutalistButton,
          onPrimary: _kBrutalistPrimaryText,
          onSurface: _kBrutalistPrimaryText,
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(
            color: _kBrutalistPrimaryText,
            fontSize: _kInputFontSize,
          ),
          bodyMedium: TextStyle(
            color: _kBrutalistPrimaryText,
            fontSize: _kInputFontSize,
          ),
          titleLarge: TextStyle(
            color: _kBrutalistPrimaryText,
            fontWeight: FontWeight.w600,
            fontSize: _kPanelTitleFontSize,
          ),
        ),
        dividerColor: _kBrutalistBorder,
        shadowColor: Colors.transparent,
        splashColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        appBarTheme: const AppBarTheme(
          elevation: 0,
          shadowColor: Colors.transparent,
          backgroundColor: _kBrutalistBackground,
        ),
        cardTheme: const CardThemeData(
          color: _kBrutalistBackground,
          elevation: 0,
          shadowColor: Colors.transparent,
          margin: EdgeInsets.zero,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            shadowColor: Colors.transparent,
            backgroundColor: _kBrutalistButton,
            foregroundColor: _kBrutalistPrimaryText,
            disabledBackgroundColor: const Color(0xFF353535),
            disabledForegroundColor: const Color(0xFF6D6E73),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
              side: BorderSide(color: _kBrutalistBorder, width: 1),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: _kBrutalistPrimaryText,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
              side: BorderSide(color: _kBrutalistBorder, width: 1),
            ),
          ),
        ),
        listTileTheme: const ListTileThemeData(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          labelStyle: TextStyle(color: _kBrutalistSecondaryText),
          hintStyle: TextStyle(
            color: _kBrutalistSecondaryText,
            fontSize: _kInputFontSize,
          ),
          filled: true,
          fillColor: _kBrutalistSidebar,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: _kBrutalistBorder, width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: _kBrutalistPrimaryText, width: 1),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: _kBrutalistBorder, width: 1),
          ),
        ),
      ),
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
  static const List<String> _kStartupStatusMessages = <String>[
    'Starting backend engine...',
    'Connecting to Vision API...',
    'Ready.',
  ];

  _StartupGatePhase _phase = _StartupGatePhase.loading;
  String? _errorText;
  String _statusMessage = _kStartupStatusMessages.first;
  Timer? _statusTimer;
  int _statusMessageIndex = 0;

  @override
  void initState() {
    super.initState();
    _startStatusMessageRotation();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runStartup());
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  void _startStatusMessageRotation() {
    _statusTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!mounted || _phase != _StartupGatePhase.loading) {
        return;
      }

      setState(() {
        _statusMessageIndex = (_statusMessageIndex + 1) % 2;
        _statusMessage = _kStartupStatusMessages[_statusMessageIndex];
      });
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
      _statusTimer?.cancel();
      setState(() {
        _statusMessageIndex = 2;
        _statusMessage = _kStartupStatusMessages[_statusMessageIndex];
      });
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) {
        return;
      }
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
        return _FullScreenStartupOverlay(
          child: Stack(
            alignment: Alignment.center,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.camera, size: 48, color: _kBrutalistButton),
                  const SizedBox(height: 12),
                  const Text(
                    'CaptionFast',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Professional Event Photo Captioning',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: _kBrutalistSecondaryText,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Container(width: 40, height: 1, color: _kStartupDivider),
                  const SizedBox(height: 32),
                  const SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: _kBrutalistButton,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _statusMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      color: _kBrutalistSecondaryText,
                    ),
                  ),
                ],
              ),
              const Positioned(
                bottom: 24,
                child: Text(
                  'v0.1.0-beta',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: _kBrutalistSecondaryText,
                    fontWeight: FontWeight.w400,
                  ),
                ),
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
                      'Failed to initialize the local engine. Please restart the application or check if port $_kBackendPort is in use.',
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
      backgroundColor: _kStartupBackground,
      body: Center(child: child),
    );
  }
}

class _PrimaryActionButton extends StatefulWidget {
  const _PrimaryActionButton({
    required this.onPressed,
    required this.child,
    this.padding,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  State<_PrimaryActionButton> createState() => _PrimaryActionButtonState();
}

class _PrimaryActionButtonState extends State<_PrimaryActionButton> {
  bool _hovering = false;
  bool _pressed = false;

  double get _scale {
    if (_pressed) {
      return 0.98;
    }
    if (_hovering) {
      return 1.015;
    }
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) {
        setState(() {
          _hovering = false;
          _pressed = false;
        });
      },
      child: GestureDetector(
        onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
        onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
        onTapCancel: disabled ? null : () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 170),
          curve: Curves.easeOutBack,
          child: ElevatedButton(
            onPressed: widget.onPressed,
            style: ElevatedButton.styleFrom(
              padding:
                  widget.padding ??
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends StatelessWidget {
  const _DashedBorder({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _DashedBorderPainter(),
      child: child,
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const color = _kBrutalistBorder;
    const strokeWidth = 1.0;
    const dashLength = 8.0;
    const gapLength = 6.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    void drawDashedLine(Offset start, Offset end) {
      final dx = end.dx - start.dx;
      final dy = end.dy - start.dy;
      final distance = dx.abs() + dy.abs();
      final directionX = distance == 0 ? 0.0 : dx / distance;
      final directionY = distance == 0 ? 0.0 : dy / distance;
      double drawn = 0;
      while (drawn < distance) {
        final dashEnd = (drawn + dashLength).clamp(0, distance);
        final p1 = Offset(
          start.dx + directionX * drawn,
          start.dy + directionY * drawn,
        );
        final p2 = Offset(
          start.dx + directionX * dashEnd,
          start.dy + directionY * dashEnd,
        );
        canvas.drawLine(p1, p2, paint);
        drawn += dashLength + gapLength;
      }
    }

    final left = strokeWidth / 2;
    final top = strokeWidth / 2;
    final right = size.width - strokeWidth / 2;
    final bottom = size.height - strokeWidth / 2;

    drawDashedLine(Offset(left, top), Offset(right, top));
    drawDashedLine(Offset(right, top), Offset(right, bottom));
    drawDashedLine(Offset(right, bottom), Offset(left, bottom));
    drawDashedLine(Offset(left, bottom), Offset(left, top));
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) {
    return false;
  }
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  static Uri get _scanUri => _kProxyScanUri;
  static final Uri _processBatchUri = Uri.parse(
    '$backendBaseUrl/process-batch',
  );
  static const Set<String> _scanFailureTokens = {
    'ERROR_READING_TEXT',
    'SERVER_ERROR',
  };
  static const Map<String, String> _kImageSubtypeByExtension = {
    '.jpg': 'jpeg',
    '.jpeg': 'jpeg',
    '.png': 'png',
    '.gif': 'gif',
    '.webp': 'webp',
    '.bmp': 'bmp',
  };

  final _tagController = TextEditingController();
  bool _isScanning = false;
  bool _isProcessingBatch = false;
  bool _showProcessSuccess = false;
  Timer? _processSuccessTimer;

  @override
  void dispose() {
    _processSuccessTimer?.cancel();
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

  String? _activeFolderBreadcrumb(List<String> imagePaths) {
    if (imagePaths.isEmpty) {
      return null;
    }
    var folderPath = p.normalize(p.dirname(imagePaths.first));
    final homePath =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (homePath != null && homePath.isNotEmpty) {
      final normalizedHome = p.normalize(homePath);
      if (folderPath.toLowerCase().startsWith(normalizedHome.toLowerCase())) {
        folderPath = '~${folderPath.substring(normalizedHome.length)}';
      }
    }
    if (!folderPath.endsWith(p.separator)) {
      folderPath = '$folderPath${p.separator}';
    }
    return folderPath.replaceAll('\\', '/');
  }

  void _clearCurrentSelectionAndTags() {
    ref.read(selectedFilesProvider.notifier).clear();
    setState(() {
      _tagController.clear();
    });
  }

  Future<void> _pickFolderFromBreadcrumb() async {
    final tags = ref.read(taggedFilesProvider);
    if (tags.isNotEmpty) {
      final shouldDiscard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Discard tagged photos?'),
            content: Text(
              "You have ${tags.length} tagged photos that haven't been processed.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Load Anyway'),
              ),
            ],
          );
        },
      );
      if (shouldDiscard != true) {
        return;
      }
    }

    final selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Folder with JPEG Images',
    );
    if (selectedDirectory == null) {
      return;
    }

    ref.read(loadedFilesProvider.notifier).clear();
    ref.read(selectedFilesProvider.notifier).clear();
    ref.read(taggedFilesProvider.notifier).clear();
    setState(() {
      _showProcessSuccess = false;
      _tagController.clear();
    });
    ref.read(loadedFilesProvider.notifier).loadJpegsFromDirectory(
      selectedDirectory,
    );
  }

  void _showProcessSuccessState() {
    _processSuccessTimer?.cancel();
    setState(() {
      _showProcessSuccess = true;
    });
    _processSuccessTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showProcessSuccess = false;
      });
    });
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

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  MediaType _mediaTypeForImagePath(String filePath) {
    final extension = p.extension(filePath).toLowerCase();
    final subtype = _kImageSubtypeByExtension[extension] ?? 'jpeg';
    return MediaType('image', subtype);
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
      debugPrint('Sending scan request to $_scanUri');
      final imageContentType = _mediaTypeForImagePath(selectedPath);
      final request = http.MultipartRequest('POST', _scanUri)
        ..headers.addAll(_authHeadersWithApiKey())
        ..files.add(
          await http.MultipartFile.fromPath(
            'file',
            selectedPath,
            contentType: imageContentType,
          ),
        );
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      debugPrint('Scan response ${response.statusCode}: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception(
          'statusCode=${response.statusCode}, body=${response.body}',
        );
      }

      final decodedBody = jsonDecode(response.body);
      if (decodedBody is! Map<String, dynamic>) {
        throw const FormatException(
          'Unexpected JSON response from scan endpoint',
        );
      }

      final raw = decodedBody['text'];
      final extractedText = raw == null
          ? ''
          : raw.toString().replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
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
    } on SocketException {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar('Connection refused.');
    } on http.ClientException {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar('Connection refused.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar(error.toString());
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
      debugPrint('Sending batch request to $_processBatchUri');
      final response = await http.post(
        _processBatchUri,
        headers: _jsonHeadersWithApiKey(),
        body: jsonEncode(payload),
      );
      debugPrint('Batch response ${response.statusCode}: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception(
          'statusCode=${response.statusCode}, body=${response.body}',
        );
      }

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Metadata injected successfully!')),
      );
      _clearCurrentSelectionAndTags();
      ref.read(taggedFilesProvider.notifier).clear();
      _showProcessSuccessState();
    } on SocketException {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar('Connection refused.');
    } on http.ClientException {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar('Connection refused.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar(error.toString());
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
                Expanded(
                  flex: 7,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: _kBrutalistBackground,
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Builder(
                                builder: (context) {
                                  final breadcrumb =
                                      _activeFolderBreadcrumb(imagePaths);
                                  if (breadcrumb == null) {
                                    return const SizedBox.shrink();
                                  }
                                  return InkWell(
                                    onTap: _pickFolderFromBreadcrumb,
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.folder_open,
                                          size: 12,
                                          color: _kBrutalistSecondaryText,
                                        ),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            breadcrumb,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: _kBrutalistSecondaryText,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Expanded(
                          child: imagePaths.isEmpty
                              ? Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 700,
                                    ),
                                    child: _DashedBorder(
                                      child: InkWell(
                                        onTap: () async {
                                          await ref
                                              .read(
                                                loadedFilesProvider.notifier,
                                              )
                                              .pickFolderAndLoadJpegs();
                                        },
                                        child: Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 28,
                                            vertical: 72,
                                          ),
                                          child: const Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.add_photo_alternate_outlined,
                                                size: 54,
                                                color: _kBrutalistSecondaryText,
                                              ),
                                              SizedBox(height: 18),
                                              Text(
                                                'Drop folder here or click to browse',
                                                style: TextStyle(
                                                  color: _kBrutalistPrimaryText,
                                                  fontSize: _kPanelTitleFontSize,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                              SizedBox(height: 10),
                                              Text(
                                                '1. Load folder → 2. Select anchor → 3. Process',
                                                style: TextStyle(
                                                  color:
                                                      _kBrutalistSecondaryText,
                                                  fontSize: _kInputFontSize,
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : LayoutBuilder(
                                  builder: (context, constraints) {
                                    final crossAxisCount =
                                        (constraints.maxWidth / 220)
                                            .floor()
                                            .clamp(2, 8);
                                    return GridView.builder(
                                      gridDelegate:
                                          SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: crossAxisCount,
                                            childAspectRatio: 0.88,
                                            crossAxisSpacing: 12,
                                            mainAxisSpacing: 12,
                                          ),
                                      itemCount: imagePaths.length,
                                      itemBuilder: (context, index) {
                                        final filePath = imagePaths[index];
                                        final fileName = p.basename(filePath);
                                        final isSelected = selected.contains(
                                          filePath,
                                        );
                                        final assignedTag = tags[filePath];

                                        return InkWell(
                                          onTap: () => ref
                                              .read(selectedFilesProvider.notifier)
                                              .toggle(filePath),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: _kBrutalistSidebar,
                                              border: Border.all(
                                                color: isSelected
                                                    ? _kBrutalistButton
                                                    : _kBrutalistBorder,
                                                width: 1,
                                              ),
                                            ),
                                            padding: const EdgeInsets.all(8),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Expanded(
                                                  child: Image.file(
                                                    File(filePath),
                                                    fit: BoxFit.cover,
                                                    width: double.infinity,
                                                    errorBuilder:
                                                        (_, _, _) => Container(
                                                          color: const Color(
                                                            0xFF222224,
                                                          ),
                                                          alignment:
                                                              Alignment.center,
                                                          child: const Text(
                                                            'Preview N/A',
                                                            style: TextStyle(
                                                              color:
                                                                  _kBrutalistSecondaryText,
                                                              fontSize:
                                                                  _kLabelFontSize,
                                                            ),
                                                          ),
                                                        ),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  fileName,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color:
                                                        _kBrutalistPrimaryText,
                                                    fontSize: _kInputFontSize,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                Text(
                                                  assignedTag == null
                                                      ? 'Tag: (none)'
                                                      : 'Tag: $assignedTag',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color:
                                                        _kBrutalistSecondaryText,
                                                    fontSize: _kLabelFontSize,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(width: 1, color: _kBrutalistBorder),
                Expanded(
                  flex: 3,
                  child: Container(
                    color: _kBrutalistSidebar,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                          child: Text(
                            'Inspector',
                            style: TextStyle(
                              fontSize: _kPanelTitleFontSize,
                              fontWeight: FontWeight.w600,
                              color: _kBrutalistPrimaryText,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _MetricPill(
                                label: 'Loaded',
                                value: imagePaths.length,
                              ),
                              _MetricPill(
                                label: 'Selected',
                                value: selected.length,
                              ),
                              _MetricPill(label: 'Tagged', value: tags.length),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const _StepHeading(number: 1, label: 'Anchor'),
                                const SizedBox(height: 8),
                                _PrimaryActionButton(
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
                                            color: _kBrutalistPrimaryText,
                                          ),
                                        )
                                      : const Text('Scan Selected Anchor Photo'),
                                ),
                                const SizedBox(height: 20),
                                const Divider(height: 1, color: _kBrutalistBorder),
                                const SizedBox(height: 20),
                                const _StepHeading(number: 2, label: 'Subject'),
                                const SizedBox(height: 8),
                                const Text(
                                  'Subject Name',
                                  style: TextStyle(
                                    fontSize: _kLabelFontSize,
                                    color: _kBrutalistSecondaryText,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                TextField(
                                  controller: _tagController,
                                  style: const TextStyle(
                                    fontSize: _kInputFontSize,
                                  ),
                                  decoration: const InputDecoration(
                                    hintText: 'Enter subject name',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                const Divider(height: 1, color: _kBrutalistBorder),
                                const SizedBox(height: 20),
                                const _StepHeading(number: 3, label: 'Tag'),
                                const SizedBox(height: 8),
                                _PrimaryActionButton(
                                  onPressed: _assignTag,
                                  child: const Text('Assign Name to Selected'),
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton(
                                    onPressed: _clearCurrentSelectionAndTags,
                                    style: OutlinedButton.styleFrom(
                                      backgroundColor: Colors.transparent,
                                      foregroundColor: _kBrutalistButton,
                                      side: const BorderSide(
                                        color: _kBrutalistButton,
                                        width: 1,
                                      ),
                                      shape: const RoundedRectangleBorder(
                                        borderRadius: BorderRadius.zero,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 14,
                                      ),
                                    ),
                                    child: const Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.clear_all, size: 18),
                                        SizedBox(width: 8),
                                        Text('Clear Selection'),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                const Divider(height: 1, color: _kBrutalistBorder),
                              ],
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: const BoxDecoration(
                            color: _kBrutalistSidebar,
                            border: Border(
                              top: BorderSide(color: _kBrutalistBorder, width: 1),
                            ),
                          ),
                          child: SizedBox(
                            height: 70,
                            child: _PrimaryActionButton(
                              onPressed: _isProcessingBatch || !backend.canSendHttp
                                  ? null
                                  : _process,
                              padding: const EdgeInsets.symmetric(vertical: 20),
                              child: _isProcessingBatch
                                  ? const SizedBox(
                                      height: 24,
                                      width: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        color: _kBrutalistPrimaryText,
                                      ),
                                    )
                                  : Text(
                                      _showProcessSuccess
                                          ? 'Success!'
                                          : 'Process Batch',
                                      style: const TextStyle(
                                        fontSize: _kPanelTitleFontSize,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
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

class _StepHeading extends StatelessWidget {
  const _StepHeading({required this.number, required this.label});

  final int number;
  final String label;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: 'Step $number: ',
            style: const TextStyle(
              color: _kBrutalistSecondaryText,
              fontSize: _kSectionHeaderFontSize,
              fontWeight: FontWeight.w500,
            ),
          ),
          TextSpan(
            text: label,
            style: const TextStyle(
              color: _kBrutalistPrimaryText,
              fontSize: _kSectionHeaderFontSize,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3A3A3A), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: _kBrutalistSecondaryText,
              fontSize: 11,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '$value',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
