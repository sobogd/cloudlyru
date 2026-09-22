import { Body, Controller, Delete, Get, Headers, Logger, Param, Post, Query, Req, Res, UseGuards } from '@nestjs/common';
import type { Request, Response } from 'express';
import { MailAccountsService } from './mail-accounts.service';
import { MailFeedService } from './mail-feed.service';
import { MailSearchService } from './mail-search.service';
import { MailSyncService } from './mail-sync.service';
import { env } from '../config/env';
import { MailFaviconService } from './mail-favicon.service';
import { MailImageService } from './mail-image.service';
import { MailIngestService } from './mail-ingest.service';
import { MailSendService } from './mail-send.service';
import { MailTranslateService } from './mail-translate.service';
import { S3Service } from '../s3/s3.service';
import { sendObjectOr404 } from '../common/http-object';
import { CurrentUser, Public, RateLimit, RequestUser, SessionOnly } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { badRequest } from '../common/errors';
import { secretEquals } from './mail-crypto';
import { envelopeRecipient } from './mail-parse';

/**
 * Потолок размера принимаемого письма.
 *
 * Выше почтовых пределов отправителей намеренно: Gmail не даёт отправить больше 25 МБ, но в .eml
 * те же вложения лежат в base64 и весят примерно на треть больше, плюс заголовки и границы MIME.
 * Это не «рабочий размер письма», а предохранитель против чтения бесконечного потока в память
 * (у Postfix свой message_size_limit, а у nginx — client_max_body_size).
 */
const MAX_INBOUND_BYTES = 64 * 1024 * 1024;

/**
 * Типы, которые можно отдавать как картинку логотипа. Только растровые: SVG — это документ,
 * он умеет исполнять скрипт, и, отданный с нашего origin, получил бы доступ к сессионной куке.
 */
const FAVICON_MIME = new Set([
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/bmp',
  'image/x-icon',
  'image/vnd.microsoft.icon',
]);

/**
 * Ручки раздела «Почта».
 *
 * Аккаунты заведены один раз на сервере и из приложения не редактируются: тут только чтение
 * списка, запуск проверки и работа с письмами. Управление аккаунтами (пароль приложения
 * принимается только на сервере при первичной настройке) закрыто намеренно.
 *
 * Весь раздел, кроме приёма письма от Postfix, помечен `@SessionOnly`: почта — это личная
 * переписка, а device-токен (WebDAV, синхронизация) выпускается со scope `files:rw` и без этой
 * пометки читал бы её целиком — включая `.eml` и безвозвратное удаление писем. Flutter-клиент
 * ходит cookie-сессией (`flutter/lib/api/cloudly_api.dart`), для него это ничего не меняет.
 *
 * Статические пути объявлены до параметрических: иначе `messages` уехало бы в `:id`.
 */
@Controller('mail')
export class MailController {
  private readonly logger = new Logger(MailController.name);

  constructor(
    private readonly accounts: MailAccountsService,
    private readonly feed: MailFeedService,
    private readonly search: MailSearchService,
    private readonly sync: MailSyncService,
    private readonly sender: MailSendService,
    private readonly ingestService: MailIngestService,
    private readonly faviconService: MailFaviconService,
    private readonly imageService: MailImageService,
    private readonly translator: MailTranslateService,
    private readonly s3: S3Service,
  ) {}

  // ===== Аккаунты (только чтение) =====

  /** Список аккаунтов со статусом синхронизации и числом писем. Паролей тут нет и быть не может. */
  @Get('accounts')
  @SessionOnly()
  listAccounts(@CurrentUser() user: RequestUser) {
    return this.accounts.list(user.id);
  }

