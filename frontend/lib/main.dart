import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

void main() {
  runApp(const ProviderScope(child: App()));
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
    final files = directory
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

final loadedFilesProvider = StateNotifierProvider<ImagePathsNotifier, List<String>>(
  (ref) => ImagePathsNotifier(),
);

final selectedFilesProvider =
    StateNotifierProvider<SelectedImagesNotifier, Set<String>>(
      (ref) => SelectedImagesNotifier(),
    );

final taggedFilesProvider = StateNotifierProvider<TagsNotifier, Map<String, String>>(
  (ref) => TagsNotifier(),
);

// Backward-compatible aliases for existing references.
final imagePathsProvider = loadedFilesProvider;
final selectedImagesProvider = selectedFilesProvider;
final tagsProvider = taggedFilesProvider;

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'VIP Tagger',
      theme: ThemeData.dark(),
      home: const HomePage(),
    );
  }
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  static final Uri _scanBadgeUri = Uri.parse('http://127.0.0.1:8001/scan-badge');
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
        throw const FormatException('Unexpected JSON response from scan endpoint');
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No tagged images to process.')));
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
    const sidebarColor = Color(0xFF1E1F24);
    const contentColor = Color(0xFF272932);

    return Scaffold(
      body: Row(
        children: [
          Container(
            width: _leftSidebarWidth,
            color: sidebarColor,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton(
                  onPressed:
                      () async => ref
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
                        onTap:
                            () => ref
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
              child:
                  imagePaths.isEmpty
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
                            onTap:
                                () => ref
                                    .read(selectedFilesProvider.notifier)
                                    .toggle(filePath),
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF1B1D24),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color:
                                      isSelected
                                          ? const Color(0xFF1EA7FF)
                                          : Colors.white24,
                                  width: isSelected ? 3 : 1,
                                ),
                              ),
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: Image.file(
                                        File(filePath),
                                        fit: BoxFit.cover,
                                        width: double.infinity,
                                        errorBuilder:
                                            (_, _, _) => Container(
                                              color: Colors.black38,
                                              alignment: Alignment.center,
                                              child: const Text('Preview N/A'),
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
                                    style: const TextStyle(color: Colors.white70),
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
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed:
                      selected.isEmpty || _isScanning ? null : _scanSelectedAnchorPhoto,
                  child:
                      _isScanning
                          ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
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
                    onPressed: _isProcessingBatch ? null : _process,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1EA7FF),
                      foregroundColor: Colors.black,
                      textStyle: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child:
                        _isProcessingBatch
                            ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            )
                            : const Text('Process Batch'),
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
