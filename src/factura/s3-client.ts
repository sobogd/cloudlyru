import { S3Client } from '@aws-sdk/client-s3';
import { env } from '../config/env';

/**
 * S3-хранилище фактур: бакет с PDF инвойсов и сканами расходов.
 *
 * Перенесённые модули фактуры (PDF, документы расходов, документы деклараций) держали каждый
 * свой клиент и читали `S3_HOST`/`S3_KEY`/`S3_TOKEN`/`S3_NAME` из окружения. В облаке клиент для
 * файлов уже есть, и проверено, что те же ключи Hetzner открывают бакет фактуры — поэтому секреты
 * здесь не дублируются: берём `S3_FILES_*` (endpoint, регион, ключи), а имя бакета — своё
 * (`S3_INVOICES_BUCKET`).
 *
 * Клиент один на процесс и создаётся лениво: в разработке ключей может не быть вовсе, и сервис
 * обязан подняться — падать он должен только на реальной попытке обратиться к S3.
 */
let client: S3Client | null = null;

/**
 * Клиент S3 для фактурного бакета (ленивая инициализация, один на процесс).
 *
 * @returns клиент, настроенный на тот же endpoint и те же ключи, что и файловое хранилище облака.
 * @throws Error, если ключи S3 не заданы — только в момент первого обращения, не на старте.
 */
export function facturaS3Client(): S3Client {
  if (client) return client;
  const endpoint = env.S3_FILES_ENDPOINT;
  const region = env.S3_FILES_REGION;
  const accessKeyId = env.S3_FILES_ACCESS_KEY;
  const secretAccessKey = env.S3_FILES_SECRET_KEY;
  if (!endpoint || !region || !accessKeyId || !secretAccessKey) {
    throw new Error('S3 не настроен: нет S3_FILES_ENDPOINT/S3_FILES_REGION/S3_FILES_ACCESS_KEY/S3_FILES_SECRET_KEY');
  }
  client = new S3Client({
    endpoint,
    region,
    credentials: { accessKeyId, secretAccessKey },
    forcePathStyle: true,
  });
  return client;
}

/**
 * Имя бакета с документами фактур.
 *
 * @returns `S3_INVOICES_BUCKET` из конфига (по умолчанию `iq-factura-invoices`).
 * Побочных эффектов нет; объекты в бакете адресуются по companyId, поэтому перенос данных
 * облака ключи не меняет.
 */
export function invoicesBucket(): string {
  return env.S3_INVOICES_BUCKET;
}