  /** Забрать почту сейчас, не дожидаясь расписания. Проход асинхронный: ответ сразу. */
  @Post('sync')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(30, 60_000)
  async syncNow(@CurrentUser() user: RequestUser) {
    // Проходы не пересекаются и уже идущий не дублируется — сервис сам скажет, что пропустил.
    // Отсюда не видно, принят проход или пропущен: `runPass` возвращает void, а свой флаг
    // занятости держит приватным. Поэтому ответ — «запрос принят», а не «проход пошёл»;
    // чтобы отвечать точнее, `MailSyncService.runPass` должен возвращать «принят/пропущен»
    // (правка в его файле).
    void user;
    // Отказ сервиса (например, БД недоступна на первом же запросе) не должен ронять процесс:
    // без обработчика необработанный reject в Node ≥20 завершает весь API вместе с загрузками.
    void this.sync.runPass('вручную из интерфейса').catch((e: Error) => {
      this.logger.warn(`проход по почте не запустился: ${e.message}`);
    });
    return { ok: true, started: true };
  }

  /** Состояние раздела: сколько непрочитанных и есть ли аккаунты с ошибкой. */
  @Get('status')
  @SessionOnly()
  async status(@CurrentUser() user: RequestUser) {
    const [unread, accounts] = await Promise.all([this.feed.unread(user.id), this.accounts.list(user.id)]);
    return {
      unread,
      accounts: accounts.map((a) => ({
        id: a.id,
        email: a.email,
        enabled: a.enabled,
        status: a.status,
        statusError: a.statusError,
        lastSyncAt: a.lastSyncAt,
      })),
    };
  }

  // ===== Приём от своего сервера =====

  /**
   * Письмо от нашего Postfix (pipe → сюда).
   *
   * Ручка без сессии: её дёргает не человек, а почтовый сервер на этой же машине.
   * Защита — токен из MAIL_INBOUND_TOKEN и запрет этого пути в nginx: снаружи он
   * недостижим, изнутри требует токен. Тело — само письмо (RFC822), целиком.
   *
   * Коды ответов выбраны по смыслу для Postfix: 200 — принято, 503 — «временно не можем»
   * (письмо подержится в очереди и повторится), 400 — письмо не разобрать.
   */
  @Post('inbound')
  @Public()
  async inbound(
    @Query('to') to: string,
    @Headers('x-mail-inbound-token') token: string,
    @Req() req: Request,
    @Res() res: Response,
  ): Promise<void> {
    const expected = env.MAIL_INBOUND_TOKEN;
    // Дублированный заголовок Express отдаёт массивом, а `Buffer.from(массив)` бросает
    // TypeError — то есть 500 в лог Postfix-обвязки, где 5xx значит «повторить позже».
    // Значение всё равно не совпало бы с токеном, поэтому достаточно свести его к строке.
    const header = typeof token === 'string' ? token : '';
    if (!expected || !secretEquals(header, expected)) {
      res.status(403).json({ message: 'inbound is not configured or token is wrong' });
      return;
    }
    const chunks: Buffer[] = [];
    let total = 0;
    for await (const chunk of req) {
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      total += buf.length;
      if (total > MAX_INBOUND_BYTES) {
        res.status(413).json({ message: 'message too large' });
        return;
      }
      chunks.push(buf);
    }
    const source = Buffer.concat(chunks);
    if (!source.length) {
      res.status(400).json({ message: 'empty message' });
      return;
    }
    // Получателя берём из самого письма (`Delivered-To`/`X-Original-To` от нашего Postfix), а не
    // из query-строки: в адресе из URL плюс декодируется в пробел, и письмо на `user+tag@domain`
    // не находило бы свой аккаунт (ответ 503 → ретраи → bounce). Query остаётся запасным
    // вариантом, если заголовков нет.
    const recipient = envelopeRecipient(source) ?? to;
    let result = await this.ingestService.ingestInbound(recipient, source);
    if (result === 'unknown-account') {
      // Plus-адресация: `user+tag@domain` доставляется аккаунту `user@domain`.
      const base = stripPlusTag(recipient);
      if (base) result = await this.ingestService.ingestInbound(base, source);
    }
    if (result === 'unknown-account') {
      // Не 404: аккаунт могут завести на сервере позже, и тогда письмо доедет повторной доставкой.
      res.status(503).json({ message: `no mail account for ${recipient}` });
      return;
    }
    res.status(200).json({ ok: true, result });
  }

