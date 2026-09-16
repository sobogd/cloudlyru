/// Модели раздела «Фактуры»: то, что приложение читает и отправляет на сервер.
///
/// Раздел перенесён из отдельного сервиса iq-factura, и формы ответов у него свои — они не
/// совпадают с моделями облака (`lib/api/models.dart`), поэтому у фактур свой файл моделей,
/// а не дополнение к общему. Всё, что приходит от сервера, разбирается терпимо: денежные
/// значения Prisma отдаёт строками (`Decimal`), даты — ISO-строками, а часть полей может
/// отсутствовать (например, номер у черновика).
///
/// Модели намеренно плоские и только для чтения: приложение не редактирует их на месте,
/// а показывает; правка уходит на сервер телом запроса (см. `factura_api.dart`).
library;

/// Разбирает значение как строку: `null` остаётся `null`, число превращается в текст.
///
/// Нужна потому, что сервер отдаёт `Decimal` то строкой, то числом (`netAmount` — строка,
/// `serialYear` — число), и различать это в каждом поле было бы шумом.
String? _str(Object? v) => v == null ? null : '$v';

/// Разбирает значение как `double`. Строки и числа сервера равнозначны; мусор даёт `null`,
/// а не исключение — экран покажет прочерк вместо падения.
double? _num(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse('$v');
}

/// Разбирает значение как `DateTime`; `null` и мусор дают `null`.
DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// Счёт в списке фактур: то, что показывает экран «Фактуры», без тяжестей карточки.
///
/// Это же представление приходит из `POST /invoices/:id/duplicate` и других ручек, которые
/// возвращают строку фактуры целиком, — поэтому разбор общий с [InvoiceDetail].
class InvoiceSummary {
  const InvoiceSummary({
    required this.id,
    required this.number,
    required this.issueDate,
    required this.totalAmount,
    required this.currency,
    required this.status,
    required this.contactName,
  });

  /// Идентификатор фактуры (cuid).
  final String id;

  /// Номер вида `FACT-2026-00050`. У черновика номера нет: он выдаётся в момент отправки
  /// в AEAT, чтобы серия отправленных фактур не имела дыр.
  final String? number;

  /// Дата выставления — то, по чему список группируется по месяцам.
  final DateTime? issueDate;

  /// Сумма к оплате в валюте фактуры.
  final double totalAmount;

  /// ISO 4217, например `EUR`.
  final String currency;

  /// `DRAFT` — черновик, `SENT` — отправлена в AEAT (номер выдан, запись в цепочке есть).
  final String status;

  /// Имя контрагента из снимка фактуры (не из справочника: снимок не меняется задним числом).
  final String? contactName;

  /// Собирает счёт из строки ответа `/invoices`.
  factory InvoiceSummary.fromJson(Map<String, dynamic> json) => InvoiceSummary(
        id: '${json['id']}',
        number: _str(json['number']),
        issueDate: _date(json['issueDate']),
        totalAmount: _num(json['totalAmount']) ?? 0,
        currency: _str(json['currency']) ?? 'EUR',
        status: _str(json['status']) ?? 'DRAFT',
        contactName: json['contact'] is Map
            ? _str((json['contact'] as Map)['name'])
            : _str((json['contactSnapshot'] as Map?)?['name']),
      );
}

/// Строка фактуры: описание, количество и цена.
class InvoiceLineView {
  const InvoiceLineView({
    required this.description,
    required this.quantity,
    required this.unitPrice,
    required this.total,
  });

  final String description;
  final double quantity;
  final double unitPrice;
  final double total;

  /// Собирает строку из ответа сервера (`lines`).
  factory InvoiceLineView.fromJson(Map<String, dynamic> json) => InvoiceLineView(
        description: _str(json['description']) ?? '',
        quantity: _num(json['quantity']) ?? 1,
        unitPrice: _num(json['unitPrice']) ?? 0,
        total: _num(json['total']) ?? 0,
      );
}

/// Запись в ленте событий фактуры: что с ней происходило и когда.
///
/// Лента — способ разобраться в спорной ситуации (отправка в AEAT, ручное подтверждение
/// зависшей записи), поэтому событие хранит и служебное `payload` с сырыми ответами AEAT.
class InvoiceEventView {
  const InvoiceEventView({
    required this.type,
    required this.outcome,
    required this.summary,
    required this.createdAt,
    required this.payload,
  });

