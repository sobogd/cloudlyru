/// REST-клиент раздела «Фактуры» — второй (после облачного) источник HTTP-запросов приложения.
///
/// Почему отдельный класс, а не методы в [CloudlyApi]: у раздела свои модели и свои ~15 ручек,
/// а облачный клиент уже 1500 строк про файлы, почту и синхронизацию. Общими остаются ровно две
/// вещи, и обе берутся из [CloudlyApi], а не копируются:
///  - адрес сервера и база `/api/v1` — из [CloudlyApi.baseUrl];
///  - Cookie веб-сессии — из [CloudlyApi.authHeaders] (замыканием, чтобы клиент всегда видел
///    текущую сессию, а не ту, что была в момент создания объекта).
///
/// Ручки раздела живут на том же сервере и под тем же входом: отдельного входа у фактур нет,
/// поэтому здесь нет ни логина, ни хранения сессии.
library;

import 'package:dio/dio.dart';

import '../api/cloudly_api.dart';
import 'factura_models.dart';

/// Ошибка обращения к фактурному API.
///
/// Отдельный тип, а не [ApiException] облака, нужен ради одного случая: ручка отправки в AEAT
/// отвечает 400 с разобранным ответом налоговой, и это не «ошибка запроса», а рабочий результат
/// (см. [FacturaApi.submit]). Всё остальное — обычные сбои с кодом и текстом.
class FacturaApiException implements Exception {
  const FacturaApiException(this.status, this.message);

  /// Код HTTP; 0 — ответа не было вовсе (нет связи, таймаут).
  final int status;

  /// Текст для человека.
  final String message;

  /// Повтор запроса имеет смысл: ответа не было, таймаут, 429 или 5xx.
  bool get retryable => status == 0 || status == 408 || status == 429 || status >= 500;

  @override
  String toString() => message;
}

/// Тело фактуры при создании и правке черновика.
///
/// Одна и та же форма уходит в `POST /invoices` и `PATCH /invoices/:id` (сервер принимает их
/// одним DTO) — так правка черновика считается по тем же правилам, что и создание.
class InvoicedraftPayload {
  const InvoicedraftPayload({
    required this.contactId,
    this.contact,
    required this.lineItems,
    required this.vatRate,
    required this.irpfRate,
    required this.currency,
    required this.issueDate,
    required this.description,
    required this.notes,
    required this.bankAccountId,
  });

  /// Контрагент из справочника; `null` — фактура на разового клиента (тогда нужен [contact]).
  final String? contactId;

  /// Разовый контрагент (имя, NIF, адрес), когда его нет в справочнике. Нужен и при правке
  /// черновика, выставленного на такого клиента: сохранить его можно только повторной отправкой
  /// тех же данных, потому что отдельной карточки у разового контрагента не существует.
  final Map<String, dynamic>? contact;

  /// Строки фактуры: описание и сумма; количество сервер ставит 1.
  final List<({String description, double amount})> lineItems;

  /// 21 — испанский бизнес, 0 — клиент вне Испании.
  final int vatRate;

  /// 0, 7 или 15; сервер сам подставит значение по профилю, если не передавать.
  final int? irpfRate;

  final String currency;

  /// Дата выставления `YYYY-MM-DD`.
  final String issueDate;

  final String? description;
  final String? notes;
  final String? bankAccountId;

  /// Тело запроса для сервера. Пустые строки не отправляем: сервер различает «поле не пришло»
  /// и «поле пустое», и пустая оговорка вместо отсутствующей сломала бы PDF.
  Map<String, dynamic> toJson() => {
        if (contactId != null) 'contactId': contactId,
        if (contact != null) 'contact': contact,
        'lineItems': [
          for (final it in lineItems) {'description': it.description, 'amount': it.amount},
        ],
        'vatRate': vatRate,
        if (irpfRate != null) 'irpfRate': irpfRate,
        'currency': currency,
        'issueDate': issueDate,
        if ((description ?? '').isNotEmpty) 'description': description,
        if ((notes ?? '').isNotEmpty) 'notes': notes,
        if (bankAccountId != null) 'bankAccountId': bankAccountId,
      };
}

