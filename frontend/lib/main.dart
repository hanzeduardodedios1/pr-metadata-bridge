import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http_parser/http_parser.dart';
import 'package:path/path.dart' as p;
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
const String _kProxyApiKey = 'cf_live_83920_auth_key';
final Uri _kLemonSqueezyValidateUri = Uri.parse(
  'https://api.lemonsqueezy.com/v1/licenses/validate',
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

  /// Polls [pingBackendHealth] until success or the health wait timeout elapses.
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

  runApp(App(backendHost: backendHost));
}

String get _resolvedExifToolPath {
  if (kDebugMode) {
    return p.join(Directory.current.path, 'exiftool.exe');
  }
  return p.join(
    File(Platform.resolvedExecutable).parent.path,
    'exiftool.exe',
  );
}

class App extends StatefulWidget {
  const App({required this.backendHost, super.key});

  final BackendHostController backendHost;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WindowListener, WidgetsBindingObserver {
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
      widget.backendHost.requestOwnedProcessKill();
      await widget.backendHost.shutdownOwned();
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
      home: StartupGate(
        backendHost: widget.backendHost,
        child: HomePage(backendHost: widget.backendHost),
      ),
    );
  }
}

enum _StartupGatePhase { loading, ready }

/// Runs startup checks before revealing [child].
class StartupGate extends StatefulWidget {
  const StartupGate({
    required this.backendHost,
    required this.child,
    super.key,
  });

  final BackendHostController backendHost;
  final Widget child;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
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

    await widget.backendHost.bootstrap();
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

class HomePage extends StatefulWidget {
  const HomePage({
    required this.backendHost,
    super.key,
    @visibleForTesting this.initialPhotoPaths,
    @visibleForTesting this.initialLicenseValid,
  });

  final BackendHostController backendHost;

  @visibleForTesting
  final List<String>? initialPhotoPaths;

  @visibleForTesting
  final bool? initialLicenseValid;

  @override
  State<HomePage> createState() => HomePageState();
}

@visibleForTesting
class HomePageState extends State<HomePage> {
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
  String? _anchorPath;
  Timer? _processSuccessTimer;
  String? licensekey;
  bool islicensevalid = false;
  bool islicenseverifying = false;
  List<String> _imagePaths = const [];
  String? _currentLoadDirectory;
  Set<String> _selectedPhotos = {};
  Map<String, String> _tags = {};
  final Set<String> _processedFiles = {};
  /// Filename → subject written by ExifTool this session (roster CSV export).
  final Map<String, String> _sessionTags = {};
  int? _lastClickedIndex;
  Set<String> _vipList = {};
  bool _isAnchorVipMatch = false;

  @visibleForTesting
  Set<String> get selectedPhotos => Set.unmodifiable(_selectedPhotos);

  @visibleForTesting
  String? get anchorPath => _anchorPath;
  final ScrollController _gridScrollController = ScrollController();
  Offset? _dragStart;
  Offset? _dragCurrent;
  Offset? _lassoPointerDown;
  int _gridCrossAxisCount = 2;
  double _gridViewportWidth = 0;
  static const double _kLassoActivationDistance = 8;

  @override
  void initState() {
    super.initState();
    final seeded = widget.initialPhotoPaths;
    if (seeded != null) {
      _imagePaths = List<String>.from(seeded);
    }
    if (widget.initialLicenseValid == true) {
      licensekey = 'test-license';
      islicensevalid = true;
      islicenseverifying = false;
    } else {
      unawaited(_loadLicenseFromPreferences());
    }
  }

  String _normalizePath(String rawPath) => p.normalize(rawPath);

  bool _isJpeg(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    return ext == '.jpg' || ext == '.jpeg';
  }

  List<String> _listJpegsInDirectory(String directoryPath) {
    final directory = Directory(directoryPath);
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => _isJpeg(file.path))
            .map((file) => _normalizePath(file.path))
            .toList()
      ..sort();
    return files;
  }

  void _resetSessionForNewFolder() {
    _selectedPhotos = {};
    _anchorPath = null;
    _tagController.clear();
    _processedFiles.clear();
    _sessionTags.clear();
    _tags = {};
    _lastClickedIndex = null;
    _isAnchorVipMatch = false;
    _showProcessSuccess = false;
  }