  /// Машинный тип события (`INVOICE_CREATED`, `VERIFACTU_MANUAL_CONFIRM`, …).
  final String type;

  /// `info` | `warning` | `error` — от этого зависит цвет строки в ленте.
  final String outcome;

  /// Человеческий текст события (его пишет сервер).
  final String summary;

  final DateTime? createdAt;

  /// Сырые данные события (номер, суммы, ответ AEAT) — показываются свёрнуто.
  final Map<String, dynamic>? payload;

  /// Собирает событие из строки ответа `/invoices/:id/events`.
  factory InvoiceEventView.fromJson(Map<String, dynamic> json) => InvoiceEventView(
        type: _str(json['type']) ?? '',
        outcome: _str(json['outcome']) ?? 'info',
        summary: _str(json['summary']) ?? '',
        createdAt: _date(json['createdAt']),
        payload: json['payload'] is Map ? Map<String, dynamic>.from(json['payload'] as Map) : null,
      );
}

/// Зависшая отправка в AEAT: локальная запись осталась `PENDING`, потому что ответ AEAT
/// не дошёл. Такую запись разрешает человек: подтверждает (запись у AEAT есть) или отменяет
/// (AEAT её не получил и номер можно освободить).
class VerifactuPendingView {
  const VerifactuPendingView({required this.sequenceNumber, required this.signedAt});

  /// Номер записи в цепочке компании.
  final int sequenceNumber;

  /// Момент подписи записи — по нему человек ищет её в кабинете AEAT.
  final DateTime? signedAt;

  /// Собирает сведения о зависшей записи.
  factory VerifactuPendingView.fromJson(Map<String, dynamic> json) => VerifactuPendingView(
        sequenceNumber: (_num(json['sequenceNumber']) ?? 0).toInt(),
        signedAt: _date(json['signedAt']),
      );
}

/// Подробности фактуры: то, что показывает карточка и форма правки.
///
/// Снимки контрагента и эмитента (`contactSnapshot`, `emitterSnapshot`) хранятся в самой
/// фактуре и не меняются задним числом — этим PDF остаётся тем же, даже если справочник
/// контрагентов потом поправят.
class InvoiceDetail {
  const InvoiceDetail({
    required this.id,
    required this.number,
    required this.status,
    required this.issueDate,
    required this.currency,
    required this.language,
    required this.vatRate,
    required this.irpfRate,
    required this.netAmount,
    required this.vatAmount,
    required this.irpfAmount,
    required this.totalAmount,
    required this.toPayAmount,
    required this.description,
    required this.notes,
    required this.legalNoteCode,
    required this.paid,
    required this.paymentMethod,
    required this.contactId,
    required this.bankAccountId,
    required this.contactSnapshot,
    required this.emitterSnapshot,
    required this.lines,
    required this.contact,
    required this.verifactuQrUrl,
    required this.verifactuChainTail,
    required this.verifactuPending,
    required this.pdfSha256,
  });

  final String id;
  final String? number;
  final String status;
  final DateTime? issueDate;
  final String currency;

  /// Язык фактуры (`es` | `en`) — от него зависит подпись единиц и текст-шаблон PDF.
  final String language;

  /// Ставка НДС: 21 для испанского бизнеса, 0 для клиентов вне Испании.
  final double vatRate;

  /// Удержание IRPF: 0, 7 (первые три года деятельности) или 15.
  final double irpfRate;

  final double netAmount;
  final double vatAmount;
  final double irpfAmount;

  /// Итог: база + НДС.
  final double totalAmount;

  /// Сколько клиент реально переводит: итог минус удержание IRPF.
  final double toPayAmount;

  final String? description;
  final String? notes;

  /// Код правовой оговорки (`art69`, `reverseCharge`) — печатается в PDF.
  final String? legalNoteCode;

  final bool paid;
  final String? paymentMethod;

  /// Контрагент из справочника; у фактуры по разовому контрагенту его нет.
  final String? contactId;

  /// Банковский счёт, который печатается в PDF как «DATOS DE PAGO».
  final String? bankAccountId;

