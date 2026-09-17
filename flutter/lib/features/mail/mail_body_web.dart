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
/// картинок и стилей, а скрипт наш — с одноразовым nonce.
///
/// Переходы по ссылкам наружу не остаются: внутри WebView чужому документу делать нечего —
/// адресной строки тут нет, назад из него пользователь не выберется, а тело письма уехало бы
/// вместе с экраном. Единственное исключение — сам документ письма; правило целиком и почему
/// именно такое — у [mailBodyLinkAction].
class MailBodyWeb extends StatefulWidget {
  /// Разметка тела письма как её отдал сервер.
  final String html;

  /// Высота до первого замера: без неё письмо схлопнулось бы в полоску, а список прыгал.
  final double minHeight;

  const MailBodyWeb(this.html, {super.key, this.minHeight = 140});

  @override
  State<MailBodyWeb> createState() => _MailBodyWebState();
}

/// Состояние WebView: контроллер и измеренная высота содержимого.
///
/// Состояние просит список держать себя живым ([AutomaticKeepAliveClientMixin]): WebView — самый
/// дорогой виджет на экране письма, а пересоздание — это полная перезагрузка чужого документа
/// (разметка, картинки, шрифты). Список выбрасывает содержимое за пределами видимой части, и без
/// этой просьбы письмо перезагружалось бы у человека на глазах.
class _MailBodyWebState extends State<MailBodyWeb> with AutomaticKeepAliveClientMixin {
  /// Контроллер создаётся один раз на виджет и переиспользуется между письмами: пересоздание
  /// на каждую загрузку — это ещё один WebView и потерянный нативный кэш.
  late final WebViewController _controller = _newController();
  /// Высота документа по последнему замеру; 0 — замера ещё не было, показывается `minHeight`.
  double _height = 0;

  /// Держать себя живым, пока экран письма открыт (см. комментарий класса).
  @override
  bool get wantKeepAlive => true;

  /// Собирает контроллер: включает JS, задаёт фон, вешает мост высоты и перехват навигации.
  ///
  /// JS включён не для письма — его скрипты вырезаны сервером и запрещены CSP, — а для нашего
  /// скрипта замера, который приходит с одноразовым nonce.
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
  /// Первая загрузка письма в уже созданный WebView.
  void initState() {
    super.initState();
    _load();
  }

  @override
  /// Перезагрузка содержимого, когда пришла другая разметка (переключение вида).
  void didUpdateWidget(MailBodyWeb oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Переключение «разметка ↔ текст» приносит другую строку html в тот же виджет (WebView
    // переиспользуется), поэтому содержимое надо перезагрузить вручную.
    if (oldWidget.html != widget.html) _load();
  }

  /// Загружает разметку письма, обернув её в документ с CSP, нормализацией и скриптом высоты.
  ///
  /// Высота сбрасывается: прежняя относится к прошлому письму, а новое может быть короче —
  /// иначе под коротким текстом осталось бы пустое место до первого замера.
  void _load() {
    _height = 0;
    _controller.loadHtmlString(mailBodyDocument(widget.html));
  }

  /// Принимает высоту из скрипта замера.
  ///
  /// Замер приходит строкой из чужого документа, поэтому проверяется: не число или не
  /// положительное — игнорируем. Потолок — предохранитель от письма-обманки с бесконечным
  /// ростом: высота приходит из чужого документа, и верить ей безгранично нельзя.
  /// Порог в 1 px гасит дрожание: скрипт мерит высоту многократно, и перерисовка на каждое
  /// изменение на пиксель стоила бы дороже, чем заметный сдвиг.
  ///
  /// Свой прошлый замер здесь не сравнивается с новым: «письмо растёт само по себе» гасится
  /// в самом скрипте — он меряет содержимое, а не окно (см. [_heightScript]).
  void _onHeight(JavaScriptMessage message) {
    final measured = double.tryParse(message.message);
    if (measured == null || measured <= 0) return;
    // Потолок — предохранитель от письма-обманки с бесконечным ростом (см. выше).
    final next = measured.clamp(widget.minHeight, 40000.0);
    if ((next - _height).abs() < 1) return;
    if (!mounted) return;
    setState(() => _height = next);
  }

  /// Решает судьбу каждого перехода внутри WebView.
  ///
  /// Само решение принимает [mailBodyLinkAction] — её и проверяет тест: правило тут
  /// охранное, а `WebViewController` в юнит-тесте не поднять.
  NavigationDecision _onNavigation(NavigationRequest request) {
    switch (mailBodyLinkAction(request.url)) {
      case MailBodyLinkAction.keepInside:
        return NavigationDecision.navigate;
      case MailBodyLinkAction.openOutside:
        // Открываем без ожидания: делегат обязан ответить синхронно, а показ подсказки
        // о неудаче — дело `_openOutside`.
        unawaited(_openOutside(request.url));
        return NavigationDecision.prevent;
      case MailBodyLinkAction.block:
        return NavigationDecision.prevent;
    }
  }

  /// Открывает ссылку системным обработчиком: `externalApplication` выводит её из приложения —
  /// в браузер для http(s) или в почтовый клиент для `mailto:`.
  ///
  /// Побочно: подсказка, если открыть не удалось (обработчика нет или система отказала) —
  /// иначе нажатие выглядело бы как «кнопка не работает». Успех озвучивать нечем: экран уходит
  /// на другое приложение.
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
    // Просьба «держать живым» уходит подпиской, которую ставит миксин: без этого вызова
    // состояние не узнает, что его собираются выбросить, и просьба не сработает.
    super.build(context);
    // Высота списка — это и есть высота письма: WebView сам по себе не тянется под содержимое,
    // поэтому до первого замера берём minHeight, а дальше измеренное значение.
    return SizedBox(
      height: _height > 0 ? _height : widget.minHeight,
      child: WebViewWidget(controller: _controller),
    );
  }
}

