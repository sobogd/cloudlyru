import { Body, Controller, Delete, Get, Param, Patch, Post } from '@nestjs/common';
import { SharesService } from './shares.service';
import { asOptionalString, asString, isPlainObject } from '../common/utils';
import { badRequest } from '../common/errors';

@Controller('shares')
export class SharesController {
  constructor(private readonly shares: SharesService) {}

  @Post()
  create(@Body() body: Record<string, unknown>) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    const kind = body.kind === 'file' || body.kind === 'FILE' ? ('FILE' as const) : ('FOLDER' as const);
    const targetId = asString(body.targetId, 'targetId');
    const password = asOptionalString(body.password, 'password');
    const capability = asOptionalString(body.capability, 'capability') as
      | 'VIEW'
      | 'DOWNLOAD'
      | 'UPLOAD'
      | 'RW'
      | undefined;
    let expiresAt: Date | null | undefined;
    if (body.expiresAt !== undefined && body.expiresAt !== null) {
      if (typeof body.expiresAt !== 'string') throw badRequest('expiresAt must be ISO string');
      const d = new Date(body.expiresAt);
      if (Number.isNaN(d.getTime())) throw badRequest('invalid expiresAt');
      expiresAt = d;
    }
    return this.shares.create({ kind, targetId, password, capability, expiresAt });
  }

  @Get()
  list() {
    return this.shares.list();
  }

  @Patch(':token')
  update(@Param('token') token: string, @Body() body: Record<string, unknown>) {
    if (!isPlainObject(body)) throw badRequest('invalid body');
    let password: string | null | undefined;
    if (body.password !== undefined) {
      if (body.password === null) password = null;
      else if (typeof body.password === 'string') password = body.password;
      else throw badRequest('invalid password');
    }
    let expiresAt: Date | null | undefined;
    if (body.expiresAt !== undefined) {
      if (body.expiresAt === null) expiresAt = null;
      else if (typeof body.expiresAt === 'string') {
        const d = new Date(body.expiresAt);
        if (Number.isNaN(d.getTime())) throw badRequest('invalid expiresAt');
        expiresAt = d;
      } else throw badRequest('invalid expiresAt');
    }
    const capability = asOptionalString(body.capability, 'capability') as
      | 'VIEW'
      | 'DOWNLOAD'
      | 'UPLOAD'
      | 'RW'
      | undefined;
    return this.shares.update(token, { password, expiresAt, capability });
  }

  @Delete(':token')
  revoke(@Param('token') token: string) {
    return this.shares.revoke(token);
  }
}
