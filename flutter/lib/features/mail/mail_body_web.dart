import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../util/widgets.dart';

/// Тело письма на экране: системный WebView с той же разметкой, что видит веб-интерфейс.
///
/// Почему WebView, а не разбор разметки на виджеты. Письма верстают так, как верстали до
/// мобильной эры: таблицы, вложенные таблицы, медиазапросы, inline-стили. Это разметка для
/// браузерного движка, и пересказ её виджетами всегда врёт: flutter_html умеет часть CSS,
/// медиазапросы роняли его разбор, а таблицы приходилось разбирать на блоки — двухколоночные
/// рассылки вставали столбиком. WebView в телефоне — тот же движок, что в браузере, поэтому
/// письмо выглядит как в вебе, и разметка на оба клиента остаётся одна.
///
/// Разметку по-прежнему чистит сервер (src/mail/mail-html.ts), вложения по cid он же заменяет
/// на data:-ссылки, поэтому страница самодостаточна: ни авторизации, ни cookies WebView не нужен.
///
/// Скрипты включены ради одного: узнать высоту содержимого. WebView не сообщает её сам, а без
/// неё письмо не может расти внутри общего списка. Своя страница письма при этом ничего не
/// исполняет: сервер вырезал `<script>`, CSP документа запрещает грузить что-либо, кроме
/// картинок и стилей, а скрипт наш — с одноразовым nonce. Переходы по ссылкам уходят в браузер,
/// а не внутрь WebView.
class MailBodyWeb extends StatefulWidget {
  /// Разметка тела письма как её отдал сервер.
  final String html;

  /// Высота до первого замера: без неё письмо схлопнулось бы в полоску, а список прыгал.
  final double minHeight;

  const MailBodyWeb(this.html, {super.key, this.minHeight = 140});

  @override
  State<MailBodyWeb> createState() => _MailBodyWebState();
}

class _MailBodyWebState extends State<MailBodyWeb> {
  late final WebViewController _controller = _newController();
  double _height = 0;

  WebViewController _newController() {
    return WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Фон белый: письмо верстают под белый лист, а WebView по умолчанию прозрачный —
      // на тёмной теме это выглядело бы как чёрный прямоугольник до первой отрисовки.
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..addJavaScriptChannel('MailBody', onMessageReceived: _onHeight)
      ..setNavigationDelegate(NavigationDelegate(onNavigationRequest: _onNavigation));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MailBodyWeb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) _load();
  }

  void _load() {
    _height = 0;
    _controller.loadHtmlString(mailBodyDocument(widget.html));
  }

  void _onHeight(JavaScriptMessage message) {
    final measured = double.tryParse(message.message);
    if (measured == null || measured <= 0) return;
    // Потолок — предохранитель от письма-обманки с бесконечным ростом: высота приходит из
    // чужого документа, и верить ей безгранично нельзя.
    final next = measured.clamp(widget.minHeight, 40000.0);
    if ((next - _height).abs() < 1) return;
    if (!mounted) return;
    setState(() => _height = next);
  }

  /// Ссылки из письма открываем в браузере: внутри WebView чужой странице делать нечего,
  /// да и назад из неё пользователь не выберется (своей адресной строки тут нет).
  NavigationDecision _onNavigation(NavigationRequest request) {
    final url = request.url;
    if (url.startsWith('about:') || url.startsWith('data:')) return NavigationDecision.navigate;
    unawaited(_openOutside(url));
    return NavigationDecision.prevent;
  }

  Future<void> _openOutside(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) snack(context, 'Не удалось открыть ссылку');
    } catch (_) {
      if (mounted) snack(context, 'Не удалось открыть ссылку');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _height > 0 ? _height : widget.minHeight,
      child: WebViewWidget(controller: _controller),
    );
  }
}

/// Рамка вокруг разметки письма: заголовок документа плюс наш скрипт высоты.
///
/// Разметка приходит и полным документом (`<html><head>…`), и куском тела — поэтому рамку
/// вставляем туда, где ей место, а кусок заворачиваем в документ сами.
String mailBodyDocument(String html) {
  final nonce = _nonce();
  final head = '<meta http-equiv="Content-Security-Policy" content="${_csp(nonce)}">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style>$_normalizeCss</style>';
  final script = '<script nonce="$nonce">$_heightScript</script>';

  final headOpen = RegExp(r'<head[^>]*>', caseSensitive: false);
  final htmlOpen = RegExp(r'<html[^>]*>', caseSensitive: false);
  final bodyClose = RegExp(r'</body>', caseSensitive: false);

  var out = html;
  if (headOpen.hasMatch(out)) {
    out = out.replaceFirstMapped(headOpen, (m) => '${m[0]}$head');
  } else if (htmlOpen.hasMatch(out)) {
    out = out.replaceFirstMapped(htmlOpen, (m) => '${m[0]}<head>$head</head>');
  } else {
    out = '<html><head>$head</head><body>$out</body></html>';
  }

  if (bodyClose.hasMatch(out)) {
    out = out.replaceFirst(bodyClose, '$script</body>');
  } else {
    out = '$out$script';
  }
  return out;
}

/// Разметка письма — чужой документ, поэтому грузить ему разрешено ровно то, без чего письмо
/// не читается: картинки, стили и шрифты. Скрипты — только наш, по одноразовому nonce.
String _csp(String nonce) =>
    "default-src 'none'; img-src data: https: http:; style-src 'unsafe-inline' https: http:; "
    "font-src data: https: http:; script-src 'nonce-$nonce'; base-uri 'none'; form-action 'none'";

/// Одноразовый nonce для нашего скрипта: разметка письма его не знает, значит её скрипты
/// (если чистка что-то пропустит) не исполнятся.
String _nonce() {
  final rnd = Random.secure();
  return List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Нормализация под узкий экран. Своих цветов и шрифтов не навязываем: письмо верстают под
/// белый лист, но палитру выбирает отправитель, и перебивать её — значит получить чёрный текст
/// на чёрном фоне. Правим только то, что на телефоне заведомо ломается: ширина картинок и
/// таблиц, длинные ссылки, горизонтальная прокрутка.
const _normalizeCss = '''
:root { color-scheme: light; }
html, body { margin: 0; padding: 0; background: #fff; overflow-x: hidden; }
body { padding: 10px 12px; -webkit-text-size-adjust: 100%; word-wrap: break-word; }
img { max-width: 100% !important; height: auto !important; }
table { max-width: 100% !important; }
pre { white-space: pre-wrap; word-wrap: break-word; }
a { word-break: break-word; }
''';

/// Скрипт высоты: WebView не сообщает, сколько места заняло содержимое, а письмо должно расти
/// внутри общего списка. Считаем высоту документа и пересчитываем её, пока письмо не устоится
/// (картинки и шрифты приходят позже разметки).
const _heightScript = r'''
(function () {
  var last = 0;
  function report() {
    if (!window.MailBody) return;
    var d = document.documentElement, b = document.body;
    var h = Math.ceil(Math.max(d ? d.scrollHeight : 0, b ? b.scrollHeight : 0));
    if (h > 0 && h !== last) { last = h; window.MailBody.postMessage(String(h)); }
  }
  report();
  document.addEventListener('DOMContentLoaded', report);
  window.addEventListener('load', report);
  try { if (window.ResizeObserver) new ResizeObserver(report).observe(document.documentElement); } catch (e) {}
  var n = 0, t = setInterval(function () { report(); if (++n > 20) clearInterval(t); }, 250);
})();
''';