  /// Снимок контрагента на момент выставления: имя, NIF и адрес, как они попали в PDF.
  final Map<String, dynamic> contactSnapshot;

  /// Снимок эмитента: реквизиты компании на момент выставления.
  final Map<String, dynamic> emitterSnapshot;

  final List<InvoiceLineView> lines;

  /// Живая карточка контрагента (если фактура на справочного контрагента).
  final ContactView? contact;

  /// Ссылка на проверку фактуры в AEAT (QR) — есть только у отправленных.
  final String? verifactuQrUrl;

  /// Последние 8 символов хеша записи в цепочке — по ним фактуру сверяют с AEAT.
  final String? verifactuChainTail;

  /// Непусто, если предыдущая отправка зависла и требует решения человека.
  final VerifactuPendingView? verifactuPending;

  /// sha256 файла PDF в бакете; меняется при каждой перерисовке.
  final String? pdfSha256;

  /// Имя контрагента для заголовков: из карточки, иначе из снимка.
  String get displayContactName =>
      contact?.name ?? _str(contactSnapshot['name']) ?? '—';

  /// NIF контрагента: из карточки, иначе из снимка.
  String? get displayContactTaxId =>
      contact?.taxId ?? _str(contactSnapshot['taxId']);

  /// Черновик можно править и удалять; отправленную фактуру — уже нет (её заморозила цепочка).
  bool get isDraft => status == 'DRAFT';

  /// Собирает подробности фактуры из ответа `/invoices/:id`.
  factory InvoiceDetail.fromJson(Map<String, dynamic> json) {
    final linesRaw = json['lines'];
    final lines = linesRaw is List
        ? linesRaw
            .whereType<Map>()
            .map((e) => InvoiceLineView.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <InvoiceLineView>[];
    return InvoiceDetail(
      id: '${json['id']}',
      number: _str(json['number']),
      status: _str(json['status']) ?? 'DRAFT',
      issueDate: _date(json['issueDate']),
      currency: _str(json['currency']) ?? 'EUR',
      language: _str(json['language']) ?? 'es',
      vatRate: _num(json['vatRate']) ?? 0,
      irpfRate: _num(json['irpfRate']) ?? 0,
      netAmount: _num(json['netAmount']) ?? 0,
      vatAmount: _num(json['vatAmount']) ?? 0,
      irpfAmount: _num(json['irpfAmount']) ?? 0,
      totalAmount: _num(json['totalAmount']) ?? 0,
      toPayAmount: _num(json['toPayAmount']) ?? 0,
      description: _str(json['description']),
      notes: _str(json['notes']),
      legalNoteCode: _str(json['legalNoteCode']),
      paid: json['paid'] == true,
      paymentMethod: _str(json['paymentMethod']),
      contactId: _str(json['contactId']),
      bankAccountId: _str(json['bankAccountId']),
      contactSnapshot:
          json['contactSnapshot'] is Map ? Map<String, dynamic>.from(json['contactSnapshot'] as Map) : const {},
      emitterSnapshot:
          json['emitterSnapshot'] is Map ? Map<String, dynamic>.from(json['emitterSnapshot'] as Map) : const {},
      lines: lines,
      contact: json['contact'] is Map
          ? ContactView.fromJson(Map<String, dynamic>.from(json['contact'] as Map))
          : null,
      verifactuQrUrl: json['verifactu'] is Map ? _str((json['verifactu'] as Map)['qrUrl']) : null,
      verifactuChainTail:
          json['verifactu'] is Map ? _str((json['verifactu'] as Map)['chainHashTail']) : null,
      verifactuPending: json['verifactuPending'] is Map
          ? VerifactuPendingView.fromJson(
              Map<String, dynamic>.from(json['verifactuPending'] as Map))
          : null,
      pdfSha256: _str(json['pdfSha256']),
    );
  }
}

/// Контрагент (клиент), которому выставляются фактуры.
class ContactView {
  const ContactView({
    required this.id,
    required this.name,
    required this.taxId,
    required this.countryCode,
    required this.currency,
    required this.email,
    required this.addressLine1,
    required this.city,
    required this.postalCode,
    required this.isEu,
  });

  final String id;
  final String name;

