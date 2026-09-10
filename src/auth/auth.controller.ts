import { Body, Controller, Delete, Get, HttpCode, Param, Post, Req, Res, UseGuards } from '@nestjs/common';
import type { Request, Response } from 'express';
import { AuthService } from './auth.service';
import { CurrentUser, Public, RateLimit, RequestUser, SessionOnly } from '../common/decorators';
import { RateLimitGuard } from '../common/guards/rate-limit.guard';
import { env } from '../config/env';

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
    const result = await this.auth.login(login, password, req.ip);
    res.cookie(env.COOKIE_NAME, result.token, {
      httpOnly: true,
      secure: env.NODE_ENV === 'production',
      sameSite: 'lax',
      path: '/',
      maxAge: result.expiresInMs,
    });
    return { user: result.user };
  }

  @HttpCode(200)
  @Post('logout')
  async logout(@Req() req: Request) {
    return this.auth.logout(String(req.cookies?.[env.COOKIE_NAME] ?? ''));
  }

  @Get('me')
  me(@CurrentUser() user: RequestUser) {
    return this.auth.me(user.id);
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
}