  // ===== Отправка =====

  /**
   * Отправить письмо. Только веб-сессия: отправка от имени владельца — не то, что должен
   * уметь токен устройства (WebDAV, клиент синхронизации).
   */
  @Post('send')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(60, 60_000)
  send(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    return this.sender.send(user.id, {
      accountId: String(body.accountId ?? ''),
      to: String(body.to ?? ''),
      cc: body.cc === undefined ? '' : String(body.cc),
      subject: body.subject === undefined ? '' : String(body.subject),
      text: String(body.text ?? ''),
      inReplyToId: typeof body.inReplyToId === 'string' && body.inReplyToId ? body.inReplyToId : null,
      attachEntryIds: Array.isArray(body.attachEntryIds) ? body.attachEntryIds.map(String) : [],
    });
  }

  /** Заготовка ответа или пересылки: получатели, тема и цитата исходного письма. */
  @Get('messages/:id/reply-context')
  @SessionOnly()
  replyContext(@Param('id') id: string, @CurrentUser() user: RequestUser, @Query('mode') mode?: string) {
    const kind = mode === 'replyAll' || mode === 'forward' ? mode : 'reply';
    return this.sender.replyContext(user.id, id, kind);
  }

  // ===== Лента =====

  /** Общее число писем в папке — клиент по нему считает полную высоту скролла. */
  @Get('count')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  count(@CurrentUser() user: RequestUser, @Query('box') box?: string, @Query('account') account?: string) {
    return this.feed.count(user.id, boxOf(box), account || null);
  }

  /** Срез ленты по смещению: `offset` — позиция, `limit` — сколько взять. */
  @Get('range')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  range(
    @CurrentUser() user: RequestUser,
    @Query('box') box?: string,
    @Query('offset') offset?: string,
    @Query('limit') limit?: string,
    @Query('account') account?: string,
  ) {
    const off = Number(offset);
    const lim = Number(limit);
    return this.feed.range(
      user.id,
      boxOf(box),
      Number.isFinite(off) ? off : 0,
      Number.isFinite(lim) ? lim : 100,
      account || null,
    );
  }

  /** Индекс по месяцам — подпись у ползунка и прыжок к месяцу. */
  @Get('months')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  months(@CurrentUser() user: RequestUser, @Query('box') box?: string, @Query('account') account?: string) {
    return this.feed.months(user.id, boxOf(box), account || null);
  }

  /**
   * Поиск по письмам папки: ищем по всему телу письма, а не только по теме.
   *
   * Папка приходит в `box` — поиск идёт ровно там, где смотрит пользователь (это его решение),
   * а не по всему ящику сразу. Сортировка — по дате, от свежих к старым: ранжирование по
   * релевантности сознательно не используется, поэтому в ответе нет ни счёта, ни подсветки.
   *
   * Ручка читает БД, а не IMAP: письмо обязано быть уже сохранённым (в том числе иметь
   * разобранное тело в поисковом индексе — см. `pending` в ответе).
   */
  @Get('search')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  searchMessages(
    @CurrentUser() user: RequestUser,
    @Query('q') q?: string,
    @Query('box') box?: string,
    @Query('account') account?: string,
    @Query('offset') offset?: string,
    @Query('limit') limit?: string,
  ) {
    const off = Number(offset);
    const lim = Number(limit);
    return this.search.search(user.id, {
      q: q ?? '',
      box: boxOf(box),
      accountId: account || null,
      offset: Number.isFinite(off) ? off : 0,
      limit: Number.isFinite(lim) ? lim : undefined,
    });
  }

  // ===== Письмо =====

  @Get('messages/:id')
  @SessionOnly()
  get(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.feed.get(user.id, id);
  }

  /**
   * Тело письма для показа. `images=1` — пользователь нажал «показать картинки»: тогда
   * внешние картинки в разметке остаются, иначе вырезаются (трекинг-пиксели).
   * `text=1` — отдать текстовую версию даже у письма с разметкой: у части рассылок вёрстка
   * нечитаема в любом движке, и это единственный способ прочитать письмо.
   */
  @Get('messages/:id/body')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  body(
    @Param('id') id: string,
    @CurrentUser() user: RequestUser,
    @Query('images') images?: string,
    @Query('text') text?: string,
  ) {
    return this.feed.body(user.id, id, images === '1', text === '1');
  }