/// Клиент фактурного API.
class FacturaApi {
  /// Собирает клиент поверх уже существующего облачного: адрес и сессия берутся у него.
  ///
  /// [cloudly] передаётся целиком, а не строкой адреса: при смене сервера приложение
  /// пересоздаёт облачный клиент, и раздел фактур обязан ходить на новый адрес с новой сессией.
  FacturaApi(this.cloudly) {
    _http = Dio(BaseOptions(
      baseUrl: cloudly.baseUrl,
      connectTimeout: const Duration(seconds: 20),
      // Ответ AEAT на отправку приходит не мгновенно (сервер ждёт SOAP-ответ налоговой),
      // поэтому на чтение даём заметно больше обычного.
      receiveTimeout: const Duration(seconds: 90),
      sendTimeout: const Duration(seconds: 120),
    ));
    _http.interceptors.add(InterceptorsWrapper(
      onRequest: (o, h) {
        o.headers.addAll(cloudly.authHeaders);
        o.headers['Accept'] = 'application/json';
        h.next(o);
      },
    ));
  }

  /// Облачный клиент: адрес, база `/api/v1` и заголовки сессии.
  final CloudlyApi cloudly;

  /// HTTP-клиент раздела: относительные пути от `/api/v1`, Cookie — из облачного клиента.
  late final Dio _http;

  /// Один запрос: тело ответа как есть (`Map`, `List` или примитив).
  ///
  /// Разделение на [_json] и [_list] нужно потому, что ручки раздела отвечают по-разному:
  /// `/invoices` и `/contacts/parse` — объектом, а `/contacts`, `/bank-accounts`, `/expenses`,
  /// `/filed-declarations` — голым массивом (так исторически и осталось при переносе). Раньше
  /// клиент ждал объект везде и молча получал пустые списки там, где сервер отдал массив.
  Future<Object?> _raw(
    String method,
    String path, {
    Object? body,
  }) async {
    try {
      final res = await _http.request<Object?>(
        path,
        data: body,
        options: Options(
          method: method,
          // 4xx разбираем сами: тело ошибки сервер отдаёт в своём формате
          // ({message, code}), а 5xx — уже настоящий сбой.
          validateStatus: (code) => code != null && code < 500,
        ),
      );
      final data = res.data;
      if (res.statusCode != null && res.statusCode! >= 400) {
        final map = data is Map ? Map<String, dynamic>.from(data) : const <String, dynamic>{};
        throw FacturaApiException(res.statusCode!, _messageOf(map) ?? 'Ошибка ${res.statusCode}');
      }
      return data;
    } on DioException catch (e) {
      throw FacturaApiException(e.response?.statusCode ?? 0, _dioMessage(e));
    }
  }