  /// NIF/VAT клиента — попадает в PDF и в запись AEAT.
  final String? taxId;

  /// ISO 3166-1 alpha-2; от него зависит НДС и IRPF.
  final String? countryCode;

  /// Валюта по умолчанию для фактур этому клиенту.
  final String? currency;

  final String? email;
  final String? addressLine1;
  final String? city;
  final String? postalCode;

  /// Признак intracomunitario — влияет на оговорку об обратном начислении НДС.
  final bool isEu;

  /// Собирает карточку контрагента из ответа `/contacts`.
  factory ContactView.fromJson(Map<String, dynamic> json) => ContactView(
        id: '${json['id']}',
        name: _str(json['name']) ?? '',
        taxId: _str(json['taxId']),
        countryCode: _str(json['countryCode']),
        currency: _str(json['currency']),
        email: _str(json['email']),
        addressLine1: _str(json['addressLine1']),
        city: _str(json['city']),
        postalCode: _str(json['postalCode']),
        isEu: json['isEu'] == true,
      );
}

/// Банковский счёт компании: печатается в PDF («DATOS DE PAGO») и выбирается в форме фактуры.
class BankAccountView {
  const BankAccountView({
    required this.id,
    required this.label,
    required this.bankName,
    required this.iban,
    required this.currency,
    required this.isDefault,
  });

  final String id;
  final String label;
  final String? bankName;
  final String? iban;
  final String? currency;

  /// Счёт по умолчанию — его форма подставляет новым фактурам.
  final bool isDefault;

  /// Собирает счёт из ответа `/bank-accounts`.
  factory BankAccountView.fromJson(Map<String, dynamic> json) => BankAccountView(
        id: '${json['id']}',
        label: _str(json['label']) ?? '',
        bankName: _str(json['bankName']),
        iban: _str(json['iban']),
        currency: _str(json['currency']),
        isDefault: json['isDefault'] == true,
      );
}

/// Профиль компании-эмитента: реквизиты, налоговый профиль и статус сертификата AEAT.
///
/// Из него форма фактуры берёт ставку IRPF по умолчанию и валюту, а экран настроек раздела —
/// всё остальное. Сертификат здесь только метаданными: сервер отдаёт NIF, срок и издателя,
/// сам файл и пароль наружу не выходят никогда.
class CompanyProfile {
  const CompanyProfile({
    required this.id,
    required this.name,
    required this.legalName,
    required this.taxId,
    required this.vatId,
    required this.addressLine1,
    required this.city,
    required this.postalCode,
    required this.region,
    required this.country,
    required this.defaultIrpfRate,
    required this.activityType,
    required this.baseCurrency,
    required this.invoiceNumberOffset,
    required this.certNif,
    required this.certExpiry,
  });

  final String id;
  final String name;

  /// Юридическое имя для PDF; пусто — берётся [name].
  final String? legalName;

  /// NIF/CIF эмитента.
  final String? taxId;

  /// VAT-идентификатор, если отличается от [taxId].
  final String? vatId;

  final String? addressLine1;
  final String? city;
  final String? postalCode;
  final String? region;
  final String? country;

  /// Ручное переопределение ставки IRPF; `null` — считается по типу деятельности.
  final double? defaultIrpfRate;

  /// `profesional` | `empresarial` | `modulos_empresarial` | `modulos_agricola` | `alquiler`.
  final String? activityType;

  /// Валюта по умолчанию.
  final String? baseCurrency;

  /// С какого номера продолжать нумерацию в текущем году (переезд из другого инструмента).
  final int invoiceNumberOffset;

  /// NIF в загруженном сертификате AEAT; `null` — сертификат не загружен.
  final String? certNif;

  /// Срок действия сертификата.
  final DateTime? certExpiry;

  /// Сертификат загружен — без него отправка в AEAT невозможна.
  bool get hasCert => certNif != null;