  /**
   * Перевод письма на русский локальной моделью на маке. Возвращает обычный текст перевода.
   *
   * Отдельный маршрут, а не поле в теле письма: перевод может идти десятки секунд, и городить
   * его в запрос, который открывает письмо, значило бы держать экран пустым всё это время.
   * Кэш переводит повторный вызов в мгновенный ответ (см. `mail-translate.service.ts`).
   *
   * Лимит ниже остальных почтовых ручек намеренно: каждый промах кэша занимает один из четырёх
   * слотов движка на маке, и десяток одновременных переводов выстроил бы за ним весь сайт.
   */
  @Post('messages/:id/translate')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(20, 60_000)
  translateMessage(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.translator.translate(user.id, id);
  }

  /** Сырое письмо файлом: содержимое письма как оно пришло, ничего не потеряно. */
  @Get('messages/:id/raw')
  @SessionOnly()
  async raw(@Param('id') id: string, @CurrentUser() user: RequestUser, @Req() req: Request, @Res() res: Response) {
    const { key, name } = await this.feed.rawKey(user.id, id);
    await sendObjectOr404(req, res, this.s3, key, {
      mime: 'message/rfc822',
      disposition: 'attachment',
      filename: name,
    });
  }

  /** Логотип отправителя (favicon домена): сервер тянет и кэширует, клиент наружу не ходит. */
  @Get('favicon')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(1200, 60_000)
  async favicon(@Query('domain') domain: string, @Res() res: Response) {
    const fav = await this.faviconService.get(domain);
    // Тип берём из кэша как есть, но отдаём только растровые: SVG здесь был бы документом
    // нашего origin (сервис сохраняет чужой Content-Type, а favicon тянется с чужого домена).
    const mime = String(fav?.mime ?? '').split(';')[0].trim().toLowerCase();
    if (!fav || !FAVICON_MIME.has(mime)) {
      res.status(404).end();
      return;
    }
    res.setHeader('Content-Type', mime);
    // Логотип — не документ: nosniff запрещает движку угадывать тип, а CSP с sandbox не даёт
    // отрисовать его как страницу, даже если картинка окажется разметкой.
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'none'; sandbox");
    res.setHeader('Cache-Control', 'public, max-age=86400');
    res.send(fav.bytes);
  }

  /**
   * Картинка из письма через наш сервер: письмо грузит её с нашего домена вместо чужого.
   *
   * Ручка ПУБЛИЧНАЯ, и это не упущение: документ письма грузится в WebView без адреса
   * (`about:blank`), cookie веб-сессии у него нет, а картинки он запрашивает сам. Вместо сессии
   * адрес подписан (HMAC от ключа рассылок, см. `mail-image.service.ts`), поэтому открытым
   * прокси ручка не становится: по неподписанному адресу сервер наружу не пойдёт.
   *
   * Отдаём только растровые картинки, определённые по первым байтам: чужой ответ уходит
   * браузеру с нашего origin, и документ (SVG, HTML) по этому адресу исполнил бы свои скрипты
   * в контексте нашего домена. `nosniff` и CSP с `sandbox` — вторая линия на тот же случай.
   *
   * Кэширование разрешено надолго: адрес подписан под конкретную картинку и её не меняет,
   * а WebView держит кэш сам — повторное открытие письма не ходит ни к нам, ни к отправителю.
   */
  @Public()
  @Get('image')
  @UseGuards(RateLimitGuard)
  @RateLimit(1200, 60_000)
  async image(@Query('u') target: string, @Query('s') sig: string, @Res() res: Response) {
    const got = await this.imageService.fetch(String(target ?? ''), String(sig ?? ''));
    if (!got) {
      res.status(404).end();
      return;
    }
    res.setHeader('Content-Type', got.mime);
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'none'; sandbox");
    // Неделя: картинка письма по подписанному адресу не меняется, а трекеры-пиксели так
    // перестают срабатывать на каждом открытии письма.
    res.setHeader('Cache-Control', 'public, max-age=604800, immutable');
    res.send(got.bytes);
  }

