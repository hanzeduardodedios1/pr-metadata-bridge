import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

void main() {
  runApp(const ProviderScope(child: App()));
}

class ImagePathsNotifier extends StateNotifier<List<String>> {
  ImagePathsNotifier() : super(const []);

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
        .map((file) => file.path)
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

  void toggle(String filePath) {
    final next = {...state};
    if (next.contains(filePath)) {
      next.remove(filePath);
    } else {
      next.add(filePath);
    }
    state = next;
  }

  void clear() {
    state = <String>{};
  }
}

class TagsNotifier extends StateNotifier<Map<String, String>> {
  TagsNotifier() : super(<String, String>{});

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
      next[filePath] = normalizedVip;
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

final imagePathsProvider =
    StateNotifierProvider<ImagePathsNotifier, List<String>>(
      (ref) => ImagePathsNotifier(),
    );

final selectedImagesProvider =
    StateNotifierProvider<SelectedImagesNotifier, Set<String>>(
      (ref) => SelectedImagesNotifier(),
    );

final tagsProvider = StateNotifierProvider<TagsNotifier, Map<String, String>>(
  (ref) => TagsNotifier(),
);

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'VIP Tagger',
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
  final _tagController = TextEditingController();

  @override
  void dispose() {
    _tagController.dispose();
    super.dispose();
  }

  void _assignTag() {
    final selectedPaths = ref.read(selectedImagesProvider);
    final vipName = _tagController.text;
    ref
        .read(tagsProvider.notifier)
        .assignTagToSelection(selectedPaths: selectedPaths, vipName: vipName);
  }

  void _process() {
    final jsonMap = ref.read(tagsProvider.notifier).filenameToVipMap();
    final jsonString = const JsonEncoder.withIndent('  ').convert(jsonMap);
    debugPrint('Processed JSON map:\n$jsonString');
  }

  @override
  Widget build(BuildContext context) {
    final imagePaths = ref.watch(imagePathsProvider);
    final selected = ref.watch(selectedImagesProvider);
    final tags = ref.watch(tagsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('VIP Image Tagger')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ElevatedButton(
                  onPressed:
                      () async => ref
                          .read(imagePathsProvider.notifier)
                          .pickFolderAndLoadJpegs(),
                  child: const Text('Pick Folder'),
                ),
                SizedBox(
                  width: 240,
                  child: TextField(
                    controller: _tagController,
                    decoration: const InputDecoration(
                      labelText: 'VIP Name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: _assignTag,
                  child: const Text('Assign Tag'),
                ),
                ElevatedButton(
                  onPressed:
                      () => ref.read(selectedImagesProvider.notifier).clear(),
                  child: const Text('Clear Selection'),
                ),
                ElevatedButton(
                  onPressed: () => ref.read(tagsProvider.notifier).clear(),
                  child: const Text('Clear All Tags'),
                ),
                ElevatedButton(
                  onPressed: _process,
                  child: const Text('Process'),
                ),
                Text(
                  'Loaded: ${imagePaths.length} | Selected: ${selected.length} | Tagged: ${tags.length}',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child:
                  imagePaths.isEmpty
                      ? const Center(
                        child: Text('No JPEG files loaded.'),
                      )
                      : GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 4,
                              childAspectRatio: 1.15,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
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
                                    .read(selectedImagesProvider.notifier)
                                    .toggle(filePath),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color:
                                      isSelected
                                          ? Colors.blue
                                          : Colors.black26,
                                  width: isSelected ? 2 : 1,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Image.file(
                                      File(filePath),
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      errorBuilder:
                                          (_, _, _) =>
                                              const Center(child: Text('N/A')),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
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
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
    );
  }
}