  /// Собирает профиль из ответа `/companies/me`.
  factory CompanyProfile.fromJson(Map<String, dynamic> json) => CompanyProfile(
        id: '${json['id']}',
        name: _str(json['name']) ?? '',
        legalName: _str(json['legalName']),
        taxId: _str(json['taxId']),
        vatId: _str(json['vatId']),
        addressLine1: _str(json['addressLine1']),
        city: _str(json['city']),
        postalCode: _str(json['postalCode']),
        region: _str(json['region']),
        country: _str(json['country']),
        defaultIrpfRate: _num(json['defaultIrpfRate']),
        activityType: _str(json['activityType']),
        baseCurrency: _str(json['baseCurrency']),
        invoiceNumberOffset: (_num(json['invoiceNumberOffset']) ?? 0).toInt(),
        certNif: _str(json['verifactuCertNif']),
        certExpiry: _date(json['verifactuCertExpiry']),
      );
}

/// Итог отправки фактуры в AEAT.
///
/// Ручка отвечает по-разному в двух случаях: 200 с записью цепочки и CSV при успехе и 400
/// с разбором ошибки AEAT при отказе. Оба случая — нормальный ход событий (AEAT вполне может
/// отклонить запись), поэтому клиент не бросает исключение, а возвращает этот тип: экран
/// показывает человеку, что именно ответила налоговая.
class SubmitResult {
  const SubmitResult({
    required this.ok,
    required this.invoice,
    required this.csv,
    required this.kind,
    required this.message,
    required this.rawResponse,
  });

  /// Успех: запись принята, фактура стала `SENT`.
  final bool ok;

  /// Свежая строка фактуры (перечитанная после присвоения номера и QR).
  final InvoiceDetail? invoice;

  /// CSV из кабинета AEAT — его сохраняют себе как подтверждение.
  final String? csv;

  /// Машинный вид ошибки (`aeat_rejected`, `network`, …).
  final String? kind;

  /// Текст для человека (ответ AEAT или объяснение сбоя).
  final String? message;

  /// Сырой ответ AEAT — показывается свёрнуто, чтобы можно было переслать в поддержку.
  final String? rawResponse;

  /// Итог успешной отправки.
  factory SubmitResult.success(Map<String, dynamic> json) => SubmitResult(
        ok: true,
        invoice: json['invoice'] is Map
            ? InvoiceDetail.fromJson(Map<String, dynamic>.from(json['invoice'] as Map))
            : null,
        csv: _str(json['csv']),
        kind: null,
        message: null,
        rawResponse: null,
      );

  /// Итог отказа: AEAT не принял запись или ответ не дошёл.
  factory SubmitResult.failure({
    String? kind,
    String? message,
    String? rawResponse,
  }) =>
      SubmitResult(
        ok: false,
        invoice: null,
        csv: null,
        kind: kind,
        message: message,
        rawResponse: rawResponse,
      );
}

/// Значение одной касильи (клетки) декларации.
///
/// Подписи приходят в двух языках: испанская — та, что напечатана в форме AEAT, английская —
/// для тех, кому удобнее читать по-английски. Показываем испанскую как основную: именно её
/// человек видит в кабинете налоговой, — а английскую оставляем подсказкой.
class DeclarationBox {
  const DeclarationBox({
    required this.code,
    required this.labelEs,
    required this.labelEn,
    required this.value,
  });

  /// Номер клетки в форме (например `07`).
  final String code;
  final String labelEs;
  final String labelEn;
  final double value;

  /// Собирает касилью из ответа сервера.
  factory DeclarationBox.fromJson(Map<String, dynamic> json) => DeclarationBox(
        code: '${json['code']}',
        labelEs: '${json['labelEs'] ?? ''}',
        labelEn: '${json['labelEn'] ?? ''}',
        value: _num(json['value']) ?? 0,
      );
}

/// Замечание движка деклараций: что проверить перед подачей.
///
/// `severity` = `warning` — на что обратить внимание (например, перенос вычета на другой
/// период оформляется вручную в форме AEAT), `error` — так подавать нельзя.
class DeclarationIssue {
  const DeclarationIssue({
    required this.code,
    required this.severity,
    required this.messageEs,
    required this.messageEn,
  });

  final String code;
  final String severity;
  final String messageEs;
  final String messageEn;

  /// Тревожное замечание — ошибка, а не предупреждение.
  bool get isError => severity == 'error';