  /// Запрос, ответ которого — JSON-объект. Массив или пустое тело дают пустой объект.
  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Object? body,
  }) async {
    final data = await _raw(method, path, body: body);
    return data is Map ? Map<String, dynamic>.from(data) : const <String, dynamic>{};
  }

  /// Запрос, ответ которого — JSON-массив объектов (списки раздела отвечают именно так).
  Future<List<Map<String, dynamic>>> _list(String path) async {
    final data = await _raw('GET', path);
    return data is List
        ? data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : const [];
  }

  /// Строка для человека из тела ошибки сервера (облако отвечает `{message, code}`).
  String? _messageOf(Map<String, dynamic> body) {
    final m = body['message'];
    if (m is String && m.isNotEmpty) return m;
    if (m is List && m.isNotEmpty) return m.join('; ');
    final err = body['error'];
    if (err is Map && err['message'] is String) return err['message'] as String;
    return null;
  }

  /// Короткий текст сетевого сбоя.
  String _dioMessage(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Сервер не ответил вовремя';
      case DioExceptionType.connectionError:
        return 'Нет связи с сервером';
      default:
        return e.message ?? 'Не удалось выполнить запрос';
    }
  }

  /// Список фактур, свежие сверху.
  ///
  /// [year] — фильтр по году серии (номер выдаётся в год выставления); сервер отдаёт страницами
  /// не более 500 строк, поэтому [limit] ограничен разумным «последние несколько сотен».
  Future<({List<InvoiceSummary> rows, int total})> listInvoices({
    int? year,
    int limit = 200,
    int offset = 0,
  }) async {
    final query = 'limit=$limit&offset=$offset${year == null ? '' : '&year=$year'}';
    final json = await _json('GET', '/invoices?$query');
    final rows = (json['rows'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => InvoiceSummary.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return (rows: rows, total: (json['total'] as num?)?.toInt() ?? rows.length);
  }

  /// Одна фактура со строками, контрагентом и статусом цепочки VeriFactu.
  Future<InvoiceDetail> getInvoice(String id) async {
    final json = await _json('GET', '/invoices/$id');
    return InvoiceDetail.fromJson(json);
  }

  /// Лента событий фактуры (от старых к новым).
  Future<List<InvoiceEventView>> getEvents(String id) async {
    final json = await _json('GET', '/invoices/$id/events');
    return (json['rows'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => InvoiceEventView.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Создаёт черновик. Номер при этом не выдаётся: он появится при отправке в AEAT,
  /// чтобы серия отправленных фактур не имела пропусков.
  Future<InvoiceDetail> createDraft(InvoicedraftPayload payload) async {
    final json = await _json('POST', '/invoices', body: payload.toJson());
    return InvoiceDetail.fromJson(json);
  }

  /// Правит черновик. Отправленную фактуру сервер править не даст — её заморозила цепочка.
  Future<InvoiceDetail> updateDraft(String id, InvoicedraftPayload payload) async {
    final json = await _json('PATCH', '/invoices/$id', body: payload.toJson());
    return InvoiceDetail.fromJson(json);
  }

  /// Удаляет фактуру вместе с её PDF.
  Future<void> deleteInvoice(String id) => _json('DELETE', '/invoices/$id');

  /// Делает копию фактуры новым черновиком (дата — сегодня, номер ещё не выдан).
  Future<InvoiceDetail> duplicateInvoice(String id) async {
    final json = await _json('POST', '/invoices/$id/duplicate');
    return InvoiceDetail.fromJson(json);
  }

  /// Отправляет фактуру в AEAT.
  ///
  /// Оба исхода — нормальный результат: 200 означает, что запись принята и фактура стала `SENT`,
  /// 400 — что налоговая отказала (или ответ не дошёл). Исключение бросается только на сбоях
  /// связи: тогда неизвестно, дошёл ли запрос, и это единственный случай, когда повторять
  /// отправку надо осознанно.
  Future<SubmitResult> submit(String id, {int? irpfRate}) async {
    try {
      final res = await _http.post<Object?>(
        '/invoices/$id/submit',
        data: {'irpfRate': ?irpfRate},
        options: Options(
          receiveTimeout: const Duration(seconds: 120),
          validateStatus: (code) => code != null && code < 500,
        ),
      );
      final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : const <String, dynamic>{};
      final code = res.statusCode ?? 0;
      if (code >= 200 && code < 300) return SubmitResult.success(data);
      final err = data['error'] is Map ? Map<String, dynamic>.from(data['error'] as Map) : const <String, dynamic>{};
      return SubmitResult.failure(
        kind: err['kind']?.toString(),
        message: (err['message'] ?? _messageOf(data))?.toString(),
        rawResponse: err['rawResponse']?.toString(),
      );
    } on DioException catch (e) {
      throw FacturaApiException(e.response?.statusCode ?? 0, _dioMessage(e));
    }
  }

  /// Подтверждает зависшую запись: человек проверил кабинет AEAT и запись там есть.
  Future<void> confirmPending(String id, {String? csv}) =>
      _json('POST', '/invoices/$id/verifactu/confirm', body: {'csv': ?csv});

  /// Отменяет зависшую запись: AEAT её не получил, номер освобождается, фактура снова черновик.
  Future<void> cancelPending(String id) => _json('POST', '/invoices/$id/verifactu/cancel');

  /// Список расходов, свежие сверху; [year] — фильтр по году документа.
  Future<List<ExpenseView>> listExpenses({int? year}) async {
    final rows = await _list('/expenses${year == null ? '' : '?year=$year'}');
    return rows.map(ExpenseView.fromJson).toList();
  }

  /// Создаёт расход. Все суммы сервер пересчитывает сам из базы и ставок.
  Future<void> createExpense(Map<String, dynamic> body) => _json('POST', '/expenses', body: body);

  /// Правит расход.
  Future<void> updateExpense(String id, Map<String, dynamic> body) =>
      _json('PATCH', '/expenses/$id', body: body);

  /// Удаляет расход вместе с приложенным документом.
  Future<void> deleteExpense(String id) => _json('DELETE', '/expenses/$id');

  /// Загружает документ расхода (скан или PDF) в S3.
  ///
  /// [parse] включает распознавание: сервер прогоняет документ через Gemini и возвращает
  /// заполненные поля, чтобы человек их только проверил. Ответ несёт ключ в S3 — его и надо
  /// сохранить в расходе, поэтому загрузка идёт до сохранения формы.
  Future<({String key, String mime, String? fileName, ParsedExpenseDraft? parsed})> uploadExpenseDoc({
    required String base64,
    required String mimeType,
    String? fileName,
    bool parse = true,
  }) async {
    final json = await _json('POST', '/expenses/upload', body: {
      'data': base64,
      'mimeType': mimeType,
      'fileName': ?fileName,
      'parse': parse,
    });
    return (
      key: '${json['fileS3Key']}',
      mime: '${json['fileMime']}',
      fileName: json['fileName'] == null ? null : '${json['fileName']}',
      parsed: json['parsed'] is Map
          ? ParsedExpenseDraft.fromJson(Map<String, dynamic>.from(json['parsed'] as Map))
          : null,
    );
  }

  /// Прямая ссылка на документ расхода (закрыта авторизацией, как и PDF фактуры).
  String expenseFileUrl(String id) => '${cloudly.baseUrl}/expenses/$id/file';

  /// Сервер считает его заново на каждый запрос: цифры берутся из фактур и расходов квартала,
  /// поэтому кэшировать ответ нельзя — после любой правки фактуры расчёт меняется.
  Future<DeclarationQuarter> getDeclarations({required int year, required int quarter}) async {
    final json = await _json('GET', '/declarations?year=$year&quarter=$quarter');
    return DeclarationQuarter.fromJson(json);
  }

  /// Справочник контрагентов (без архивных — их отсекает сервер).
  Future<List<ContactView>> listContacts() async {
    final rows = await _list('/contacts');
    return rows.map(ContactView.fromJson).toList();
  }

  /// Банковские счета компании.
  Future<List<BankAccountView>> listBankAccounts() async {
    final rows = await _list('/bank-accounts');
    return rows.map(BankAccountView.fromJson).toList();
  }

  /// Профиль компании-эмитента (в том числе метаданные сертификата AEAT).
  Future<CompanyProfile> getCompany() async {
    final json = await _json('GET', '/companies/me');
    return CompanyProfile.fromJson(json);
  }

  /// Прямая ссылка на PDF фактуры: ручка отвечает редиректом на presigned-ссылку S3.
  ///
  /// Ссылка закрыта авторизацией, поэтому открывать её нужно вместе с [CloudlyApi.authHeaders]
  /// (это делает `downloadAndOpen` из `lib/util/download.dart`).
  String pdfUrl(String id) => '${cloudly.baseUrl}/invoices/$id/pdf';
}
