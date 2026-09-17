import { Injectable, Logger } from '@nestjs/common';
import { createHmac, timingSafeEqual } from 'crypto';
import { env } from '../config/env';
import { fetchPublicBytes, type PublicBytes } from './public-fetch';

/**
 * Картинки писем через наш сервер — то, за счёт чего «всё грузится» у Gmail.
 *
 * Зачем прокси. Письмо приходит с чужих адресов, и половина из них не работает в приложении:
 *   * `http://` — WebView такие подресурсы режет (проверено на живой почте: 20 картинок
 *     в 5 письмах из 14), а браузер их грузит только на страницах по http;
 *   * hotlink-защита — письмо показывается без Referer, и часть CDN отвечает 403;
 *   * трекеры-пиксели — по запросу за картинкой отправитель узнаёт IP, время и клиента;
 *   * медленный и недоступный чужой хост держит загрузку письма, пока не отвалится по таймауту.
 *
 * Что делает прокси: сервер сам скачивает картинку (`fetchPublicBytes` — с защитой от SSRF,
 * потолком размера и таймаутом) и отдаёт её письму со своего адреса по https. Письму больше
 * не важно, что было в оригинале: ни схема, ни Referer, ни политика смешанного контента.
 * Так же поступает Gmail: он отдаёт картинки с `googleusercontent.com`, поэтому в нём они
 * видны всегда.
 *
 * Адрес картинки подписывается (HMAC), потому что ручка публичная: cookie веб-сессии у WebView
 * нет (документ письма грузится без адреса), а подпись даёт ровно то, что нужно — по чужому
 * адресу сервер наружу не пойдёт, и открытого прокси не получится. Срок у подписи не ставим
 * намеренно: письмо открывают повторно и через год, и подпись «на час» сломала бы старые письма.
 */
@Injectable()
export class MailImageService {
  private readonly logger = new Logger(MailImageService.name);

  /**
   * Ключ подписи — подключ от ключа рассылок (`MAIL_SECRET_KEY`), а не сам ключ: им шифруются
   * пароли почтовых аккаунтов, и второй способ его применения лучше не заводить. Без ключа
   * прокси выключен, и письмо показывается как раньше, с прямыми адресами.
   */
  private readonly key: Buffer | null = env.MAIL_SECRET_KEY
    ? createHmac('sha256', env.MAIL_SECRET_KEY).update('mail-image-v1').digest()
    : null;

  /** Потолок одной картинки: письма с фотографиями бывают тяжёлыми, но не бесконечно. */
  private static readonly MAX_BYTES = 8 * 1024 * 1024;
  /** Таймаут на попытку: медленный чужой хост не должен держать запрос телефона. */
  private static readonly TIMEOUT_MS = 8000;
  /**
   * Кем представляемся чужому CDN. Браузерное начало строки — не обман ради обмана: часть
   * рассылочных CDN отдаёт картинки только «браузерным» клиентам, а остальным отвечает 403.
   * Свой адрес в UA оставляем: администратор того сайта должен видеть, кто к нему ходит.
   *
   * Чего этим не починить: hotlink-защиту, которой нужен `Referer` с самого сайта. Мы его
   * не подставляем (как и Gmail): заголовка нет — значит, для таких CDN картинки не будет.
   */
  private static readonly UA =
    'Mozilla/5.0 (compatible; CloudlyRu/0.1; +https://files.iq-factura.com) mail-image';
  /**
   * Короткая подпись в адресе: 16 байт от HMAC — это 2^128 вариантов на известный адрес,
   * а длинный адрес в разметке письма только мешает читать разметку.
   */
  private static readonly SIG_BYTES = 16;

  /** Работает ли прокси: без ключа подписи он выключен (см. комментарий класса). */
  get enabled(): boolean {
    return this.key !== null;
  }

  /**
   * Адрес картинки на нашем сервере — вместо чужого адреса в разметке письма.
   *
   * Адрес абсолютный: документ письма грузится без адреса (`about:blank`), и относительная
   * ссылка в нём не разрешилась бы никуда. Параметры кодируем: чужой адрес содержит `&`, `?`
   * и `=`, а без кодирования сервер увидел бы другие параметры.
   */
  url(target: string): string {
    const base = env.BASE_URL.replace(/\/+$/, '');
    const sig = this.sign(target);
    return `${base}/api/v1/mail/image?u=${encodeURIComponent(target)}&s=${sig}`;
  }

  /**
   * Проверить подпись и скачать картинку. `null` — подпись не сошлась, адрес не http(s),
   * хост не публичный, ответ не картинка или слишком велик: письму в этих случаях нечего
   * показать, и подставлять заглушку мы не будем.
   */
  async fetch(rawUrl: string, sig: string): Promise<PublicBytes | null> {
    if (!this.key) return null;
    const expected = this.sign(rawUrl);
    // Сравнение постоянного времени: по времени ответа подпись не должна подбираться побайтово.
    const a = Buffer.from(expected, 'utf8');
    const b = Buffer.from(String(sig ?? ''), 'utf8');
    if (a.length !== b.length || !timingSafeEqual(a, b)) {
      this.logger.warn('картинка письма: подпись не сошлась');
      return null;
    }
    return fetchPublicBytes(rawUrl, {
      maxBytes: MailImageService.MAX_BYTES,
      timeoutMs: MailImageService.TIMEOUT_MS,
      userAgent: MailImageService.UA,
      onProblem: (reason) => this.logger.warn(`картинка письма ${hostOf(rawUrl)}: ${reason}`),
    });
  }

  /** Подпись адреса: `HMAC(ключ, адрес)`, обрезанная до SIG_BYTES. */
  private sign(target: string): string {
    return createHmac('sha256', this.key as Buffer)
      .update(target)
      .digest('hex')
      .slice(0, MailImageService.SIG_BYTES * 2);
  }
}

/** Хост из адреса для лога: сам адрес печатать нельзя — в нём бывают токены и параметры. */
function hostOf(raw: string): string {
  try {
    return new URL(raw).hostname;
  } catch {
    return 'адрес не разобран';
  }
}
