import { Body, Controller, Delete, Get, Headers, Param, Post, Query, Req, Res, UseGuards } from '@nestjs/common';
import type { Request, Response } from 'express';
import { MailAccountsService } from './mail-accounts.service';
import { MailFeedService } from './mail-feed.service';
import { MailSyncService } from './mail-sync.service';
import { env } from '../config/env';
import { MailFaviconService } from './mail-favicon.service';
import { MailIngestService } from './mail-ingest.service';
import { MailSendService } from './mail-send.service';
import { S3Service } from '../s3/s3.service';
import { sendObjectOr404 } from '../common/http-object';
import { CurrentUser, Public, RateLimit, RequestUser, SessionOnly } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { badRequest } from '../common/errors';
import { secretEquals } from './mail-crypto';

/**
 * Ручки раздела «Почта».
 *
 * Аккаунты заведены один раз на сервере и из приложения не редактируются: тут только чтение
 * списка, запуск проверки и работа с письмами. Управление аккаунтами (пароль приложения
 * принимается только на сервере при первичной настройке) закрыто намеренно.
 *
 * Статические пути объявлены до параметрических: иначе `messages` уехало бы в `:id`.
 */
@Controller('mail')
export class MailController {
  constructor(
    private readonly accounts: MailAccountsService,
    private readonly feed: MailFeedService,
    private readonly sync: MailSyncService,
    private readonly sender: MailSendService,
    private readonly ingestService: MailIngestService,
    private readonly faviconService: MailFaviconService,
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
    void user;
    void this.sync.runPass('вручную из интерфейса');
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
    if (!expected || !secretEquals(token ?? '', expected)) {
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
    const result = await this.ingestService.ingestInbound(to, source);
    if (result === 'unknown-account') {
      // Не 404: аккаунт могут завести на сервере позже, и тогда письмо доедет повторной доставкой.
      res.status(503).json({ message: `no mail account for ${to}` });
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
  replyContext(@Param('id') id: string, @CurrentUser() user: RequestUser, @Query('mode') mode?: string) {
    const kind = mode === 'replyAll' || mode === 'forward' ? mode : 'reply';
    return this.sender.replyContext(user.id, id, kind);
  }

  // ===== Лента =====

  /** Общее число писем в папке — клиент по нему считает полную высоту скролла. */
  @Get('count')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  count(@CurrentUser() user: RequestUser, @Query('box') box?: string, @Query('account') account?: string) {
    return this.feed.count(user.id, boxOf(box), account || null);
  }

  /** Срез ленты по смещению: `offset` — позиция, `limit` — сколько взять. */
  @Get('range')
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
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  months(@CurrentUser() user: RequestUser, @Query('box') box?: string, @Query('account') account?: string) {
    return this.feed.months(user.id, boxOf(box), account || null);
  }

  // ===== Письмо =====

  @Get('messages/:id')
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

  /** Сырое письмо файлом: содержимое письма как оно пришло, ничего не потеряно. */
  @Get('messages/:id/raw')
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
    if (!fav) {
      res.status(404).end();
      return;
    }
    res.setHeader('Content-Type', fav.mime);
    res.setHeader('Cache-Control', 'public, max-age=86400');
    res.send(fav.bytes);
  }

  @Post('messages/:id/seen')
  @UseGuards(RateLimitGuard)
  @RateLimit(1200, 60_000)
  setSeen(@Param('id') id: string, @Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    return this.feed.setSeen(user.id, id, body.seen !== false);
  }

  @Post('messages/:id/flagged')
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
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  remove(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.feed.deleteMessage(user.id, id);
  }

  /** Вернуть письмо из корзины почты (вложения никуда не девались, письмо снова в ленте). */
  @Post('messages/:id/restore')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  restore(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.feed.restoreMessage(user.id, id);
  }

  /** Удалить письмо навсегда: только из корзины, вместе с вложениями и сырым .eml. */
  @Post('messages/:id/purge')
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

  /** Метаданные части письма: по ним клиент строит ссылку на файл (`/files/:entryId/...`). */
  @Get('messages/:id/attachments/:attachmentId')
  attachment(
    @Param('id') id: string,
    @Param('attachmentId') attachmentId: string,
    @CurrentUser() user: RequestUser,
  ) {
    return this.feed.attachment(user.id, id, attachmentId);
  }
}

/** Потолок размера принимаемого письма: у Gmail предел 25 МБ, у остальных меньше. */
const MAX_INBOUND_BYTES = 64 * 1024 * 1024;

/** Папка из строки запроса: у почты их три, любое другое значение — ошибка. */
function boxOf(raw?: string): string {
  if (raw === undefined || raw === '' || raw === 'inbox') return 'inbox';
  if (raw === 'sent' || raw === 'trash') return raw;
  throw badRequest('unknown mail box', 'mail_box_unknown');
}
