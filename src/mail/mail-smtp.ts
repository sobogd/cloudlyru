import nodemailer, { type Transporter } from 'nodemailer';

/**
 * SMTP-транспорт и его проверка — отдельным модулем, а не методом сервиса.
 *
 * Причина техническая, но по сути правильная: проверка отправки нужна и сервису аккаунтов
 * (при добавлении), и сервису отправки. Если бы она жила в сервисе отправки, два сервиса
 * ссылались бы друг на друга, и Nest не смог бы их собрать без forwardRef — то есть круговая
 * зависимость подсказывала, что общая часть вообще не про них.
 */

export interface SmtpCredentials {
  smtpHost: string;
  smtpPort: number;
  login: string;
  password: string;
}

/** Сколько ждём установления соединения. У почтовых серверов бывает и по 20 секунд. */
const CONNECT_TIMEOUT_MS = 20_000;

/**
 * Транспорт аккаунта.
 *
 * 465 — шифрование с первого байта, 587 (и всё остальное) — STARTTLS, причём обязательный:
 * пароль приложения нельзя отправлять по открытому каналу, и если сервер шифрование не
 * предложит, лучше отказ, чем тихая отправка пароля в открытом виде.
 *
 * `family: 4` — намеренно и с объяснением. Боевой сервер живёт на Hetzner, где IPv6 поднят,
 * но наружу работает не всегда: попытка подключиться к smtp.gmail.com повисала в таймауте
 * (у Google есть AAAA-запись, у smtp.mail.me.com на тот момент не было — поэтому Apple
 * подключился сразу, а Gmail нет). Принудительный IPv4 стоит нам ничего: у всех крупных
 * почтовых провайдеров есть A-записи.
 */
export function createSmtpTransport(account: SmtpCredentials, family: 4 | 6 | 0 = 4): Transporter {
  return nodemailer.createTransport({
    host: account.smtpHost,
    port: account.smtpPort,
    secure: account.smtpPort === 465,
    requireTLS: account.smtpPort !== 465,
    auth: { user: account.login, pass: account.password },
    // Логи транспорта содержат диалог с сервером целиком, включая AUTH
    logger: false,
    debug: false,
    connectionTimeout: CONNECT_TIMEOUT_MS,
    greetingTimeout: 20_000,
    socketTimeout: 120_000,
    ...(family ? { family } : {}),
  });
}

/**
 * Порты, которые имеет смысл попробовать: сначала заявленный, потом общепринятая замена
 * (465 ↔ 587). Оба поддерживают и Gmail, и iCloud, и почти любой корпоративный сервер,
 * а на практике один из них бывает закрыт на стороне сети или хостинга.
 */
function portsToTry(port: number): number[] {
  const alternative = port === 465 ? 587 : port === 587 ? 465 : null;
  return alternative ? [port, alternative] : [port];
}

export interface SmtpVerifyResult {
  /** Текст ошибки или null, если доступ есть. */
  error: string | null;
  /** Порт, на котором получилось (или заявленный, если не получилось ни на одном). */
  port: number;
  /** Что происходило на каждой попытке — это уходит в текст ошибки, чтобы причина была видна. */
  attempts: string[];
}

/**
 * Проверка доступа к SMTP без отправки письма. Возвращает рабочий порт и/или причину отказа.
 *
 * Делается при добавлении аккаунта: «почта читается, а письма не уходят» — не то, что стоит
 * выяснять, когда письмо уже написано и нажато «отправить».
 */
export async function verifySmtpAccess(account: SmtpCredentials): Promise<SmtpVerifyResult> {
  const attempts: string[] = [];
  const ports = portsToTry(account.smtpPort);
  for (const port of ports) {
    const transport = createSmtpTransport({ ...account, smtpPort: port });
    try {
      await transport.verify();
      return { error: null, port, attempts };
    } catch (e) {
      const err = e as Error & { response?: string; code?: string };
      const text = String(err.response || err.message || e).slice(0, 200);
      attempts.push(`${port}: ${text}`);
    } finally {
      transport.close();
    }
  }
  return {
    error: attempts.join('; ') || 'не удалось подключиться',
    port: account.smtpPort,
    attempts,
  };
}
