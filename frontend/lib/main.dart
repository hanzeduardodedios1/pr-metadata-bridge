import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http_parser/http_parser.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

late final String _kBackendHost;
late final int _kBackendPort;
late final Uri _kProxyScanUri;
late final Uri _kBackendHealthUri;
const String _kProxyBaseUrl = 'https://clownfish-app-7pdjt.ondigitalocean.app';
const Duration _kHealthRequestTimeout = Duration(seconds: 2);
const Duration _kBackendGracefulShutdownTimeout = Duration(seconds: 2);
const Duration _kBackendForceShutdownTimeout = Duration(seconds: 1);
const Color _kBrutalistBackground = Color(0xFF282828);
const Color _kBrutalistSidebar = Color(0xFF1E1E1E);
const Color _kBrutalistBorder = Color(0xFF2A2A2A);
const Color _kBrutalistPrimaryText = Colors.white;
const Color _kBrutalistSecondaryText = Color(0xFF8B8C90);
const Color _kBrutalistButton = Color(0xFF3D7AB5);
const Color _kAnchorHighlight = Color(0xFFFFD54F);
const Color _kStartupBackground = Color(0xFF1E1E1E);
const Color _kStartupDivider = Color(0xFF2A2A2A);
const double _kLabelFontSize = 11;
const double _kInputFontSize = 13;
const double _kSectionHeaderFontSize = 15;
const double _kPanelTitleFontSize = 18;

const String _kPrefLicenseKey = 'license_key';
const String _kPrefLicenseValidated = 'license_validated';
// TEMP: bypass LemonSqueezy gate for local V1.1 UI testing. Set to false when store is approved.
const bool _kBypassLicenseGate = true;
const String _kDevLicenseKeyPlaceholder = 'dev-bypass-local-test';
final Uri _kLemonSqueezyValidateUri = Uri.parse(
  'https://api.lemonsqueezy.com/v1/licenses/validate',
);

final backendHostProvider = ChangeNotifierProvider<BackendHostController>(
  (ref) => throw StateError('backendHostProvider must be overridden in main()'),
);

Never _fatalProxyUrlInvalid([Object? cause]) {
  final details = cause == null ? '' : '\nCause: $cause';
  throw StateError(
    'PROXY URL INVALID\n'
    'PROXY URL INVALID\n'
    'PROXY URL INVALID\n'
    'Missing or invalid proxy configuration. '
    'Expected _kProxyBaseUrl to be a valid absolute URL.$details',
  );
}

