import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { S3Service } from '../s3/s3.service';
import { parseMessage } from './mail-parse';
import { env } from '../config/env';

/**
 * Поисковый индекс для писем, сохранённых до появления поиска.
 *
 * Зачем отдельный проход. Полного тела письма в БД нет: там лежит только превью (`bodyText`,
 * первые 2000 символов), а само письмо — сырой .eml в S3. Поиск работает по колонке
 * `searchText`, и новые письма заполняют её прямо при сохранении (`mail-ingest.service.ts`,
 * письмо там уже разобрано). Старым письмам эту колонку взять неоткуда: их нужно разобрать
 * заново, то есть сходить в S3 за каждым .eml. Это разовая работа, и делать её в запросе
 * поиска нельзя, поэтому она идёт фоном порциями.
 *
 * Когда проход закончится, он сам замолкает: выборка идёт по `searchIndexedAt IS NULL`,
 * а частичный индекс (`MailMessage_search_backfill_idx`) после этого пуст. Вернуться к работе
 * он может только если отметку кто-то снимет — например, при ручном переиндексировании.
 *
 * Писем с `searchIndexedAt IS NULL` не бывает у новых писем, поэтому счётчик `pending`
 * в выдаче поиска — это ровно «сколько архива ещё не проиндексировано».
 */

/** Сколько писем забираем за один проход. Порция держит и S3-трафик, и память в разумных рамках. */
const DEFAULT_BATCH = 100;
/** Сколько писем разбираем одновременно: каждое — это GET из S3 и разбор MIME в память. */
const POOL = 4;
/** Задержка перед первым проходом после старта: не мешаем сервису подниматься и синхронизации. */
const FIRST_RUN_DELAY_MS = 15_000;

/**
 * Потолок сырья, которое разбираем. Тот же смысл, что у показа тела письма в
 * `mail-feed.service.ts`: разбор держит в памяти и письмо, и все его части, поэтому проверяем
 * размер объекта ДО разбора. Письма выше потолка помечаем проиндексированными с пустым текстом:
 * иначе они возвращались бы в выборку вечно и останавливали весь проход.
 */
const MAX_PARSE_BYTES = 32 * 1024 * 1024;

/**
 * Сколько раз пробуем письмо, прежде чем махнуть на него рукой.
 *
 * Счётчик живёт в памяти процесса и обнуляется рестартом — это осознанно: письмо, у которого
 * пропал объект в хранилище, не должно останавливать бэкфилл, но и «похоронить» его навсегда
 * из-за одной сетевой ошибки нельзя. Три попытки в разных проходах — это минуты, за которые
 * временный сбой проходит; если не прошёл, письмо помечается проиндексированным без текста,
 * и в логе остаётся предупреждение с его id.
 */
const MAX_TRIES = 3;

