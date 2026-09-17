import { Body, Controller, Delete, Get, HttpCode, Param, Post, Req, Res, UseGuards } from '@nestjs/common';
import type { Request, Response } from 'express';
import { AuthService } from './auth.service';
import { CurrentUser, Public, RateLimit, RequestUser, SessionOnly } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { env } from '../config/env';
import { badRequest } from '../common/errors';

@Controller('auth')
export class AuthController {
  constructor(private readonly auth: AuthService) {}

  @Public()
  @UseGuards(RateLimitGuard)
  @RateLimit(5, 60_000)
  @HttpCode(200)
  @Post('login')
  async login(
    @Body() body: Record<string, unknown>,
    @Req() req: Request,
    @Res({ passthrough: true }) res: Response,
  ) {
    const login = typeof body.login === 'string' ? body.login : '';
    const password = typeof body.password === 'string' ? body.password : '';
    // `client` — как приложение себя называет (например «Cloudly 1.0.0 · android»): по этой
    // строке человек узнаёт свой вход в списке сеансов. Заголовок — на случай, когда метки нет.
    const result = await this.auth.login(login, password, req.ip, {
      client: typeof body.client === 'string' ? body.client : undefined,
      userAgent: req.headers['user-agent'],
    });
    res.cookie(env.COOKIE_NAME, result.token, {
      httpOnly: true,
      secure: env.NODE_ENV === 'production',
      sameSite: 'lax',
      path: '/',
      maxAge: result.expiresInMs,
    });
    return { user: result.user };
  }

  /**
   * Выход. Cookie чистится ВСЕГДА, даже если сессии в БД уже нет: иначе мёртвая cookie
   * живёт в браузере ещё 30 дней, а `AuthGuard` смотрит cookie первой и до Bearer не
   * доходит — все запросы получают 401, и повторный вход по токену недостижим.
   *
   * Ручка публичная намеренно: иначе при мёртвой сессии `AuthGuard` отвечает 401 и до
   * `clearCookie` дело не доходит вовсе — то есть выйти и избавиться от просроченной cookie
   * было бы нельзя. Опасного здесь ничего нет: без валидного токена метод ничего не удаляет,
   * а POST от чужого сайта отсекает OriginGuard (проверка Origin/Referer/Sec-Fetch-Site).
   */
  @Public()
  @HttpCode(200)
  @Post('logout')
  async logout(@Req() req: Request, @Res({ passthrough: true }) res: Response) {
    const result = await this.auth.logout(String(req.cookies?.[env.COOKIE_NAME] ?? ''), req.ip);
    res.clearCookie(env.COOKIE_NAME, {
      httpOnly: true,
      secure: env.NODE_ENV === 'production',
      sameSite: 'lax',
      path: '/',
    });
    return result;
  }

  /**
   * Смена логина и пароля владельца: только веб-сессия (у device-токена нет пароля, а смена
   * пароля из украденного токена — это захват аккаунта). Принимает `currentPassword` (обязателен),
   * `login` и `newPassword` — то, что заполнено, то и меняется. Смена пароля гасит все прочие
   * сессии: смысл смены пароля в том числе в том, чтобы выкинуть того, кто мог войти со старым.
   */
  @SessionOnly()
  @HttpCode(200)
  @Post('credentials')
  changeCredentials(
    @Body() body: Record<string, unknown>,
    @CurrentUser() user: RequestUser,
    @Req() req: Request,
  ) {
    return this.auth.changeCredentials(
      user.id,
      body.currentPassword,
      body.login,
      body.newPassword,
      String(req.cookies?.[env.COOKIE_NAME] ?? ''),
      req.ip,
    );
  }

  @Get('me')
  me(@CurrentUser() user: RequestUser) {
    // для Bearer-токена deviceId задан гардом: клиент получает корень зеркала своего устройства
    return this.auth.me(user.id, user.deviceId ?? null);
  }

  /**
   * Живые сеансы владельца: список для настроек приложения.
   *
   * Отдаёт и «какой из них текущий» (`current`) — по нему интерфейс помечает этот сеанс
   * «это устройство» и не предлагает его завершить.
   */
  @SessionOnly()
  @Get('sessions')
  listSessions(@CurrentUser() user: RequestUser, @Req() req: Request) {
    return this.auth.listSessions(user.id, String(req.cookies?.[env.COOKIE_NAME] ?? ''));
  }

  /**
   * Завершить один сеанс: кнопка рядом с конкретным входом в списке.
   *
   * Только веб-сессия (`SessionOnly`) и только свой сеанс; свой текущий завершать нельзя —
   * для него есть «Выйти», который делает то же самое и ещё чистит cookie приложения.
   */
  @SessionOnly()
  @HttpCode(200)
  @Delete('sessions/:id')
  revokeSession(@Param('id') id: string, @CurrentUser() user: RequestUser, @Req() req: Request) {
    return this.auth.revokeSession(user.id, id, String(req.cookies?.[env.COOKIE_NAME] ?? ''), req.ip);
  }

  /**
   * Гасит все прочие входы в аккаунт — все веб-сессии, кроме той, из которой пришёл запрос.
   *
   * Только веб-сессия, как и смена пароля: device-токен с телефона не должен уметь выкидывать
   * владельца из его же браузера и приложения. `SessionOnly` отсекает такой запрос сам (403),
   * а cookie текущей сессии приходит в том же запросе — по ней и определяется, какую сессию
   * оставить.
   */
  @SessionOnly()
  @HttpCode(200)
  @Post('sessions/revoke-others')
  revokeOtherSessions(@CurrentUser() user: RequestUser, @Req() req: Request) {
    return this.auth.revokeOtherSessions(user.id, String(req.cookies?.[env.COOKIE_NAME] ?? ''), req.ip);
  }

  // ===== App-password / device-токены =====
  // Выпуск и отзыв токенов — только веб-сессия: устройство со своим токеном не должно
  // выпускать себе новые (иначе отзыв украденного токена ничего не даёт).

  @SessionOnly()
  @Post('tokens')
  createToken(@Body() body: Record<string, unknown>, @CurrentUser() user: RequestUser) {
    const label = typeof body.label === 'string' ? body.label : 'app';
    return this.auth.createToken(user.id, label);
  }

  // Список токенов — тоже только веб-сессия: метки, scope и даты всех устройств не должен
  // видеть сам device-токен (по нему видно, сколько устройств и когда ими пользовались).
  @SessionOnly()
  @Get('tokens')
  listTokens(@CurrentUser() user: RequestUser) {
    return this.auth.listTokens(user.id);
  }

  @SessionOnly()
  @HttpCode(200)
  @Delete('tokens/:id')
  revokeToken(@Param('id') id: string, @CurrentUser() user: RequestUser) {
    return this.auth.revokeToken(user.id, id);
  }

  /**
   * Токен отзывает сам себя («Выйти» на телефоне). Отдельная ручка нужна потому, что
   * `DELETE /auth/tokens/:id` доступен только веб-сессии: выход на телефоне стирал токен
   * лишь локально, а на сервере он оставался живым до 180 дней с полным files:rw по REST
   * и WebDAV. SessionOnly здесь не ставим — иначе смысл теряется; отозвать можно только
   * тот токен, которым пришёл запрос.
   */
  @HttpCode(200)
  @Delete('me/token')
  revokeOwnToken(@CurrentUser() user: RequestUser) {
    if (!user.deviceId) throw badRequest('this endpoint requires an API token (Bearer), not a web session');
    return this.auth.revokeToken(user.id, user.deviceId, true);
  }
}