/// Что делать с переходом по ссылке из тела письма.
///
/// Три случая, а не два, потому что «оставить внутри» и «открыть наружу» — не всё: переход,
/// который не годится ни туда, ни туда, надо просто погасить.
enum MailBodyLinkAction {
  /// Адрес нашего же документа письма: его грузит `loadHtmlString`, и запрет сломал бы отрисовку.
  keepInside,

  /// Уходит системному обработчику: браузеру для http(s), почтовому клиенту для `mailto:`.
  openOutside,

  /// Ни внутри, ни наружу: чужой документ, которому нечего делать на экране.
  block,
}

/// Куда девается переход по [url] из тела письма.
///
/// Внутри остаётся только сам документ письма: `loadHtmlString` грузит его как `about:blank`.
/// Разрешена вся схема `about:` — адреса внутренние, никуда не ходят и чужого документа не грузят,
/// а придираться к конкретному `about:blank` значило бы рисковать отрисовкой письма ради различия,
/// которого на телефоне не видно.
///
/// `data:` гасится, хотя соблазн пропустить его внутрь есть: по такой ссылке WebView загрузил бы
/// документ, целиком собранный отправителем, с работающим JS (он включён ради замера высоты)
/// и нашим каналом высоты. Вшитые картинки и вложения от этого не страдают: сервер подставляет
/// их в `src`/`srcset`, а переход по ссылке и загрузка подресурса — разные события, делегат
/// навигации про второе не спрашивает. Наружу `data:` тоже не отдаём: системному браузеру
/// такой документ показывать нечего.
///
/// Остальное — `http`, `https`, `mailto:`, `tel:` и прочие схемы — уходит из приложения. Внутри
/// WebView этому не место: адресной строки и кнопки «назад» тут нет, пользователь не смог бы
/// вернуться к письму, а сама страница — чужой документ, которому незачем давать доступ к нашему
/// экрану.
MailBodyLinkAction mailBodyLinkAction(String url) {
  if (url.startsWith('about:')) return MailBodyLinkAction.keepInside;
  if (url.startsWith('data:')) return MailBodyLinkAction.block;
  return MailBodyLinkAction.openOutside;
}

