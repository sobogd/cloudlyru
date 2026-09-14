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

/**
 * Транспорт аккаунта.
 *
 * 465 — шифрование с первого байта, 587 (и всё остальное) — STARTTLS, причём обязательный:
 * пароль приложения нельзя отправлять по открытому каналу, и если сервер шифрование не
 * предложит, лучше отказ, чем тихая отправка пароля в открытом виде.
 */
export function createSmtpTransport(account: SmtpCredentials): Transporter {
  return nodemailer.createTransport({
    host: account.smtpHost,
    port: account.smtpPort,
    secure: account.smtpPort === 465,
    requireTLS: account.smtpPort !== 465,
    auth: { user: account.login, pass: account.password },
    // Логи транспорта содержат диалог с сервером целиком, включая AUTH
    logger: false,
    debug: false,
    connectionTimeout: 30_000,
    greetingTimeout: 20_000,
    socketTimeout: 120_000,
  });
}

/**
 * Проверка доступа к SMTP без отправки письма. Возвращает текст ошибки или null.
 *
 * Делается при добавлении аккаунта: «почта читается, а письма не уходят» — не то, что стоит
 * выяснять, когда письмо уже написано и нажато «отправить».
 */
export async function verifySmtpAccess(account: SmtpCredentials): Promise<string | null> {
  const transport = createSmtpTransport(account);
  try {
    await transport.verify();
    return null;
  } catch (e) {
    const err = e as Error & { response?: string; code?: string };
    return String(err.response || err.message || e).slice(0, 300);
  } finally {
    transport.close();
  }
}