  @Post('messages/:id/seen')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(1200, 60_000)
  setSeen(@Param('id') id: string, @Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    return this.feed.setSeen(user.id, id, body.seen !== false);
  }

  /**
   * Флаг «важное». Ручка объявлена для совместимости и на будущее: `flagged` приходит в ленте
   * и в письме, а Flutter-клиент пока рисует только состояние (переключателя в интерфейсе нет,
   * см. `flutter/lib/api/models.dart` — поле разбирается, ручка не вызывается). Удалять её из-за
   * этого не стоит: поверхность API у клиента в проде, а форма ответа уже есть в контракте.
   */
  @Post('messages/:id/flagged')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  setFlagged(@Param('id') id: string, @Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    return this.feed.setFlagged(user.id, id, body.flagged === true);
  }

  /**
   * В корзину почты. Это отдельная от файлов корзина: письмо мягко удаляется (deletedAt),
   * вложения при нём остаются и в файловой корзине не появляются. На сервере аккаунта
   * ничего не меняется: синхронизация в этой фазе только читает.
   */
  @Delete('messages/:id')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  remove(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.feed.deleteMessage(user.id, id);
  }

  /** Вернуть письмо из корзины почты (вложения никуда не девались, письмо снова в ленте). */
  @Post('messages/:id/restore')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  restore(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.feed.restoreMessage(user.id, id);
  }

  /**
   * Удалить письмо навсегда: только из корзины, вместе с вложениями и сырым .eml.
   * `@SessionOnly` — по той же причине, что у `/mail/trash/purge`: безвозвратная очистка
   * не должна быть доступна токену устройства (иначе политика ручки-соседа обходится).
   */
  @Post('messages/:id/purge')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(300, 60_000)
  purgeMessage(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.feed.purgeMessage(user.id, id);
  }

  /** Очистить корзину почты целиком (безвозвратно). */
  @SessionOnly()
  @Post('trash/purge')
  @UseGuards(RateLimitGuard)
  @RateLimit(60, 60_000)
  purgeTrash(@CurrentUser() user: RequestUser) {
    return this.feed.purgeTrash(user.id);
  }

  /**
   * Метаданные части письма: по ним клиент строит ссылку на файл (`/files/:entryId/...`).
   * Клиент пока берёт вложения из самого письма (`feed.get`), и ручка дублирует эти данные;
   * оставлена как часть контракта (у клиента в проде может появиться отдельный экран вложения).
   */
  @Get('messages/:id/attachments/:attachmentId')
  @SessionOnly()
  attachment(
    @Param('id') id: string,
    @Param('attachmentId') attachmentId: string,
    @CurrentUser() user: RequestUser,
  ) {
    return this.feed.attachment(user.id, id, attachmentId);
  }
}

/** Папка из строки запроса: у почты их три, любое другое значение — ошибка. */
function boxOf(raw?: string): string {
  if (raw === undefined || raw === '' || raw === 'inbox') return 'inbox';
  if (raw === 'sent' || raw === 'trash') return raw;
  throw badRequest('unknown mail box', 'mail_box_unknown');
}

/**
 * Адрес без plus-метки: `user+tag@domain` → `user@domain`. Так работает plus-адресация, и без
 * этого письмо на такой адрес не нашло бы аккаунт (ответ 503 → повторные доставки → bounce).
 * `null`, если plus-метки нет: тогда повторять поиск незачем.
 */
function stripPlusTag(addr: string): string | null {
  const at = addr.lastIndexOf('@');
  if (at <= 0) return null;
  const local = addr.slice(0, at);
  const plus = local.indexOf('+');
  if (plus <= 0) return null;
  return `${local.slice(0, plus)}${addr.slice(at)}`.toLowerCase();
}