  /// Собирает замечание из ответа сервера.
  factory DeclarationIssue.fromJson(Map<String, dynamic> json) => DeclarationIssue(
        code: '${json['code']}',
        severity: '${json['severity'] ?? 'warning'}',
        messageEs: '${json['messageEs'] ?? ''}',
        messageEn: '${json['messageEn'] ?? ''}',
      );
}

/// Одна операция в modelos 349 — поставка клиенту из другой страны ЕС.
class DeclarationOperation {
  const DeclarationOperation({
    required this.taxId,
    required this.country,
    required this.name,
    required this.clave,
    required this.base,
  });

  /// VAT-номер контрагента.
  final String taxId;

  /// ISO-код страны контрагента.
  final String country;

  final String name;

  /// `clave` из формы 349: `S` — поставки услуг, `E` — поставки товаров и т. д.
  final String clave;

  /// База операции.
  final double base;

  /// Собирает операцию из ответа сервера.
  factory DeclarationOperation.fromJson(Map<String, dynamic> json) => DeclarationOperation(
        taxId: '${json['taxId'] ?? ''}',
        country: '${json['country'] ?? ''}',
        name: '${json['name'] ?? ''}',
        clave: '${json['clave'] ?? ''}',
        base: _num(json['base']) ?? 0,
      );
}

/// Одна модель (форма) декларации: 303, 130 или 349.
///
/// [required] отвечает на вопрос «нужно ли её вообще подавать в этом квартале», [reason] —
/// почему движок так решил, [deadline] — срок подачи. Касильи и итоговые суммы заполнены
/// только у тех моделей, к которым они относятся: у 349 вместо них список операций.
class DeclarationModel {
  const DeclarationModel({
    required this.model,
    required this.required,
    required this.reason,
    required this.deadline,
    required this.amounts,
    required this.boxes,
    required this.operations,
  });

  /// Номер формы (`303`, `130`, `349`).
  final String model;

  /// Обязательна ли подача в этом квартале.
  final bool required;

  /// Объяснение движка (по-испански: так человек ищет норму).
  final String reason;

  /// Срок подачи `YYYY-MM-DD`.
  final String? deadline;

  /// Итоговые суммы модели: подписи уже человеческие (`IVA devengado`, `A ingresar`, …).
  /// Порядок сохранён тем, в котором движок их считал.
  final List<({String label, double value})> amounts;

  /// Клетки формы с их номерами.
  final List<DeclarationBox> boxes;

  /// Операции для 349; у остальных моделей пусто.
  final List<DeclarationOperation> operations;

