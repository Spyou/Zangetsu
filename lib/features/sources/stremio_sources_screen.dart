import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/provider/stremio_manager.dart';
import '../../core/provider/stremio_provider.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../search/browse_source_screen.dart';

class StremioSourcesScreen extends StatefulWidget {
  const StremioSourcesScreen({super.key});

  @override
  State<StremioSourcesScreen> createState() => _StremioSourcesScreenState();
}

class _StremioSourcesScreenState extends State<StremioSourcesScreen> {
  Future<void> _add() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Stremio addon'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://addon.example'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || url == null || url.trim().isEmpty) return;
    try {
      await sl<StremioManager>().add(url);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not add addon: $e')));
      }
    }
  }

  Future<void> _showCatalog(
    StremioProvider provider,
    StremioCatalog catalog,
  ) async {
    try {
      final items = await provider.catalog(catalog);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.surface,
        builder: (_) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .8,
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, index) => ListTile(
                leading: items[index].cover == null
                    ? const Icon(Icons.movie_outlined)
                    : Image.network(
                        items[index].cover!,
                        width: 44,
                        fit: BoxFit.cover,
                      ),
                title: Text(items[index].title),
                subtitle: Text(items[index].id),
              ),
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Catalog failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = sl<StremioManager>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Stremio addons'),
        actions: [
          IconButton(
            onPressed: _add,
            icon: const Icon(Icons.add),
            tooltip: 'Add addon',
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) => manager.all.isEmpty
            ? Center(
                child: Text('No Stremio addons installed', style: AppText.body),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final provider in manager.all)
                    Card(
                      child: ExpansionTile(
                        title: Text(provider.displayName),
                        subtitle: Text(provider.baseUrl),
                        onExpansionChanged: (_) {},
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => manager.remove(provider.baseUrl),
                        ),
                        children: [
                          ListTile(
                            leading: const Icon(Icons.open_in_new_rounded),
                            title: const Text('Browse addon catalogs'),
                            subtitle: const Text(
                              'Choose a catalog, then open titles normally',
                            ),
                            onTap: () => Navigator.push<void>(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => BrowseSourceScreen(
                                  sourceId: provider.sourceId,
                                  title: provider.displayName,
                                ),
                              ),
                            ),
                          ),
                          FutureBuilder<StremioManifest>(
                            future: provider.manifest,
                            builder: (context, snapshot) {
                              final catalogs =
                                  snapshot.data?.catalogs ?? const [];
                              if (snapshot.hasError) {
                                return ListTile(
                                  title: Text(
                                    'Manifest failed: ${snapshot.error}',
                                  ),
                                );
                              }
                              if (!snapshot.hasData) {
                                return const LinearProgressIndicator();
                              }
                              return Column(
                                children: [
                                  for (final catalog in catalogs)
                                    ListTile(
                                      leading: const Icon(
                                        Icons.view_list_outlined,
                                      ),
                                      title: Text(catalog.name),
                                      subtitle: Text(
                                        '${catalog.type} · ${catalog.id}',
                                      ),
                                      onTap: () =>
                                          _showCatalog(provider, catalog),
                                    ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