/// Рамка вокруг разметки письма: заголовок документа плюс наш скрипт высоты.
///
/// Разметка приходит и полным документом (`<html><head>…`), и куском тела — поэтому рамку
/// вставляем туда, где ей место, а кусок заворачиваем в документ сами.
///
/// Точки вставки именно такие, потому что документ письма чужой и его нельзя переписать целиком
/// (это потеряло бы разметку и стили): мета-теги и стили идут сразу после `<head>` (или после
/// `<html>`, если головы нет), а скрипт замера — прямо перед `</body>`, чтобы к моменту его
/// исполнения разметка уже была разобрана. Если в разметке нет ни головы, ни закрытия тела,
/// её заворачивает ветка по умолчанию.
String mailBodyDocument(String html) {
  // Nonce один на документ: он попадает и в CSP, и в тег нашего скрипта, поэтому чужой скрипт
  // (если чистка сервера что-то пропустила) его не угадает и исполнен не будет.
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
///
/// Почему именно так, по каждой директиве:
/// `default-src 'none'` — запрет по умолчанию, чтобы ничего не забылось (запросы, фреймы, медиа);
/// `img-src data: https: http:` — `data:` это вшитые вложения, http(s) — картинки по ссылке,
/// без них рассылка теряет половину смысла;
/// `style-src 'unsafe-inline' https: http:` — письма верстают inline-стилями (и подключаемыми
/// таблицами стилей), подпись по nonce тут не годится, потому что стили пишет отправитель;
/// `font-src` — иконочные шрифты, которыми свёрстаны кнопки в рассылках;
/// `script-src 'nonce-$nonce'` — исполняется только наш скрипт замера;
/// `base-uri 'none'` и `form-action 'none'` — чтобы письмо не могло подменить базу относительных
/// ссылок и не отправляло формы (в том числе с данными со страницы) на чужой сервер.
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
///
/// `color-scheme: light` — единственное исключение из «не вмешиваемся»: без него WebView
/// на тёмной теме сам перекрашивает светлую разметку, и письмо приезжает с чужими цветами.
/// `img { max-width: 100% !important }` — рассылки верстают под ширину письма на десктопе
/// (600–800 px), и на телефоне картинка иначе вылезает за экран и растягивает документ;
/// `!important` нужен, потому что свои размеры отправитель ставит атрибутом или inline-стилем.
/// `pre` — текстовая версия письма приходит завёрнутой в `<pre>`, и без переноса она уезжает
/// в горизонтальную прокрутку.
///
/// `html, body { height: auto; min-height: 0 }` — тоже про растягивание, но с другой стороны:
/// у высоких макетов (а их шлют и в письмах) корень подписан `height: 100%` или
/// `min-height: 100vh`, и тогда высота документа становится высотой окна, а не содержимого.
/// Внутри списка писем это давало два бедствия сразу: короткое письмо занимало экран пустым
/// местом, а окно, выставленное по замеру, снова поднимало эту же высоту — письмо «дорастало»
/// на каждом замере. `!important` здесь обязателен: объявление отправителя чаще всего inline,
/// и без веса оно выиграло бы у нашего правила.
const _normalizeCss = '''
:root { color-scheme: light; }
html, body { margin: 0; padding: 0; background: #fff; overflow-x: hidden; height: auto !important; min-height: 0 !important; }
body { padding: 10px 12px; -webkit-text-size-adjust: 100%; word-wrap: break-word; }
img { max-width: 100% !important; height: auto !important; }
table { max-width: 100% !important; }
pre { white-space: pre-wrap; word-wrap: break-word; }
a { word-break: break-word; }
''';

/// Скрипт замера: WebView не сообщает, сколько места заняло содержимое, а письмо должно расти
/// внутри общего списка.
///
/// Почему замер устроен именно так — три правила, и каждое закрывает свою поломку вёрстки:
///
///  • **меряем содержимое, а не документ**. `scrollHeight` никогда не бывает меньше высоты
///    окна, поэтому короткое письмо всегда «занимало» целый экран, а выставленная по замеру
///    высота на следующем круге снова попадала в замер — письмо росло вниз само по себе.
///    Поэтому высота берётся у самого `body` (его высота — это его содержимое) плюс, на случай
///    выпавших из потока элементов, самая нижняя граница среди детей;
///  • **единицы вьюпорта пересчитываются в пиксели** ([freezeViewportUnits]). `100vh` внутри
///    письма — это высота окна, то есть ровно та величина, которую мы и выставляем: замер
///    зависел бы от собственного прошлого результата и рос бесконечно. Опорой служит высота
///    экрана (`screen.height`), а не окна: она не меняется от наших же правок. `min-height`
///    в этих единицах гасится в ноль целиком — на телефоне он даёт не «во весь экран», а
///    пустое место под коротким письмом;
///  • **широкие блоки сужаются** ([clampOverflow]): рассылки свёрстаны под 600–800 px, и
///    фиксированная ширина на телефоне обрезала содержимое. Сужаем только то, что и правда
///    шире окна, — остального не касаемся.
///
/// Пересчёт идёт по четырём поводам, потому что одного из них мало: сразу при разборе (быстрый
/// случай — короткий текст), по `DOMContentLoaded` и `load` (готовность документа и ресурсов),
/// через `ResizeObserver` (письмо «доросло» из-за картинки без перезагрузки) и, наконец,
/// интервалом 250 мс — страховка на случай, когда ничего из перечисленного не сработало.
/// Интервал снимает себя, как только замер устоялся (три одинаковых подряд), а если письмо
/// почему-то продолжает меняться — после 40 замеров (10 с), чтобы не тикать вечно.
const _heightScript = r'''
(function () {
  // Опорная высота для единиц вьюпорта: высота экрана, а не окна — окно мы и меняем замером.
  var refH = (window.screen && window.screen.height) || window.innerHeight || 0;

  // Пересчёт vh/vmin/vmax в пиксели: без него письмо растёт от собственной высоты (см. выше).
  function freezeViewportUnits() {
    if (!refH) return;
    var units = /(-?\d*\.?\d+)(vh|vmin|vmax)\b/gi;
    function swap(css) {
      if (!css || css.indexOf('v') < 0) return css;
      // min-height в единицах вьюпорта — это «не меньше экрана», то есть пустое место.
      css = css.replace(/min-height\s*:\s*-?\d*\.?\d+(vh|vmin|vmax)/gi, 'min-height:0');
      return css.replace(units, function (all, n, unit) {
        var u = unit.toLowerCase();
        var base = u === 'vmin' ? Math.min(refH, window.innerWidth || refH)
                 : u === 'vmax' ? Math.max(refH, window.innerWidth || refH)
                 : refH;
        return (parseFloat(n) * base / 100) + 'px';
      });
    }
    var i, s, t;
    var styled = document.querySelectorAll('[style]');
    for (i = 0; i < styled.length; i++) {
      s = styled[i].getAttribute('style');
      t = swap(s);
      if (t !== s) styled[i].setAttribute('style', t);
    }
    var sheets = document.querySelectorAll('style');
    for (i = 0; i < sheets.length; i++) {
      s = sheets[i].textContent || '';
      t = swap(s);
      if (t !== s) sheets[i].textContent = t;
    }
  }

  // Сужение блоков шире окна: фиксированные ширины десктопных рассылок на телефоне обрезаются.
  function clampOverflow() {
    var vw = document.documentElement.clientWidth || window.innerWidth || 0;
    if (!vw || !document.body) return;
    var all = document.body.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      if (all[i].getBoundingClientRect().width > vw + 1) all[i].style.maxWidth = '100%';
    }
  }

  // Высота содержимого: высота body (у неё auto — значит, по содержимому) и, на всякий случай,
  // самая нижняя граница среди детей — так видно элементы, выпавшие из потока (float, absolute).
  function measure() {
    var b = document.body;
    if (!b) return 0;
    var r = b.getBoundingClientRect();
    var h = r.height;
    for (var i = 0; i < b.children.length; i++) {
      var cr = b.children[i].getBoundingClientRect();
      if (cr.bottom - r.top > h) h = cr.bottom - r.top;
    }
    return Math.ceil(h);
  }

  var last = 0, stable = 0;
  function report() {
    if (!window.MailBody) return;
    var h = measure();
    if (h <= 0) return;
    if (Math.abs(h - last) < 1) {
      stable++;              // высота не меняется — значит, письмо устоялось
    } else {
      last = h;
      stable = 0;
      window.MailBody.postMessage(String(h));
    }
  }

  freezeViewportUnits();
  clampOverflow();
  report();
  // На готовности документа и ресурсов обе правки повторяются: скрипт стоит в самом конце
  // документа, но элементы после него и пришедшие позже (картинки) в первый проход не попали.
  // Повтор безвреден: vh-единиц после первого прохода в разметке уже нет.
  document.addEventListener('DOMContentLoaded', function () { freezeViewportUnits(); clampOverflow(); report(); });
  window.addEventListener('load', function () { freezeViewportUnits(); clampOverflow(); report(); });
  try { if (window.ResizeObserver) new ResizeObserver(report).observe(document.documentElement); } catch (e) {}
  var n = 0, t = setInterval(function () {
    report();
    if (stable >= 3 || ++n > 40) clearInterval(t);
  }, 250);
})();
''';