  /// Собирает модель из её ветки ответа.
  ///
  /// [amountKeys] — какие поля этой модели считать итоговыми суммами и как их подписать:
  /// у каждой формы свой набор, и брать «все числа подряд» нельзя (в ответе есть и служебные,
  /// вроде `operadores`).
  factory DeclarationModel.fromJson(
    String model,
    Map<String, dynamic> json,
    List<({String key, String label})> amountKeys,
  ) {
    return DeclarationModel(
      model: model,
      required: json['required'] == true,
      reason: '${json['reason'] ?? ''}',
      deadline: json['deadline'] == null ? null : '${json['deadline']}',
      amounts: [
        for (final a in amountKeys)
          if (json[a.key] != null) (label: a.label, value: _num(json[a.key]) ?? 0),
      ],
      boxes: (json['casillas'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => DeclarationBox.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      operations: (json['operaciones'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => DeclarationOperation.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

/// Квартальный расчёт целиком: что подавать и с какими числами.
///
/// Это помощник, а не канал подачи: значения переносятся в форму AEAT руками (движок прямо
/// пишет об этом в замечаниях), а поданное потом фиксируется в «Поданных декларациях».
class DeclarationQuarter {
  const DeclarationQuarter({
    required this.year,
    required this.quarter,
    required this.label,
    required this.deadline,
    required this.invoices,
    required this.expenses,
    required this.activityType,
    required this.estimacionDirecta,
    required this.issues,
    required this.models,
  });

  final int year;
  final int quarter;

  /// Подпись периода (`Q3 2026`).
  final String label;

  /// Самый ранний срок подачи среди моделей квартала.
  final String? deadline;

  /// Сколько фактур попало в квартал.
  final int invoices;

  /// Сколько расходов попало в квартал.
  final int expenses;

  /// Тип деятельности компании — от него зависит, нужна ли 130 и какая ставка IRPF.
  final String activityType;

  /// Прямая оценка (estimación directa) — режим, при котором подаётся 130.
  final bool estimacionDirecta;

  final List<DeclarationIssue> issues;

  /// Модели в порядке 303 → 130 → 349.
  final List<DeclarationModel> models;

  /// Собирает квартальный расчёт из ответа `/declarations`.
  factory DeclarationQuarter.fromJson(Map<String, dynamic> json) {
    final period = json['period'] is Map ? Map<String, dynamic>.from(json['period'] as Map) : const <String, dynamic>{};
    final profile = json['profile'] is Map ? Map<String, dynamic>.from(json['profile'] as Map) : const <String, dynamic>{};
    final counts = json['counts'] is Map ? Map<String, dynamic>.from(json['counts'] as Map) : const <String, dynamic>{};

    // Итоговые поля каждой модели: берём их поимённо, чтобы в блок не попали служебные числа.
    final models = <DeclarationModel>[
      if (json['modelo303'] is Map)
        DeclarationModel.fromJson(
          '303',
          Map<String, dynamic>.from(json['modelo303'] as Map),
          const [
            (key: 'ivaDevengado', label: 'IVA devengado'),
            (key: 'ivaDeducible', label: 'IVA deducible'),
            (key: 'resultado', label: 'Resultado'),
          ],
        ),
      if (json['modelo130'] is Map)
        DeclarationModel.fromJson(
          '130',
          Map<String, dynamic>.from(json['modelo130'] as Map),
          const [
            (key: 'ingresosTrim', label: 'Ingresos del trimestre'),
            (key: 'gastosTrim', label: 'Gastos del trimestre'),
            (key: 'rendimientoTrim', label: 'Rendimiento del trimestre'),
            (key: 'ingresosAcum', label: 'Ingresos acumulados'),
            (key: 'gastosAcum', label: 'Gastos acumulados'),
            (key: 'rendimiento', label: 'Rendimiento acumulado'),
            (key: 'resultado', label: 'Resultado'),
            (key: 'aIngresar', label: 'A ingresar'),
          ],
        ),
      if (json['modelo349'] is Map)
        DeclarationModel.fromJson(
          '349',
          Map<String, dynamic>.from(json['modelo349'] as Map),
          const [
            (key: 'operadores', label: 'Operadores'),
            (key: 'importeTotal', label: 'Importe total'),
          ],
        ),
    ];

    final deadlines = <String>[
      for (final m in models)
        if (m.required && m.deadline != null) m.deadline!,
    ]..sort();

    return DeclarationQuarter(
      year: (_num(period['year']) ?? 0).toInt(),
      quarter: (_num(period['quarter']) ?? 0).toInt(),
      label: '${period['label'] ?? ''}',
      deadline: deadlines.isEmpty ? null : deadlines.first,
      invoices: (_num(counts['invoices']) ?? 0).toInt(),
      expenses: (_num(counts['expenses']) ?? 0).toInt(),
      activityType: '${profile['activityType'] ?? ''}',
      estimacionDirecta: profile['estimacionDirecta'] == true,
      issues: (json['issues'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => DeclarationIssue.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      models: models,
    );
  }
}

/// Расход (factura recibida): документ поставщика, который уменьшает базу IRPF и даёт вычет НДС.
///
/// Номер и VeriFactu к расходам не применяются — это документы поставщика, их только
/// агрегируют для деклараций. Все денежные поля сервер считает сам из базы, ставки НДС и IRPF,
/// поэтому в форме достаточно базы и ставок.
class ExpenseView {
  const ExpenseView({
    required this.id,
    required this.supplierName,
    required this.supplierTaxId,
    required this.supplierCountryCode,
    required this.nature,
    required this.kind,
    required this.issueDate,
    required this.category,
    required this.description,
    required this.notes,
    required this.currency,
    required this.netAmount,
    required this.vatRate,
    required this.irpfRate,
    required this.totalAmount,
    required this.deductibleVatPct,
    required this.deductibleForIrpf,
    required this.reverseCharge,
    required this.hasDocument,
    required this.fileName,
  });

  final String id;

  /// Имя поставщика — единственное обязательное поле расхода.
  final String supplierName;

  final String? supplierTaxId;
  final String? supplierCountryCode;

  /// `goods` | `service` — от этого зависит clave в форме 349.
  final String? nature;

  /// `invoice` — обычный счёт; `recurring_no_invoice` — взнос RETA/соцстраха без счёта.
  final String? kind;

  final DateTime? issueDate;
  final String? category;
  final String? description;
  final String? notes;
  final String currency;
  final double netAmount;

  /// Ставка НДС (`0`, `4`, `10`, `21`).
  final double vatRate;

  /// Удержание IRPF, обычно 0.
  final double irpfRate;

  /// Итог с НДС.
  final double totalAmount;

  /// Какую долю НДС можно принять к вычету, % (топливо и подобное бывает 50%).
  final double deductibleVatPct;

  /// Учитывать ли расход в базе IRPF (штрафы и часть представительских — нет).
  final bool deductibleForIrpf;

  /// Обратное начисление НДС: покупка внутри ЕС, НДС начисляет получатель.
  final bool reverseCharge;

  /// К расходу приложен документ (скан или PDF) — по нему его открывают на просмотр.
  final bool hasDocument;

  final String? fileName;

  /// Собирает расход из ответа `/expenses`.
  factory ExpenseView.fromJson(Map<String, dynamic> json) => ExpenseView(
        id: '${json['id']}',
        supplierName: _str(json['supplierName']) ?? '',
        supplierTaxId: _str(json['supplierTaxId']),
        supplierCountryCode: _str(json['supplierCountryCode']),
        nature: _str(json['nature']),
        kind: _str(json['kind']),
        issueDate: _date(json['issueDate']),
        category: _str(json['category']),
        description: _str(json['description']),
        notes: _str(json['notes']),
        currency: _str(json['currency']) ?? 'EUR',
        netAmount: _num(json['netAmount']) ?? 0,
        vatRate: _num(json['vatRate']) ?? 0,
        irpfRate: _num(json['irpfRate']) ?? 0,
        totalAmount: _num(json['totalAmount']) ?? 0,
        deductibleVatPct: _num(json['deductibleVatPct']) ?? 100,
        deductibleForIrpf: json['deductibleForIrpf'] != false,
        reverseCharge: json['reverseCharge'] == true,
        hasDocument: _str(json['fileS3Key']) != null,
        fileName: _str(json['fileName']),
      );
}

/// Поля, которые распознал сервер по скану расхода.
///
/// Это черновик заполнения, а не готовый расход: человек проверяет то, что прочитала модель,
/// и сохраняет уже своими руками (см. `expense_form_screen.dart`).
class ParsedExpenseDraft {
  const ParsedExpenseDraft({
    required this.supplierName,
    required this.supplierTaxId,
    required this.supplierCountryCode,
    required this.issueDate,
    required this.currency,
    required this.netAmount,
    required this.vatRate,
    required this.irpfRate,
    required this.reverseCharge,
    required this.nature,
    required this.kind,
    required this.description,
  });

  final String supplierName;
  final String supplierTaxId;
  final String supplierCountryCode;
  final String issueDate;
  final String currency;
  final double netAmount;
  final double vatRate;
  final double irpfRate;
  final bool reverseCharge;
  final String nature;
  final String kind;
  final String description;

  /// Собирает распознанные поля; отсутствующие значения остаются пустыми, а не падают.
  factory ParsedExpenseDraft.fromJson(Map<String, dynamic> json) => ParsedExpenseDraft(
        supplierName: _str(json['supplierName']) ?? '',
        supplierTaxId: _str(json['supplierTaxId']) ?? '',
        supplierCountryCode: _str(json['supplierCountryCode']) ?? '',
        issueDate: _str(json['issueDate']) ?? '',
        currency: _str(json['currency']) ?? '',
        netAmount: _num(json['netAmount']) ?? 0,
        vatRate: _num(json['vatRate']) ?? 0,
        irpfRate: _num(json['irpfRate']) ?? 0,
        reverseCharge: json['reverseCharge'] == true,
        nature: _str(json['nature']) ?? 'service',
        kind: _str(json['kind']) ?? 'invoice',
        description: _str(json['description']) ?? '',
      );
}
