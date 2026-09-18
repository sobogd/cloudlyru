import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';
import 'ai_types.dart';
import 'chat_controller.dart';
import 'chat_thread_screen.dart';

/// Раздел «Чат»: список чатов и вход в переписку.
///
/// Раздел открывается на списке, как в приложениях ChatGPT и Gemini: чатов бывает много, темы
/// разные, и начинать всегда с пустой переписки неудобно. История лежит на сервере, поэтому
/// чаты общие для телефона и ноутбука, а не у каждого свои.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

/// Состояние экрана: список чатов живёт в провайдере, здесь — только навигация и подтверждения.
class _ChatScreenState extends ConsumerState<ChatScreen> {
  /// Контроллер списка, взятый один раз в `initState`: обновлять список нужно и после
  /// возврата из переписки, а держать ссылку на провайдер до этого момента проще, чем читать
  /// его каждый раз заново.
  late final ChatsController _chats;

  @override
  void initState() {
    super.initState();
    _chats = ref.read(chatsProvider.notifier);
    // список читаем при первом открытии раздела: до этого момента вкладки не существует, и
    // запрос в сеть на старте приложения был бы лишним
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _chats.load();
    });
  }

  /// Создаёт чат и открывает его переписку.
  ///
  /// После возврата список перечитывается: за время разговора сервер назвал чат по первому
  /// вопросу и поднял его наверх — без перезагрузки тема в списке осталась бы старой.
  Future<void> _newChat() async {
    final chat = await _chats.create();
    if (chat == null || !mounted) return;
    await _openThread(chat);
  }

  /// Открывает переписку чата и обновляет список после возврата.
  Future<void> _openThread(AiChat chat) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChatThreadScreen(chat: chat)),
    );
    if (mounted) await _chats.load();
  }

  /// Переименование темы чата.
  Future<void> _rename(AiChat chat) async {
    final title = await promptDialog(context, 'Тема чата', initial: chat.title);
    if (title == null || title.trim().isEmpty || !mounted) return;
    await _chats.rename(chat, title.trim());
  }

  /// Удаление чата вместе с перепиской (спрашиваем подтверждение: удаление необратимо).
  Future<void> _delete(AiChat chat) async {
    final ok = await confirmDialog(
      context,
      'Удалить чат',
      'Переписка «${chat.title}» будет удалена вместе с сообщениями. Восстановить её нечем.',
      danger: true,
      confirmLabel: 'Удалить',
    );
    if (!ok || !mounted) return;
    await _chats.remove(chat.id);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatsProvider);

    return Scaffold(
      // Цвет шапки задаёт `appBarTheme` из `theme.dart`, как и на остальных разделах.
      appBar: AppBar(
        title: const Text('Чат', style: TextStyle(color: C.fg, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Обновить список',
            onPressed: state.loading ? null : () => _chats.load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: state.configured
          ? FloatingActionButton(
              tooltip: 'Новый чат',
              backgroundColor: C.accent,
              foregroundColor: C.accentFg,
              onPressed: _newChat,
              child: const Icon(Icons.add),
            )
          : null,
      body: Column(
        children: [
          // Без ключа на сервере чат не заработает ничем, что можно сделать в приложении:
          // ключ задаётся секретом репозитория и попадает на сервер при выкладке. Говорим об
          // этом словами, а не пустым списком.
          if (!state.configured) const _NotConfiguredNotice(),
          if (state.error != null) _errorBar(state.error!),
          Expanded(child: _body(state)),
        ],
      ),
    );
  }

  /// Тело экрана: индикатор загрузки, пустой список или сами чаты.
  Widget _body(ChatsState state) {
    if (state.loading && state.chats.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.chats.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            state.configured
                ? 'Чатов пока нет. Нажмите «+», чтобы начать разговор.'
                : 'Чат появится, когда на сервере будет задан ключ xAI.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.fg3, fontSize: 13, height: 1.4),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _chats.load(),
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: state.chats.length,
        itemBuilder: (context, i) => _chatTile(state.chats[i]),
      ),
    );
  }

  /// Строка списка: тема, модель, число сообщений и время последнего.
  Widget _chatTile(AiChat chat) {
    return ListTile(
      leading: const Icon(Icons.chat_bubble_outline, color: C.fg2),
      title: Text(
        chat.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: C.fg, fontSize: 15),
      ),
      subtitle: Text(
        // время последнего сообщения показываем в том же формате, что и в остальных списках
        [
          chat.model,
          '${chat.messages} сообщ.',
          if (chat.updatedAt != null) listDate(chat.updatedAt!, DateTime.now()),
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: C.fg3, fontSize: 12),
      ),
      onTap: () => _openThread(chat),
      trailing: PopupMenuButton<String>(
        tooltip: 'Действия',
        onSelected: (v) => v == 'rename' ? _rename(chat) : _delete(chat),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'rename', child: Text('Переименовать')),
          PopupMenuItem(value: 'delete', child: Text('Удалить')),
        ],
      ),
    );
  }

  /// Сообщение об ошибке над списком: ошибка списка — не то же, что ошибка в переписке.
  Widget _errorBar(String message) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: C.danger),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, color: C.danger, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: const TextStyle(color: C.fg2, fontSize: 13, height: 1.3)),
            ),
          ],
        ),
      );
}

/// Подсказка, когда на сервере не задан ключ xAI.
///
/// Это не сбой запроса, а состояние сервера: ключ лежит в окружении сервера (`GROK_API_KEY`),
/// приходит из секрета репозитория при выкладке. В приложении его ввести нельзя — так и
/// задумано: из APK ключ извлекается, а с сервера он не уходит никуда.
class _NotConfiguredNotice extends StatelessWidget {
  const _NotConfiguredNotice();

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.key_off_outlined, color: C.warn, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'На сервере не задан ключ xAI (GROK_API_KEY), поэтому ответить некому. Ключ '
              'задаётся секретом репозитория и попадает на сервер при выкладке.',
              style: TextStyle(color: C.fg2, fontSize: 13, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}