@Injectable()
export class MailIndexService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(MailIndexService.name);
  /** Интервал проходов и таймер первого прохода. Живут до выключения модуля. */
  private timer?: NodeJS.Timeout;
  private firstRun?: NodeJS.Timeout;
  /** Проход уже идёт: проходы не пересекаются, иначе две порции читали бы одни и те же письма. */
  private busy = false;
  /** Попытки по письмам, которые сейчас не поддаются (см. MAX_TRIES). */
  private readonly attempts = new Map<string, number>();
  /** «Архив проиндексирован» пишем в лог один раз, а не каждым проходом. */
  private doneLogged = false;

  constructor(
    private readonly prisma: PrismaService,
    private readonly s3: S3Service,
  ) {}

  /** Запуск: первый проход с задержкой, дальше по расписанию. Выключено — не запускаем ничего. */
  onModuleInit(): void {
    if (!env.MAIL_SEARCH_INDEX_ENABLED) {
      this.logger.log('индексация почты для поиска выключена (MAIL_SEARCH_INDEX_ENABLED=false)');
      return;
    }
    const intervalMs = env.MAIL_SEARCH_INDEX_INTERVAL_SEC * 1000;
    this.firstRun = setTimeout(() => void this.runBatch(), FIRST_RUN_DELAY_MS);
    this.timer = setInterval(() => void this.runBatch(), intervalMs);
    this.logger.log(
      `индексация почты для поиска: порция ${env.MAIL_SEARCH_INDEX_BATCH} писем каждые ${env.MAIL_SEARCH_INDEX_INTERVAL_SEC} с`,
    );
  }

  /** Выключение: снимаем таймеры, чтобы проход не начался в момент остановки сервиса. */
  onModuleDestroy(): void {
    if (this.firstRun) clearTimeout(this.firstRun);
    if (this.timer) clearInterval(this.timer);
  }

  /**
   * Один проход: взять порцию неиндексированных писем и разобрать их.
   *
   * Ошибка внутри письма не роняет проход: остальные письма порции должны быть обработаны,
   * а причина уходит в лог. Отказ целиком (например, хранилище недоступно) виден по нулю
   * успехов в порции — в этом случае счётчики попыток сбрасываются, чтобы недоступность
   * пятиминутной давности не «похоронила» письма навсегда.
   */
  async runBatch(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const rows = await this.prisma.mailMessage.findMany({
        where: { searchIndexedAt: null },
        select: { id: true, rawAsset: { select: { sha256: true } } },
        // Свежие первыми: их чаще всего и ищут. Порядок совпадает с частичным индексом прохода.
        orderBy: { sortAt: 'desc' },
        take: env.MAIL_SEARCH_INDEX_BATCH,
      });
      if (!rows.length) {
        if (!this.doneLogged) {
          this.doneLogged = true;
          this.logger.log('поисковый индекс почты: весь архив проиндексирован');
        }
        return;
      }
      // Появилось новое неиндексированное письмо (например, архив пополнился вручную) — снова
      // сообщаем о завершении, когда разберём и его.
      this.doneLogged = false;

      let ok = 0;
      let failed = 0;
      await pool(rows, POOL, async (row) => {
        if (await this.indexOne(row.id, S3Service.assetKey(row.rawAsset.sha256))) {
          ok += 1;
          this.attempts.delete(row.id);
        } else {
          failed += 1;
        }
      });

      if (ok === 0 && failed > 0) {
        // Ни одного успеха за порцию — это похоже на отказ хранилища, а не на беду отдельного
        // письма. Попытки не считаем: иначе три подряд недоступности S3 «проиндексировали» бы
        // весь архив пустым текстом.
        this.attempts.clear();
        this.logger.warn(`поисковый индекс почты: ни одно из ${failed} писем не разобрано — похоже, хранилище недоступно, повторю позже`);
        return;
      }

      const left = await this.prisma.mailMessage.count({ where: { searchIndexedAt: null } });
      this.logger.log(`поисковый индекс почты: разобрано ${ok}, не вышло ${failed}, осталось ${left}`);
    } catch (e) {
      // Сюда попадает только отказ самой БД (выборка или счётчик): письма обрабатываются
      // внутри pool, и их ошибки наружу не выходят.
      this.logger.warn(`поисковый индекс почты: проход не удался — ${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  }

  /**
   * Разобрать одно письмо и записать поисковый текст.
   *
   * `true` — письмо отмечено проиндексированным (с текстом или без него). `false` — не вышло,
   * и письмо нужно взять в следующий проход. Разбор идёт из S3, а не из БД: полного тела
   * в строке письма нет, только превью.
   */
  private async indexOne(id: string, key: string): Promise<boolean> {
    try {
      const size = await this.s3.objectSize(key);
      if (size > MAX_PARSE_BYTES) {
        this.logger.warn(
          `поисковый индекс почты: письмо ${id} весит ${Math.round(size / 1024 / 1024)} МБ — больше предела разбора, помечаю без текста`,
        );
        await this.markIndexed(id, '');
        return true;
      }
      const source = await this.s3.getObjectBytes(key, MAX_PARSE_BYTES);
      const parsed = await parseMessage(source);
      await this.markIndexed(id, parsed.searchText);
      return true;
    } catch (e) {
      return this.failAttempt(id, (e as Error).message);
    }
  }

  /**
   * Неудача на письме: считаем попытку и, если их уже MAX_TRIES, помечаем письмо
   * проиндексированным с пустым текстом.
   *
   * Так проход не может встать на одном битом письме: без отметки оно выбиралось бы каждым
   * проходом заново, и весь бэкфилл застрял бы на нём. Поиск по такому письму работать
   * не будет — в логе остаётся строка с причиной, и это честнее молчаливого зависания.
   */
  private async failAttempt(id: string, reason: string): Promise<boolean> {
    const tries = (this.attempts.get(id) ?? 0) + 1;
    this.attempts.set(id, tries);
    if (tries < MAX_TRIES) {
      this.logger.warn(`поисковый индекс почты: письмо ${id} не разобрано (попытка ${tries}/${MAX_TRIES}): ${reason}`);
      return false;
    }
    this.logger.warn(`поисковый индекс почты: письмо ${id} не разобрано за ${MAX_TRIES} попытки — помечаю без текста: ${reason}`);
    this.attempts.delete(id);
    try {
      await this.markIndexed(id, '');
      return true;
    } catch (e) {
      // Записать отметку тоже не вышло (обычно это и есть причина всех бед — БД). Письмо
      // остаётся в очереди; попытки начнутся заново.
      this.logger.warn(`поисковый индекс почты: письмо ${id} не удалось даже пометить — ${(e as Error).message}`);
      return false;
    }
  }

  /** Записать поисковый текст и отметку «проиндексировано». Пустой текст — письмо без индекса. */
  private async markIndexed(id: string, searchText: string): Promise<void> {
    await this.prisma.mailMessage.update({
      where: { id },
      data: { searchText, searchIndexedAt: new Date() },
    });
  }
}

/**
 * Пул на N одновременных задач: письма разбираются независимо, но каждое — это GET в S3
 * и разбор MIME в память, поэтому одновременно их должно быть немного.
 */
async function pool<T>(items: T[], limit: number, run: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const worker = async (): Promise<void> => {
    for (;;) {
      const i = next++;
      if (i >= items.length) return;
      await run(items[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(Math.max(limit, 1), items.length) }, () => worker()));
}