void _initializeBackendConfigFromConstants() {
  final proxyUrl = _kProxyBaseUrl.trim();
  if (proxyUrl.isEmpty) {
    _fatalProxyUrlInvalid('_kProxyBaseUrl is empty.');
  }

  final parsedBaseUri = Uri.tryParse(proxyUrl);
  if (parsedBaseUri == null ||
      !parsedBaseUri.hasScheme ||
      parsedBaseUri.host.isEmpty) {
    _fatalProxyUrlInvalid(
      '_kProxyBaseUrl is not a valid absolute URL: $proxyUrl',
    );
  }
  final scheme = parsedBaseUri.scheme.toLowerCase();
  final host = parsedBaseUri.host.toLowerCase();
  final isLocalHost =
      host == 'localhost' || host == '127.0.0.1' || host == '::1';
  if (scheme != 'https' && !isLocalHost) {
    _fatalProxyUrlInvalid(
      '_kProxyBaseUrl must use https for non-local endpoints. Got: $proxyUrl',
    );
  }

  final trimmedBasePath = parsedBaseUri.path.replaceAll(RegExp(r'/+$'), '');
  const scanSuffix = '/api/v1/scan';
  final scanPath = trimmedBasePath.isEmpty
      ? scanSuffix
      : '$trimmedBasePath$scanSuffix';
  _kProxyScanUri = Uri(
    scheme: parsedBaseUri.scheme,
    userInfo: parsedBaseUri.userInfo,
    host: parsedBaseUri.host,
    port: parsedBaseUri.hasPort ? parsedBaseUri.port : null,
    path: scanPath,
  );
  final origin = Uri(
    scheme: parsedBaseUri.scheme,
    host: parsedBaseUri.host,
    port: parsedBaseUri.hasPort ? parsedBaseUri.port : null,
  );
  _kBackendHost = parsedBaseUri.host;
  _kBackendPort = parsedBaseUri.hasPort
      ? parsedBaseUri.port
      : (parsedBaseUri.scheme == 'https' ? 443 : 80);
  _kBackendHealthUri = origin.replace(path: '/', query: '');
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
  bool _canSendHttp = true;
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
    _canSendHttp = true;
    _ownsProcess = false;
    _bootstrapMessage = null;
    notifyListeners();
  }

  /// Polls [pingBackendHealth] until success or [_kHealthWaitTimeout] elapses.
  Future<bool> waitForBackendHttpReady() async {
    _canSendHttp = true;
    _bootstrapMessage = null;
    notifyListeners();
    return true;
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
  _initializeBackendConfigFromConstants();

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

  /// Last folder passed to [loadJpegsFromDirectory], used for refresh and breadcrumb.
  String? get currentLoadDirectory => _currentLoadDirectory;
  String? _currentLoadDirectory;

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
    _currentLoadDirectory = _normalizePath(selectedDirectory);
    final directory = Directory(_currentLoadDirectory!);
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
    _currentLoadDirectory = null;
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

  void selectOnly(String filePath) {
    state = {_normalizePath(filePath)};
  }

  void selectRange(List<String> imagePaths, int fromIndex, int toIndex) {
    final low = fromIndex < toIndex ? fromIndex : toIndex;
    final high = fromIndex > toIndex ? fromIndex : toIndex;
    final next = <String>{};
    for (var i = low; i <= high; i++) {
      if (i >= 0 && i < imagePaths.length) {
        next.add(_normalizePath(imagePaths[i]));
      }
    }
    state = next;
  }

  void clear() {
    state = <String>{};
  }

  void keepOnlyPaths(Set<String> validPaths) {
    final next = {
      for (final p in state)
        if (validPaths.contains(p)) p,
    };
    if (next.length == state.length) {
      return;
    }
    state = next;
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

  void keepOnlyPathsWithTags(Set<String> validPaths) {
    final next = {
      for (final e in state.entries)
        if (validPaths.contains(e.key)) e.key: e.value,
    };
    if (next.length == state.length) {
      return;
    }
    state = next;
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

String get _resolvedExifToolPath {
  if (kDebugMode) {
    return p.join(Directory.current.path, 'exiftool.exe');
  }
  return p.join(
    File(Platform.resolvedExecutable).parent.path,
    'exiftool.exe',
  );
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

enum _StartupGatePhase { loading, ready }

/// Runs startup checks before revealing [child].
class StartupGate extends ConsumerStatefulWidget {
  const StartupGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<StartupGate> {
  static const List<String> _kStartupStatusMessages = <String>[
    'Starting up...',
    'Connecting to Vision API...',
    'Ready.',
  ];

  _StartupGatePhase _phase = _StartupGatePhase.loading;
  bool? _isExifToolValid;
  String _statusMessage = _kStartupStatusMessages.first;
  Timer? _statusTimer;
  int _statusMessageIndex = 0;

  @override
  void initState() {
    super.initState();
    _checkExifTool();
    _startStatusMessageRotation();
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
    if (_isExifToolValid != true) {
      return;
    }

    await ref.read(backendHostProvider).bootstrap();
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
  }

  Future<void> _checkExifTool() async {
    try {
      debugPrint('Resolving path...');
      final exiftoolPath = _resolvedExifToolPath;
      debugPrint('Checking ExifTool at: $exiftoolPath');
      final result = await Process.run(exiftoolPath, const <String>[
        '-ver',
      ]).timeout(const Duration(seconds: 3));
      if (result.exitCode == 0) {
        if (mounted) {
          setState(() {
            _isExifToolValid = true;
          });
        }
        unawaited(_runStartup());
        return;
      }
      if (mounted) {
        setState(() {
          _isExifToolValid = false;
        });
      }
    } catch (e) {
      debugPrint('ExifTool check failed: $e');
      if (mounted) {
        setState(() => _isExifToolValid = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isExifToolValid == null) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Initializing Engine...'),
            ],
          ),
        ),
      );
    }
    if (_isExifToolValid == false) {
      final targetPath = _resolvedExifToolPath;
      final exists = File(targetPath).existsSync();
      final exePath = Platform.resolvedExecutable;
      final currentDir = Directory.current.path;
      return Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 64, color: Colors.redAccent),
                SizedBox(height: 16),
                Text(
                  'ExifTool binary missing. Please reinstall the application.\n\n'
                  '--- DIAGNOSTICS ---\n'
                  'Target Path: $targetPath\n'
                  'File Exists: $exists\n'
                  'Exe Path: $exePath\n'
                  'Current Dir: $currentDir',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }
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

class _SessionTaggedBadge extends StatelessWidget {
  const _SessionTaggedBadge();

  static const Color _badgeGreen = Color(0xFF1D9E75);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: const BoxDecoration(
        color: _badgeGreen,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: const Icon(Icons.check, size: 14, color: Colors.white),
    );
  }
}

class _DashedBorder extends StatelessWidget {
  const _DashedBorder({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: const _DashedBorderPainter(), child: child);
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
  String? _scannedAnchorPath;
  Timer? _processSuccessTimer;
  String? _licenseKey;
  final Set<String> _processedFiles = {};
  final Map<String, String> _sessionResults = {};
  int? _lastClickedIndex;
  Set<String> _vipList = {};
  bool _isAnchorVipMatch = false;

  @override
  void initState() {
    super.initState();
    _loadLicenseFromPreferences();
  }

  String? get _effectiveLicenseKey {
    if (_kBypassLicenseGate) {
      return _kDevLicenseKeyPlaceholder;
    }
    final key = _licenseKey?.trim();
    return key == null || key.isEmpty ? null : key;
  }

  Future<void> _loadLicenseFromPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_kPrefLicenseKey);
    if (!mounted) {
      return;
    }
    setState(() {
      // When bypass is on, treat license as valid so scan/UI flow is not blocked.
      _licenseKey = _kBypassLicenseGate ? _kDevLicenseKeyPlaceholder : key;
    });
  }

  Future<void> _showLicenseDialog() async {
    final controller = TextEditingController(text: _licenseKey ?? '');
    String? dialogError;
    var submitting = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: !submitting,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit() async {
              final enteredKey = controller.text.trim();
              if (enteredKey.isEmpty) {
                setDialogState(() {
                  dialogError = 'Please enter a license key.';
                });
                return;
              }
              setDialogState(() {
                submitting = true;
                dialogError = null;
              });
              http.Response response;
              try {
                response = await http
                    .post(
                      _kLemonSqueezyValidateUri,
                      headers: const {
                        'Accept': 'application/json',
                        'Content-Type': 'application/json',
                      },
                      body: jsonEncode(<String, String>{
                        'license_key': enteredKey,
                      }),
                    )
                    .timeout(const Duration(seconds: 25));
              } on Object catch (_) {
                setDialogState(() {
                  submitting = false;
                  dialogError =
                      'Could not validate. Check your connection and try again.';
                });
                return;
              }

              Map<String, dynamic>? bodyMap;
              try {
                final decoded = jsonDecode(response.body);
                bodyMap = decoded is Map<String, dynamic> ? decoded : null;
              } on FormatException {
                bodyMap = null;
              }

              final valid = bodyMap?['valid'] == true;
              final explicitInvalid = bodyMap?['valid'] == false;

              if (response.statusCode == 200 && valid) {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString(_kPrefLicenseKey, enteredKey);
                await prefs.setBool(_kPrefLicenseValidated, true);
                if (!mounted) {
                  return;
                }
                setState(() {
                  _licenseKey = enteredKey;
                });
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                if (!context.mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('License activated successfully'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } else if (explicitInvalid ||
                  (response.statusCode == 200 && bodyMap != null && !valid)) {
                setDialogState(() {
                  submitting = false;
                  dialogError =
                      'Invalid license key. Please check your purchase email.';
                });
              } else {
                setDialogState(() {
                  submitting = false;
                  dialogError =
                      'Could not validate. Check your connection and try again.';
                });
              }
            }

            return AlertDialog(
              title: const Text('License Key'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Enter your license key to use cloud scan.',
                      style: TextStyle(
                        fontSize: _kInputFontSize,
                        color: _kBrutalistSecondaryText,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      enabled: !submitting,
                      decoration: InputDecoration(
                        hintText: 'License key',
                        errorText: dialogError,
                        border: const OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: _kInputFontSize),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: submitting ? null : submit,
                  child: submitting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Submit'),
                ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
  }

  @override
  void dispose() {
    _processSuccessTimer?.cancel();
    _tagController.dispose();
    super.dispose();
  }

  bool _isVipName(String name) {
    if (_vipList.isEmpty) {
      return false;
    }
    return _vipList.contains(name.trim().toLowerCase());
  }

  Set<String> _parseVipListFromText(String content) {
    return content
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => line.toLowerCase())
        .toSet();
  }

  Future<void> _showPasteVipListDialog() async {
    final controller = TextEditingController(text: _vipList.join('\n'));

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Paste VIP List'),
          content: SizedBox(
            width: 400,
            child: TextField(
              controller: controller,
              minLines: 5,
              maxLines: 15,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                hintText: 'One name per line',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    final pastedText = controller.text;
    controller.dispose();

    if (saved != true || !mounted) {
      return;
    }

    final names = _parseVipListFromText(pastedText);
    setState(() {
      _vipList = names;
      _isAnchorVipMatch = _isVipName(_tagController.text);
    });
  }

  void _assignTag() {
    // Always use the live field text at tap time, never a stale scan/OCR value.
    final subjectFromField = _tagController.text;
    final selectedPaths = ref.read(selectedFilesProvider);
    ref
        .read(taggedFilesProvider.notifier)
        .assignTagToSelection(
          selectedPaths: selectedPaths,
          vipName: subjectFromField,
        );
  }

  void _process() {
    _processBatch();
  }

  String? _activeFolderBreadcrumb(
    List<String> imagePaths,
    String? currentLoadDirectory,
  ) {
    String? rawFolder;
    if (imagePaths.isNotEmpty) {
      rawFolder = p.dirname(imagePaths.first);
    } else if (currentLoadDirectory != null &&
        currentLoadDirectory.isNotEmpty) {
      rawFolder = currentLoadDirectory;
    } else {
      return null;
    }
    var folderPath = p.normalize(rawFolder);
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

  void _refreshCurrentFolder() {
    final dir = ref.read(loadedFilesProvider.notifier).currentLoadDirectory;
    if (dir == null) {
      return;
    }
    ref.read(loadedFilesProvider.notifier).loadJpegsFromDirectory(dir);
    final valid = ref.read(loadedFilesProvider).toSet();
    ref.read(selectedFilesProvider.notifier).keepOnlyPaths(valid);
    ref.read(taggedFilesProvider.notifier).keepOnlyPathsWithTags(valid);
  }

  Future<void> _openBetaFeedbackEmail() async {
    final uri = Uri(
      scheme: 'mailto',
      path: 'ed.ddios0210@gmail.com',
      queryParameters: const <String, String>{
        'subject': 'CaptionFast Beta Feedback',
      },
    );
    if (!await canLaunchUrl(uri)) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar('Could not open an email app.');
      return;
    }
    await launchUrl(uri);
  }

  void _clearSessionProcessedFiles() {
    _processedFiles.clear();
    _sessionResults.clear();
    _lastClickedIndex = null;
  }

  String _escapeCsvField(String value) {
    if (value.contains('"') ||
        value.contains(',') ||
        value.contains('\n') ||
        value.contains('\r')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  String _buildCsvContent() {
    final buffer = StringBuffer()..writeln('Filename,Extracted Name');
    final sortedPaths = _sessionResults.keys.toList()..sort();
    for (final filePath in sortedPaths) {
      final filename = p.basename(filePath);
      final extractedName = _sessionResults[filePath] ?? '';
      buffer.writeln(
        '${_escapeCsvField(filename)},${_escapeCsvField(extractedName)}',
      );
    }
    return buffer.toString();
  }

  String _formatExportTimestamp(DateTime dateTime) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${dateTime.year}${two(dateTime.month)}${two(dateTime.day)}_'
        '${two(dateTime.hour)}${two(dateTime.minute)}${two(dateTime.second)}';
  }

  Future<void> _exportToCSV() async {
    if (_sessionResults.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No processed photos to export yet.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir == null) {
        if (!mounted) {
          return;
        }
        _showErrorSnackBar('Could not locate your Downloads folder.');
        return;
      }

      final timestamp = _formatExportTimestamp(DateTime.now());
      final filePath = p.join(
        downloadsDir.path,
        'CaptionFast_Export_$timestamp.csv',
      );
      await File(filePath).writeAsString(_buildCsvContent());

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Exported roster to $filePath'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar('CSV export failed: $error');
    }
  }

  void _onThumbnailTap(int index, String filePath) {
    final isCtrl = HardwareKeyboard.instance.isControlPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final notifier = ref.read(selectedFilesProvider.notifier);
    final imagePaths = ref.read(loadedFilesProvider);

    if (isShift && _lastClickedIndex != null) {
      notifier.selectRange(imagePaths, _lastClickedIndex!, index);
    } else if (isCtrl) {
      notifier.toggle(filePath);
    } else {
      notifier.selectOnly(filePath);
    }
    setState(() => _lastClickedIndex = index);
  }

  void _clearCurrentSelectionAndTags() {
    ref.read(selectedFilesProvider.notifier).clear();
    setState(() {
      _tagController.clear();
      _lastClickedIndex = null;
      _isAnchorVipMatch = false;
    });
  }

  Future<void> _pickFolderFromBreadcrumb() async {
    final imagePaths = ref.read(loadedFilesProvider);
    final tags = ref.read(taggedFilesProvider);
    final hasUnprocessedTaggedPhotos = imagePaths.isNotEmpty && tags.isNotEmpty;
    if (hasUnprocessedTaggedPhotos) {
      final shouldDiscard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Unsaved Changes'),
            content: const Text(
              'You have unprocessed tags. Are you sure you want to change folders and lose this data?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Discard'),
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
      _isAnchorVipMatch = false;
      _clearSessionProcessedFiles();
    });
    ref
        .read(loadedFilesProvider.notifier)
        .loadJpegsFromDirectory(selectedDirectory);
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
    final licenseKey = _effectiveLicenseKey;
    // Blocking gate — skipped while _kBypassLicenseGate is true.
    if (!_kBypassLicenseGate &&
        (licenseKey == null || licenseKey.isEmpty)) {
      await _showLicenseDialog();
      return;
    }

    final selectedPaths = ref.read(selectedFilesProvider).toList();
    if (selectedPaths.length != 1) {
      return;
    }

    final selectedPath = selectedPaths.first;
    if (_scannedAnchorPath != null && _scannedAnchorPath != selectedPath) {
      final shouldReplace = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Replace Anchor?'),
            content: const Text(
              'Scanning a new photo will replace the current anchor.\nContinue?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Continue'),
              ),
            ],
          );
        },
      );
      if (shouldReplace != true) {
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _scannedAnchorPath = null;
      });
    }

    setState(() {
      _isScanning = true;
    });

    try {
      debugPrint('Sending scan request to $_scanUri');
      final imageContentType = _mediaTypeForImagePath(selectedPath);
      final requestUri = Uri.parse(_scanUri.toString());
      final request = http.MultipartRequest('POST', requestUri)
        ..files.add(
          await http.MultipartFile.fromPath(
            'file',
            selectedPath,
            contentType: imageContentType,
          ),
        );
      request.headers['X-API-Key'] =
          licenseKey ?? _kDevLicenseKeyPlaceholder;
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
        _scannedAnchorPath = selectedPath;
        _isAnchorVipMatch = _isVipName(extractedText);
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
      return;
    }

    final subject = _tagController.text;
    if (subject.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a subject name in the field before processing.'),
        ),
      );
      return;
    }

    setState(() {
      _isProcessingBatch = true;
    });

    final paths = tags.keys.toList()..sort();
    try {
      final exifPath = _resolvedExifToolPath;
      var allSucceeded = true;
      for (final filePath in paths) {
        if (!mounted) {
          return;
        }

        final fileSubject = tags[filePath] ?? subject;
        final args = <String>[
          '-XMP:Subject=${_tagController.text}',
          '-IPTC:Keywords=${_tagController.text}',
          '-XPKeywords=${_tagController.text}',
          '-XPSubject=${_tagController.text}',
          if (_isVipName(fileSubject)) '-XMP:Rating=5',
          '-overwrite_original',
          filePath,
        ];

        try {
          final result = await Process.run(exifPath, args);
          if (result.exitCode == 0) {
            final normalizedPath = p.normalize(filePath);
            setState(() {
              _processedFiles.add(normalizedPath);
              _sessionResults[normalizedPath] = subject.trim();
            });
          } else {
            allSucceeded = false;
            final err = result.stderr.toString();
            debugPrint(
              'ExifTool failed for $filePath (exit ${result.exitCode}): $err',
            );
            if (mounted) {
              _showErrorSnackBar(
                '${p.basename(filePath)}: ${err.trim().isEmpty ? "ExifTool failed" : err.trim()}',
              );
            }
          }
        } on ProcessException {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'ExifTool binary not found in installation directory.',
                ),
                backgroundColor: Colors.red,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          return;
        }
      }

      if (!mounted) {
        return;
      }

      if (allSucceeded) {
        ref.read(selectedFilesProvider.notifier).clear();
        setState(() {
          _tagController.clear();
          _scannedAnchorPath = null;
          _isAnchorVipMatch = false;
        });
        _showProcessSuccessState();
      }
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
    final scanTooltip = selected.isEmpty
        ? 'Select a photo to scan'
        : selected.length > 1
        ? 'Select only one photo to scan'
        : 'Scan this photo for text';
    final currentLoadDirectory = ref
        .read(loadedFilesProvider.notifier)
        .currentLoadDirectory;

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
                                  final breadcrumb = _activeFolderBreadcrumb(
                                    imagePaths,
                                    currentLoadDirectory,
                                  );
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
                            if (currentLoadDirectory != null)
                              IconButton(
                                icon: const Icon(
                                  Icons.refresh,
                                  size: 20,
                                  color: _kBrutalistSecondaryText,
                                ),
                                tooltip: 'Refresh folder',
                                onPressed: _refreshCurrentFolder,
                              ),
                            IconButton(
                              icon: const Icon(
                                Icons.bug_report,
                                size: 20,
                                color: _kBrutalistSecondaryText,
                              ),
                              tooltip: 'Report bug',
                              onPressed: _openBetaFeedbackEmail,
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
                                          final loaded = await ref
                                              .read(
                                                loadedFilesProvider.notifier,
                                              )
                                              .pickFolderAndLoadJpegs();
                                          if (loaded && mounted) {
                                            ref
                                                .read(
                                                  selectedFilesProvider
                                                      .notifier,
                                                )
                                                .clear();
                                            setState(
                                              _clearSessionProcessedFiles,
                                            );
                                          }
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
                                                Icons
                                                    .add_photo_alternate_outlined,
                                                size: 54,
                                                color: _kBrutalistSecondaryText,
                                              ),
                                              SizedBox(height: 18),
                                              Text(
                                                'Drop folder here or click to browse',
                                                style: TextStyle(
                                                  color: _kBrutalistPrimaryText,
                                                  fontSize:
                                                      _kPanelTitleFontSize,
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
                                        final isAnchor =
                                            filePath == _scannedAnchorPath;
                                        final isProcessed = _processedFiles
                                            .contains(filePath);
                                        final assignedTag = tags[filePath];

                                        return GestureDetector(
                                          onTap: () =>
                                              _onThumbnailTap(index, filePath),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: _kBrutalistSidebar,
                                              border: Border.all(
                                                color: isAnchor
                                                    ? _kAnchorHighlight
                                                    : (isSelected
                                                          ? _kBrutalistButton
                                                          : _kBrutalistBorder),
                                                width: isAnchor ? 2 : 1,
                                              ),
                                            ),
                                            padding: const EdgeInsets.all(8),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Expanded(
                                                  child: Stack(
                                                    children: [
                                                      Positioned.fill(
                                                        child: Image.file(
                                                          File(filePath),
                                                          fit: BoxFit.cover,
                                                          width:
                                                              double.infinity,
                                                          errorBuilder:
                                                              (
                                                                _,
                                                                _,
                                                                _,
                                                              ) => Container(
                                                                color:
                                                                    const Color(
                                                                      0xFF222224,
                                                                    ),
                                                                alignment:
                                                                    Alignment
                                                                        .center,
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
                                                      if (isAnchor)
                                                        const Positioned(
                                                          top: 8,
                                                          right: 8,
                                                          child: Icon(
                                                            Icons
                                                                .center_focus_strong,
                                                            color:
                                                                _kAnchorHighlight,
                                                            size: 20,
                                                          ),
                                                        ),
                                                      if (isProcessed)
                                                        const Positioned(
                                                          top: 4,
                                                          right: 4,
                                                          child:
                                                              _SessionTaggedBadge(),
                                                        ),
                                                    ],
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
                                                      ? 'Unassigned'
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
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton(
                                      onPressed: _showPasteVipListDialog,
                                      style: OutlinedButton.styleFrom(
                                        backgroundColor: Colors.transparent,
                                        foregroundColor: _kBrutalistPrimaryText,
                                        side: const BorderSide(
                                          color: _kBrutalistBorder,
                                          width: 1,
                                        ),
                                        shape: const RoundedRectangleBorder(
                                          borderRadius: BorderRadius.zero,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          const Icon(Icons.content_paste, size: 18),
                                          const SizedBox(width: 8),
                                          Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Text('Paste VIP List'),
                                              if (_vipList.isNotEmpty)
                                                Text(
                                                  'VIPs Loaded: ${_vipList.length}',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: _kBrutalistPrimaryText
                                                            .withValues(alpha: 0.7),
                                                      ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
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
                                Tooltip(
                                  message: scanTooltip,
                                  child: _PrimaryActionButton(
                                    onPressed:
                                        selected.length != 1 ||
                                            _isScanning ||
                                            !backend.canSendHttp
                                        ? null
                                        : () {
                                            final key = _effectiveLicenseKey;
                                            // Blocking gate — skipped while _kBypassLicenseGate is true.
                                            if (!_kBypassLicenseGate &&
                                                (key == null || key.isEmpty)) {
                                              _showLicenseDialog();
                                            } else {
                                              _scanSelectedAnchorPhoto();
                                            }
                                          },
                                    child: _isScanning
                                        ? const SizedBox(
                                            height: 18,
                                            width: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: _kBrutalistPrimaryText,
                                            ),
                                          )
                                        : const Text(
                                            'Scan Selected Anchor Photo',
                                          ),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                const Divider(
                                  height: 1,
                                  color: _kBrutalistBorder,
                                ),
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
                                  onChanged: (_) => setState(() {
                                    _isAnchorVipMatch = _isVipName(_tagController.text);
                                  }),
                                  style: const TextStyle(
                                    fontSize: _kInputFontSize,
                                  ),
                                  decoration: const InputDecoration(
                                    hintText: 'Enter subject name',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                if (_isAnchorVipMatch) ...[
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF3D3520),
                                      border: Border.all(
                                        color: _kAnchorHighlight,
                                        width: 1,
                                      ),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.star,
                                          size: 14,
                                          color: _kAnchorHighlight,
                                        ),
                                        SizedBox(width: 6),
                                        Text(
                                          'VIP MATCH',
                                          style: TextStyle(
                                            color: _kAnchorHighlight,
                                            fontSize: _kLabelFontSize,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.8,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 20),
                                const Divider(
                                  height: 1,
                                  color: _kBrutalistBorder,
                                ),
                                const SizedBox(height: 20),
                                const _StepHeading(number: 3, label: 'Tag'),
                                const SizedBox(height: 8),
                                _PrimaryActionButton(
                                  onPressed:
                                      _tagController.text.trim().isEmpty ||
                                          selected.isEmpty
                                      ? null
                                      : _assignTag,
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
                                const Divider(
                                  height: 1,
                                  color: _kBrutalistBorder,
                                ),
                              ],
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: const BoxDecoration(
                            color: _kBrutalistSidebar,
                            border: Border(
                              top: BorderSide(
                                color: _kBrutalistBorder,
                                width: 1,
                              ),
                            ),
                          ),
                          child: SizedBox(
                            height: 70,
                            child: Row(
                              children: [
                                Expanded(
                                  child: _PrimaryActionButton(
                                    onPressed:
                                        _sessionResults.isEmpty
                                        ? null
                                        : _exportToCSV,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 20,
                                    ),
                                    child: const Text(
                                      'Export CSV',
                                      style: TextStyle(
                                        fontSize: _kInputFontSize,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: 2,
                                  child: _PrimaryActionButton(
                                    onPressed:
                                        _isProcessingBatch || tags.isEmpty
                                        ? null
                                        : _process,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 20,
                                    ),
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
