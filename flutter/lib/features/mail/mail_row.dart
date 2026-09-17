import 'package:flutter/material.dart';

import '../../api/cloudly_api.dart';
import '../../api/models.dart';
import '../../theme.dart';
import '../../util/format.dart';
import '../../util/widgets.dart';

/// Базовая высота строки письма — до поправки на системный размер шрифта.
///
/// Строка — это две строки текста (отправитель и тема) фиксированными кеглями плюс отступы
/// 8+8. Значение лежит здесь, а не в экране, потому что строку рисуют два экрана — лента
/// (`mail_screen.dart`) и поиск (`mail_search_screen.dart`), и высота у них обязана совпадать.
///
/// В ленте число служит не только вёрстке: по нему считаются индексы видимой части списка
/// (`itemExtent` и `_fetchVisible`), поэтому там оно берётся отсюда как есть.
const mailRowBase = 52.0;

/// Размер логотипа отправителя в строке.
///
/// Намеренно маленький: это метка домена рядом с именем, а не аватар на всю строку.
const _faviconSize = 18.0;

/// Строка письма: [favicon] отправитель · метка аккаунта · дата, ниже — тема.
///
/// Здесь же живут общие для экранов почты мелочи — разбор домена адреса, подпись аккаунта
/// и название папки: строка, лента и поиск обязаны показывать одно и то же одинаково.
///
/// Тела письма в строке нет намеренно (так решил владелец): в списке видно, от кого письмо
/// и о чём оно, а текст читается уже в самом письме. Из этого же следует, что высота строки
/// фиксирована и одинакова у всех писем — на ней держится виртуализация ленты.
///
/// Логотип домена рисуется только тогда, когда домен у адреса разобран, и никогда не
/// подменяется кружком с буквой: нет логотипа — нет и иконки. Место под логотип при этом
/// остаётся занятым: если бы строка сжималась, имя отправителя прыгало бы влево-вправо
/// в момент загрузки картинки (в ленте строки появляются на ходу при прокрутке).
class MailRow extends StatelessWidget {
  const MailRow({
    super.key,
    required this.api,
    required this.item,
    required this.accounts,
    required this.onTap,
  });

  /// Клиент API: из него берутся заголовки сессии для картинки логотипа.
  final CloudlyApi api;
  /// Письмо строки (одна и та же модель у ленты и у поиска).
  final MailListItem item;
  /// Аккаунты пользователя: по ним решается, показывать в строке домен или полный адрес.
  final List<MailAccountRow> accounts;
  /// Что делать по нажатию — открыть письмо.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final domain = domainOfEmail(item.fromAddr);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.brd))),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                // Логотип домена: сервер тянет и кэширует его сам (`/mail/favicon`), поэтому
                // клиент в чужой сайт не ходит. Нет логотипа — `AuthThumb` отдаёт пустую
                // заглушку, и в строке остаётся только отступ (см. комментарий к классу).
                if (domain != null) ...[
                  AuthThumb(
                    api: api,
                    url: api.faviconUrl(domain),
                    size: _faviconSize,
                    radius: 5,
                    fallback: const SizedBox.shrink(),
                  ),
                  const SizedBox(width: 6),
                ],
                // Жирный шрифт — признак непрочитанного: отдельной точки-индикатора в строке нет,
                // поэтому вес шрифта несёт всю разницу между прочитанным и новым письмом.
                Expanded(
                  child: Text(
                    item.fromName ?? item.fromAddr ?? 'без отправителя',
                    style: TextStyle(
                      color: C.fg,
                      fontSize: 14,
                      fontWeight: item.seen ? FontWeight.w400 : FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Число писем в цепочке: сервер уже свернул переписку в одну строку, и без
                // этой цифры непонятно, что внутри ещё есть письма.
                if (item.threadCount > 1) Text('${item.threadCount}', style: const TextStyle(color: C.fg3, fontSize: 11)),
                const SizedBox(width: 6),
                Text(accountTagOf(item, accounts), style: const TextStyle(color: C.fg3, fontSize: 11)),
                const SizedBox(width: 6),
                Text(item.sortAt == null ? '' : listDate(DateTime.parse(item.sortAt!), DateTime.now()),
                    style: const TextStyle(color: C.fg3, fontSize: 11)),
              ]),
              const SizedBox(height: 2),
              Text(item.subject ?? '(без темы)',
                  style: TextStyle(color: C.fg, fontSize: 13, fontWeight: item.seen ? FontWeight.w400 : FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          if (item.hasAttachments) const Icon(Icons.attach_file, size: 14, color: C.fg3),
        ]),
      ),
    );
  }
}

/// Домен адреса в нижнем регистре или `null`, если адрес пустой или битый (нет «собаки»
/// либо после неё пусто).
///
/// Один разбор на весь раздел почты: домен нужен и для логотипа в строке, и для подписи
/// аккаунта, и две разные реализации здесь уже расходились (одна падала на адресе с двумя
/// «собаками», другая считала доменом часть строки после первой). Функция свободная, а не метод
/// состояния: от состояния она не зависит.
String? domainOfEmail(String? addr) {
  if (addr == null) return null;
  // Последняя «собака»: в local-part она допустима в кавычках, а домен идёт после последней.
  final i = addr.lastIndexOf('@');
  if (i <= 0 || i == addr.length - 1) return null;
  return addr.substring(i + 1).toLowerCase();
}

/// Подпись аккаунта в строке: обычно домен, но если на этом домене больше одного аккаунта —
/// полный адрес.
///
/// Так видно, куда пришло письмо (у пользователя бывает несколько ящиков), и при этом
/// «@gmail.com» не повторяется в каждой строке, когда ящик один.
String accountTagOf(MailListItem item, List<MailAccountRow> accounts) {
  final domain = domainOfEmail(item.accountEmail) ?? item.accountEmail;
  final same = accounts.where((a) => (domainOfEmail(a.email) ?? a.email) == domain).length > 1;
  return same ? item.accountEmail : domain;
}

/// Название папки почты для интерфейса: в заголовке ленты, в баре папок и в поиске.
///
/// Одна функция на весь раздел: подписи у папок те же, что и в баре выбора, и своя копия
/// в каждом экране означала бы, что папку переименовали в одном месте и забыли в другом.
String mailBoxLabel(String id) => switch (id) {
      'sent' => 'Исходящие',
      'trash' => 'Корзина',
      _ => 'Входящие',
    };
