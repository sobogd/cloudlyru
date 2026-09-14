import { Body, Controller, Delete, Get, Param, Patch, Post, Query, Req, Res, UseGuards } from '@nestjs/common';
import type { Request, Response } from 'express';
import { MailAccountsService } from './mail-accounts.service';
import { MailFeedService } from './mail-feed.service';
import { MailSyncService } from './mail-sync.service';
import { MailPurgeService } from './mail-purge.service';
import { MailSendService } from './mail-send.service';
import { S3Service } from '../s3/s3.service';
import { sendObjectOr404 } from '../common/http-object';
import { CurrentUser, RateLimit, RequestUser, SessionOnly } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { badRequest } from '../common/errors';

/**
 * Ручки раздела «Почта».
 *
 * Управление аккаунтами — только веб-сессией (`SessionOnly`): там принимается пароль
 * приложения, и ApiToken устройства (WebDAV, клиент синхронизации) не должен уметь
 * ни добавить аккаунт, ни посмотреть список. Остальные ручки — обычные, читают почту
 * текущего пользователя.
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
    private readonly purge: MailPurgeService,
    private readonly s3: S3Service,
  ) {}

  // ===== Аккаунты =====

  /** Список аккаунтов со статусом синхронизации и числом писем. Паролей тут нет и быть не может. */
  @Get('accounts')
  @SessionOnly()
  listAccounts(@CurrentUser() user: RequestUser) {
    return this.accounts.list(user.id);
  }

  /** Добавить аккаунт: пароль приложения проверяем живым подключением и сразу шифруем. */
  @Post('accounts')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(20, 60_000)
  addAccount(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    return this.accounts.create(user.id, {
      kind: body.kind,
      email: body.email,
      password: body.password,
      imapHost: body.imapHost,
      smtpHost: body.smtpHost,
    });
  }

  /** Включить/выключить аккаунт или сменить пароль приложения. */
  @Patch('accounts/:id')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(20, 60_000)
  patchAccount(@Param('id') id: string, @Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    return this.accounts.patch(user.id, id, { enabled: body.enabled, password: body.password });
  }

  @Delete('accounts/:id')
  @SessionOnly()
  removeAccount(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.accounts.remove(user.id, id);
  }

  /** Забрать почту сейчас, не дожидаясь расписания. Проход асинхронный: ответ сразу. */
  @Post('sync')
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

  // ===== Чистка сервера =====

  /**
   * Отчёт по удалению копий с сервера. Ничего не меняет — это прогон «на сухую», и он
   * обязателен перед удалением: сначала видно, сколько писем попадёт под нож и почему
   * остальные не попали.
   */
  @Get('purge/plan')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(30, 60_000)
  purgePlan(@CurrentUser() user: RequestUser, @Query('limit') limit?: string) {
    const n = Number(limit);
    return this.purge.plan(user.id, Number.isFinite(n) && n > 0 ? { limit: n } : {});
  }

  /**
   * Удалить копии с сервера. Без `confirm: true` ручка отказывается работать, а без
   * MAIL_PURGE_ENABLED не делает ничего — удаление необратимо, и это последний порог.
   */
  @Post('purge/run')
  @SessionOnly()
  @UseGuards(RateLimitGuard)
  @RateLimit(10, 60_000)
  purgeRun(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    const n = Number(body.limit);
    return this.purge.run(user.id, {
      confirm: body.confirm === true,
      ...(Number.isFinite(n) && n > 0 ? { limit: n } : {}),
    });
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
  count(@CurrentUser() user: RequestUser, @Query('box') box?: string) {
    return this.feed.count(user.id, boxOf(box));
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
  ) {
    const off = Number(offset);
    const lim = Number(limit);
    return this.feed.range(user.id, boxOf(box), Number.isFinite(off) ? off : 0, Number.isFinite(lim) ? lim : 100);
  }

  /** Индекс по месяцам — подпись у ползунка и прыжок к месяцу. */
  @Get('months')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  months(@CurrentUser() user: RequestUser, @Query('box') box?: string) {
    return this.feed.months(user.id, boxOf(box));
  }

  // ===== Письмо =====

  @Get('messages/:id')
  get(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.feed.get(user.id, id);
  }

  /**
   * Тело письма для показа. `images=1` — пользователь нажал «показать картинки»: тогда
   * внешние картинки в разметке остаются, иначе вырезаются (трекинг-пиксели).
   */
  @Get('messages/:id/body')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  body(@Param('id') id: string, @CurrentUser() user: RequestUser, @Query('images') images?: string) {
    return this.feed.body(user.id, id, images === '1');
  }

  /** Сырое письмо файлом: содержимое письма как оно пришло, ничего не потеряно. */  @Get('messages/:id/raw')
  async raw(@Param('id') id: string, @CurrentUser() user: RequestUser, @Req() req: Request, @Res() res: Response) {
    const { key, name } = await this.feed.rawKey(user.id, id);
    await sendObjectOr404(req, res, this.s3, key, {
      mime: 'message/rfc822',
      disposition: 'attachment',
      filename: name,
    });
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
   * В корзину. Письмо уходит в общую с файлами корзину вместе с вложениями, на сервере
   * аккаунта ничего не меняется: синхронизация в этой фазе только читает.
   */
  @Delete('messages/:id')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  remove(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.feed.deleteMessage(user.id, id);
  }

  /** Вернуть письмо из корзины (вложения возвращаются вместе с ним). */
  @Post('messages/:id/restore')
  @UseGuards(RateLimitGuard)
  @RateLimit(600, 60_000)
  restore(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.feed.restoreMessage(user.id, id);
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

/** Папка из строки запроса: у почты их две, любое другое значение — «Входящие». */
function boxOf(raw?: string): string {
  if (raw === undefined || raw === '' || raw === 'inbox') return 'inbox';
  if (raw === 'sent') return 'sent';
  throw badRequest('unknown mail box', 'mail_box_unknown');
}
