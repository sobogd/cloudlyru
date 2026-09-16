import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { env } from '../../config/env';
import { forbidden } from '../errors';

/**
 * CSRF-защита: для небезопасных методов, если браузер прислал Origin/Referer,
 * он обязан совпадать с BASE_URL. Запросы без Origin (curl, мобильные клиенты) — разрешены.
 *
 * Отсюда два следствия, о которых стоит помнить:
 *  1) защита держится не на токене, а на том, что чужой сайт не может подделать Origin, и на
 *     SameSite=Lax у cookie — то есть она слабее обычного CSRF-токена и появилась как замена
 *     ему (веб-клиент — одностраничное приложение на своём origin);
 *  2) GET-методы здесь не проверяются вовсе (браузер шлёт их кросс-доменно без preflight),
 *     поэтому ручка, которая меняет состояние на GET, оказывается без этой защиты
 *     (`GET /auth/me` создаёт корень зеркала — см. src/auth).
 */
@Injectable()
export class OriginGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const req = context.switchToHttp().getRequest();
    if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return true;

    // Sec-Fetch-Site есть во всех современных браузерах и не подделывается страницей: браузер
    // сам говорит, что запрос пришёл с чужого сайта. Проверяем только 'cross-site': 'same-site'
    // (другой поддомен нашего домена) уже разбирает сверка Origin ниже, а запрос без заголовка
    // (старый браузер, curl, мобильный клиент) обязан остаться разрешённым — иначе отвалились бы
    // все клиенты, которые этот заголовок не шлют.
    if (req.headers['sec-fetch-site'] === 'cross-site') {
      throw forbidden('cross-site request rejected');
    }

    const baseOrigin = new URL(env.BASE_URL).origin;

    for (const name of ['origin', 'referer']) {
      const header: unknown = req.headers[name];
      // Дублирующийся заголовок Node отдаёт массивом. Раньше такое значение не считалось
      // заголовком вовсе («не строка — значит, его нет»), и запрос с двумя Origin проходил
      // проверку. Теперь это явный отказ: разбирать, какой из них «правильный», нельзя.
      if (Array.isArray(header)) throw forbidden(`duplicate ${name} header`);
      if (typeof header === 'string' && header.length > 0) {
        let hOrigin: string;
        try {
          hOrigin = new URL(header).origin;
        } catch {
          throw forbidden('bad origin header');
        }
        if (hOrigin !== baseOrigin) throw forbidden('cross-origin request rejected');
      }
    }
    return true;
  }
}