  void _loadJpegsFromDirectory(String selectedDirectory) {
    _currentLoadDirectory = _normalizePath(selectedDirectory);
    _imagePaths = _listJpegsInDirectory(_currentLoadDirectory!);
  }

  Future<bool> _pickFolderAndLoadJpegs() async {
    final selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Folder with JPEG Images',
    );
    if (selectedDirectory == null) {
      return false;
    }
    setState(() {
      _resetSessionForNewFolder();
      _loadJpegsFromDirectory(selectedDirectory);
    });
    return true;
  }

  void _toggleSelection(String filePath) {
    final normalizedPath = _normalizePath(filePath);
    final next = {..._selectedPhotos};
    if (next.contains(normalizedPath)) {
      next.remove(normalizedPath);
    } else {
      next.add(normalizedPath);
    }
    _selectedPhotos = next;
  }

  void _selectRange(int fromIndex, int toIndex) {
    final low = fromIndex < toIndex ? fromIndex : toIndex;
    final high = fromIndex > toIndex ? fromIndex : toIndex;
    final next = <String>{};
    for (var i = low; i <= high; i++) {
      if (i >= 0 && i < _imagePaths.length) {
        next.add(_normalizePath(_imagePaths[i]));
      }
    }
    _selectedPhotos = next;
  }

  void _addSelectedPaths(Iterable<String> filePaths) {
    final next = {..._selectedPhotos};
    var changed = false;
    for (final filePath in filePaths) {
      if (next.add(_normalizePath(filePath))) {
        changed = true;
      }
    }
    if (changed) {
      _selectedPhotos = next;
    }
  }

  Future<({bool valid, String message})> _verifyLicenseKey(String key) async {
    try {
      final response = await http
          .post(
            _kLemonSqueezyValidateUri,
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, String>{'license_key': key}),
          )
          .timeout(const Duration(seconds: 25));
      Map<String, dynamic>? bodyMap;
      try {
        final decoded = jsonDecode(response.body);
        bodyMap = decoded is Map<String, dynamic> ? decoded : null;
      } on FormatException {
        bodyMap = null;
      }

      final valid = bodyMap?['valid'] == true;
      if (response.statusCode == 200 && valid) {
        final licenseInfo = bodyMap?['license_key'];
        if (licenseInfo is Map<String, dynamic>) {
          final status = (licenseInfo['status'] as String? ?? '').toLowerCase();
          if (status == 'inactive' ||
              status == 'expired' ||
              status == 'disabled') {
            return (
              valid: false,
              message: 'License is $status. Please renew or contact support.',
            );
          }
        }
        return (valid: true, message: '');
      }

      final err = bodyMap?['error'];
      if (err is String && err.isNotEmpty) {
        return (valid: false, message: err);
      }
      if (bodyMap?['valid'] == false) {
        return (
          valid: false,
          message: 'Invalid license key. Please check your purchase email.',
        );
      }
      return (
        valid: false,
        message: 'Could not validate. Check your connection and try again.',
      );
    } on Object {
      return (
        valid: false,
        message: 'Could not validate. Check your connection and try again.',
      );
    }
  }

  Future<void> _persistLicenseKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefLicenseKey, key);
    await prefs.setBool(_kPrefLicenseValidated, true);
  }

  Future<void> _clearLicenseFromPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPrefLicenseKey);
    await prefs.setBool(_kPrefLicenseValidated, false);
  }

  Future<void> _invalidateLicense(String message) async {
    await _clearLicenseFromPreferences();
    if (!mounted) {
      return;
    }
    setState(() {
      licensekey = null;
      islicensevalid = false;
      islicenseverifying = false;
    });
    _showErrorSnackBar(message);
    await _showLicenseDialog();
  }

  Future<void> _loadLicenseFromPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_kPrefLicenseKey)?.trim();
    if (!mounted) {
      return;
    }
    if (key == null || key.isEmpty) {
      setState(() {
        licensekey = null;
        islicensevalid = false;
        islicenseverifying = false;
      });
      return;
    }

    setState(() {
      licensekey = key;
      islicensevalid = false;
      islicenseverifying = true;
    });

    final result = await _verifyLicenseKey(key);
    if (!mounted) {
      return;
    }
    if (result.valid) {
      setState(() {
        islicensevalid = true;
        islicenseverifying = false;
      });
      return;
    }

    await _clearLicenseFromPreferences();
    if (!mounted) {
      return;
    }
    setState(() {
      licensekey = null;
      islicensevalid = false;
      islicenseverifying = false;
    });
  }

  Future<void> _showLicenseDialog() async {
    final controller = TextEditingController(text: licensekey ?? '');
    final messenger = ScaffoldMessenger.of(context);
    String? dialogerror;
    var submitting = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit() async {
              final enteredkey = controller.text.trim();
              if (enteredkey.isEmpty) {
                setDialogState(() {
                  dialogerror = 'Please enter a license key.';
                });
                return;
              }
              setDialogState(() {
                submitting = true;
                dialogerror = null;
              });

              final result = await _verifyLicenseKey(enteredkey);
              if (!dialogContext.mounted) {
                return;
              }

              if (result.valid) {
                await _persistLicenseKey(enteredkey);
                if (!dialogContext.mounted) {
                  return;
                }
                Navigator.of(dialogContext).pop();
                if (!mounted) {
                  return;
                }
                setState(() {
                  licensekey = enteredkey;
                  islicensevalid = true;
                  islicenseverifying = false;
                });
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('License activated successfully'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } else {
                setDialogState(() {
                  submitting = false;
                  dialogerror = result.message;
                });
              }
            }

            return AlertDialog(
              title: const Text('Enter License Key'),
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
                        errorText: dialogerror,
                        border: const OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: _kInputFontSize),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting ? null : submit,
                  child: submitting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Activate'),
                ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
  }

  Widget _buildLicenseGateOverlay() {
    if (islicenseverifying) {
      return const ColoredBox(
        color: Color(0xCC1E1E1E),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: _kBrutalistButton,
                ),
              ),
              SizedBox(height: 16),
              Text(
                'Verifying license...',
                style: TextStyle(
                  fontSize: _kInputFontSize,
                  color: _kBrutalistSecondaryText,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!islicensevalid) {
      return ColoredBox(
        color: const Color(0xCC1E1E1E),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.vpn_key_outlined,
                    size: 48,
                    color: _kBrutalistButton,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Enter License Key',
                    style: TextStyle(
                      fontSize: _kPanelTitleFontSize,
                      fontWeight: FontWeight.w600,
                      color: _kBrutalistPrimaryText,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'A valid license is required to use cloud scan.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: _kInputFontSize,
                      color: _kBrutalistSecondaryText,
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: _PrimaryActionButton(
                      onPressed: _showLicenseDialog,
                      child: const Text('Enter License Key'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  @override
  void dispose() {
    _processSuccessTimer?.cancel();
    _tagController.dispose();
    _gridScrollController.dispose();
    super.dispose();
  }

  static const double _kGridCrossAxisSpacing = 12;
  static const double _kGridMainAxisSpacing = 12;
  static const double _kGridChildAspectRatio = 0.88;

  int _crossAxisCountForGridWidth(double maxWidth) {
    return (maxWidth / 220).floor().clamp(2, 8);
  }

  double _crossAxisExtentForGrid(double gridWidth, int crossAxisCount) {
    return (gridWidth - (crossAxisCount - 1) * _kGridCrossAxisSpacing) /
        crossAxisCount;
  }

  double _mainAxisExtentForGrid(double gridWidth, int crossAxisCount) {
    return _crossAxisExtentForGrid(gridWidth, crossAxisCount) /
        _kGridChildAspectRatio;
  }

  Rect _thumbnailRectAtIndex({
    required int index,
    required int crossAxisCount,
    required double gridWidth,
    required double scrollOffset,
  }) {
    final crossAxisExtent = _crossAxisExtentForGrid(gridWidth, crossAxisCount);
    final mainAxisExtent = _mainAxisExtentForGrid(gridWidth, crossAxisCount);
    final col = index % crossAxisCount;
    final row = index ~/ crossAxisCount;
    final left = col * (crossAxisExtent + _kGridCrossAxisSpacing);
    final top = row * (mainAxisExtent + _kGridMainAxisSpacing) - scrollOffset;
    return Rect.fromLTWH(left, top, crossAxisExtent, mainAxisExtent);
  }

  Iterable<int> _thumbnailIndicesInSelectionRect(
    Rect selectionRect, {
    required int itemCount,
    required int crossAxisCount,
    required double gridWidth,
    required double scrollOffset,
  }) sync* {
    for (var index = 0; index < itemCount; index++) {
      final thumbRect = _thumbnailRectAtIndex(
        index: index,
        crossAxisCount: crossAxisCount,
        gridWidth: gridWidth,
        scrollOffset: scrollOffset,
      );
      if (selectionRect.overlaps(thumbRect)) {
        yield index;
      }
    }
  }

  void _applyLassoSelection(List<String> imagePaths) {
    if (_dragStart == null || _dragCurrent == null || imagePaths.isEmpty) {
      return;
    }
    final selectionRect = Rect.fromPoints(_dragStart!, _dragCurrent!);
    final scrollOffset = _gridScrollController.hasClients
        ? _gridScrollController.offset
        : 0.0;
    final indices = _thumbnailIndicesInSelectionRect(
      selectionRect,
      itemCount: imagePaths.length,
      crossAxisCount: _gridCrossAxisCount,
      gridWidth: _gridViewportWidth,
      scrollOffset: scrollOffset,
    );
    final paths = [
      for (final index in indices)
        if (index >= 0 && index < imagePaths.length) imagePaths[index],
    ];
    setState(() => _addSelectedPaths(paths));
  }

  void _onGridPanStart(DragStartDetails details) {
    _lassoPointerDown = details.localPosition;
  }

  void _onGridPanUpdate(DragUpdateDetails details, List<String> imagePaths) {
    final pointerDown = _lassoPointerDown;
    if (pointerDown == null) {
      return;
    }

    if (_dragStart == null) {
      if ((details.localPosition - pointerDown).distance <
          _kLassoActivationDistance) {
        return;
      }
      setState(() {
        _dragStart = pointerDown;
        _dragCurrent = details.localPosition;
      });
    } else {
      setState(() {
        _dragCurrent = details.localPosition;
      });
    }
    _applyLassoSelection(imagePaths);
  }

  void _onGridPanEnd(DragEndDetails details) {
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
      _lassoPointerDown = null;
    });
  }

  void _onGridPanCancel() {
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
      _lassoPointerDown = null;
    });
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
    final subjectFromField = _tagController.text.trim();
    if (subjectFromField.isEmpty || _selectedPhotos.isEmpty) {
      return;
    }
    setState(() {
      final next = {..._tags};
      for (final filePath in _selectedPhotos) {
        next[_normalizePath(filePath)] = subjectFromField;
      }
      _tags = next;
    });
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
    final dir = _currentLoadDirectory;
    if (dir == null) {
      return;
    }
    final files = _listJpegsInDirectory(dir);
    final valid = files.toSet();
    setState(() {
      _imagePaths = files;
      _selectedPhotos = {
        for (final path in _selectedPhotos)
          if (valid.contains(path)) path,
      };
      _tags = {
        for (final entry in _tags.entries)
          if (valid.contains(entry.key)) entry.key: entry.value,
      };
      if (_anchorPath != null && !valid.contains(_anchorPath)) {
        _anchorPath = null;
      }
    });
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

  String _escapeCsvField(String value) {
    if (value.contains('"') ||
        value.contains(',') ||
        value.contains('\n') ||
        value.contains('\r')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  String _buildRosterCsvContent() {
    final buffer = StringBuffer()..writeln('Filename,Tagged Subject');
    final sortedFilenames = _sessionTags.keys.toList()..sort();
    for (final filename in sortedFilenames) {
      final taggedSubject = _sessionTags[filename] ?? '';
      buffer.writeln(
        '${_escapeCsvField(filename)},${_escapeCsvField(taggedSubject)}',
      );
    }
    return buffer.toString();
  }

  String? _activeImageDirectory(
    List<String> imagePaths,
    String? currentLoadDirectory,
  ) {
    if (currentLoadDirectory != null && currentLoadDirectory.isNotEmpty) {
      return p.normalize(currentLoadDirectory);
    }
    if (imagePaths.isNotEmpty) {
      return p.normalize(p.dirname(imagePaths.first));
    }
    return null;
  }

  Future<void> _exportRosterCsv(
    List<String> imagePaths,
    String? currentLoadDirectory,
  ) async {
    if (_sessionTags.isEmpty) {
      return;
    }

    final imageDir = _activeImageDirectory(imagePaths, currentLoadDirectory);
    if (imageDir == null) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar('No active image folder to save the roster.');
      return;
    }

    try {
      final filePath = p.join(imageDir, 'CaptionFast_Roster.csv');
      await File(filePath).writeAsString(_buildRosterCsvContent());

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Roster saved to $imageDir'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      _showErrorSnackBar('Roster export failed: $error');
    }
  }

  void _onThumbnailTap(int index, String filePath) {
    final isCtrl = HardwareKeyboard.instance.isControlPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final normalizedPath = _normalizePath(filePath);

    setState(() {
      if (isShift && _lastClickedIndex != null) {
        _selectRange(_lastClickedIndex!, index);
      } else if (isCtrl) {
        _toggleSelection(normalizedPath);
      } else {
        _anchorPath = normalizedPath;
        _selectedPhotos = {};
      }
      _lastClickedIndex = index;
    });
  }

  void _clearCurrentSelectionAndTags() {
    setState(() {
      _selectedPhotos = {};
      _tagController.clear();
      _lastClickedIndex = null;
      _isAnchorVipMatch = false;
    });
  }

  Future<void> _pickFolderFromBreadcrumb() async {
    final hasUnprocessedTaggedPhotos =
        _imagePaths.isNotEmpty && _tags.isNotEmpty;
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

    setState(() {
      _resetSessionForNewFolder();
      _currentLoadDirectory = null;
      _imagePaths = const [];
      _loadJpegsFromDirectory(selectedDirectory);
    });
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

  String _scanForbiddenDetail(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final detail = decoded['detail'];
        if (detail is String && detail.isNotEmpty) {
          return detail;
        }
      }
    } on FormatException {
      // Fall through to generic message.
    }
    return 'License rejected. Please enter a valid license key.';
  }

  Future<void> _scanSelectedAnchorPhoto() async {
    final key = licensekey?.trim();
    if (!islicensevalid || key == null || key.isEmpty) {
      await _showLicenseDialog();
      return;
    }

    final anchorPath = _anchorPath;
    if (anchorPath == null) {
      return;
    }

    setState(() {
      _isScanning = true;
    });

    try {
      debugPrint('Sending scan request to $_scanUri');
      final imageContentType = _mediaTypeForImagePath(anchorPath);
      final requestUri = Uri.parse(_scanUri.toString());
      final request = http.MultipartRequest('POST', requestUri)
        ..files.add(
          await http.MultipartFile.fromPath(
            'file',
            anchorPath,
            contentType: imageContentType,
          ),
        );
      request.headers['X-API-Key'] = _kProxyApiKey;
      request.headers['X-License-Key'] = key;
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      debugPrint('Scan response ${response.statusCode}: ${response.body}');

      if (response.statusCode == 403) {
        final message = _scanForbiddenDetail(response.body);
        if (!mounted) {
          return;
        }
        await _invalidateLicense(message);
        return;
      }

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
    final tags = _tags;
    if (tags.isEmpty) {
      return;
    }

    final subjectFallback = _tagController.text.trim();
    final paths = tags.keys.toList()..sort();
    for (final filePath in paths) {
      final tagValue = (tags[filePath] ?? subjectFallback).trim();
      if (tagValue.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Every tagged photo needs a subject name. Assign names or enter one in the field.',
            ),
          ),
        );
        return;
      }
    }

    setState(() {
      _isProcessingBatch = true;
    });

    try {
      final exifPath = _resolvedExifToolPath;
      var allSucceeded = true;
      for (final filePath in paths) {
        if (!mounted) {
          return;
        }

        final tagValue = (tags[filePath] ?? subjectFallback).trim();
        final args = <String>[
          '-XMP:Subject=$tagValue',
          '-IPTC:Keywords=$tagValue',
          '-XPKeywords=$tagValue',
          '-XPSubject=$tagValue',
          if (_isVipName(tagValue)) '-XMP:Label=Red',
          '-overwrite_original',
          filePath,
        ];

        try {
          final result = await Process.run(exifPath, args);
          if (result.exitCode == 0) {
            final normalizedPath = p.normalize(filePath);
            setState(() {
              _processedFiles.add(normalizedPath);
              _sessionTags[p.basename(normalizedPath)] = tagValue;
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
        setState(() {
          _selectedPhotos = {};
          _tagController.clear();
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
    final imagePaths = _imagePaths;
    final selected = _selectedPhotos;
    final tags = _tags;
    final scanTooltip = _anchorPath == null
        ? 'Click a photo to set the anchor, then scan'
        : 'Scan anchor photo for text';
    final currentLoadDirectory = _currentLoadDirectory;

    return ListenableBuilder(
      listenable: widget.backendHost,
      builder: (context, _) {
        final backend = widget.backendHost;
        return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Column(
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
                                        onTap: _pickFolderAndLoadJpegs,
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
                                        _crossAxisCountForGridWidth(
                                          constraints.maxWidth,
                                        );
                                    _gridCrossAxisCount = crossAxisCount;
                                    _gridViewportWidth = constraints.maxWidth;
                                    final selectionRect =
                                        _dragStart != null &&
                                            _dragCurrent != null
                                        ? Rect.fromPoints(
                                            _dragStart!,
                                            _dragCurrent!,
                                          )
                                        : null;
                                    return Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onPanStart: _onGridPanStart,
                                          onPanUpdate: (details) =>
                                              _onGridPanUpdate(
                                                details,
                                                imagePaths,
                                              ),
                                          onPanEnd: _onGridPanEnd,
                                          onPanCancel: _onGridPanCancel,
                                          child: GridView.builder(
                                            controller: _gridScrollController,
                                            physics: _dragStart != null
                                                ? const NeverScrollableScrollPhysics()
                                                : const ClampingScrollPhysics(),
                                            gridDelegate:
                                                SliverGridDelegateWithFixedCrossAxisCount(
                                                  crossAxisCount:
                                                      crossAxisCount,
                                                  childAspectRatio:
                                                      _kGridChildAspectRatio,
                                                  crossAxisSpacing:
                                                      _kGridCrossAxisSpacing,
                                                  mainAxisSpacing:
                                                      _kGridMainAxisSpacing,
                                                ),
                                            itemCount: imagePaths.length,
                                            itemBuilder: (context, index) {
                                        final filePath = imagePaths[index];
                                        final fileName = p.basename(filePath);
                                        final isSelected = selected.contains(
                                          filePath,
                                        );
                                        final isAnchor =
                                            filePath == _anchorPath;
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
                                          ),
                                        ),
                                        if (selectionRect != null)
                                          Positioned(
                                            left: selectionRect.left,
                                            top: selectionRect.top,
                                            width: selectionRect.width,
                                            height: selectionRect.height,
                                            child: IgnorePointer(
                                              child: DecoratedBox(
                                                decoration: BoxDecoration(
                                                  color: _kBrutalistButton
                                                      .withValues(alpha: 0.25),
                                                  border: Border.all(
                                                    color: _kBrutalistButton,
                                                    width: 1,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
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
                                        _anchorPath == null ||
                                            _isScanning ||
                                            !backend.canSendHttp
                                        ? null
                                        : () {
                                            if (!islicensevalid ||
                                                licensekey == null ||
                                                licensekey!.trim().isEmpty) {
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
                                    onPressed: _sessionTags.isEmpty
                                        ? null
                                        : () => _exportRosterCsv(
                                            imagePaths,
                                            currentLoadDirectory,
                                          ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 20,
                                    ),
                                    child: const Text(
                                      'Export Roster (CSV)',
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
          if (!islicensevalid || islicenseverifying)
            Positioned.fill(child: _buildLicenseGateOverlay()),
        ],
      ),
    );
      },
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
