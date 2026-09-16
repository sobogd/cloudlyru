import { Injectable, Logger } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { AuthService } from '../auth/auth.service';
import { ZONE_PHOTOS } from '../common/zones';
import { parseTzOffsetMin } from '../media/media.service';

/**
 * Лента раздела «Медиа»: свои ручки и свой SQL (в `MediaService` — превью/оригиналы и разбор
 * метаданных, ленты там нет). Показывает всё медиа зоны «Фото» (фото и видео) единым потоком
 * от свежих к старым.
 *
 * Границы раздела задаёт не зона, а строка `MediaMeta`: в ленте ровно то, у чего эта строка
 * есть (её заводит `MediaService.captureAny` для любого `image/*` и `video/*`). PDF и
 * архивы в «Медиа» не попадают вовсе, а BMP/JXL попадают без превью — у них
 * `previewState = 'impossible'`.
 *
 * Галерея ходит по курсору (`feed`): страница — это кадры старше или новее указанной позиции,
 * поэтому прокрутка не зависит от того, что библиотека меняется под руками. Число кадров
 * (`count`) и срез по смещению (`range`) остались для прогрева миниатюр — он идёт по всей
 * библиотеке страницами и нумерует их сам.
 *
 * Пояс: `capturedAt` — истинный UTC-момент, а месяцы для ползунка считаются по поясу клиента
 * (`?tz=` в `/media/months`), иначе фото у границы месяца попадает не в тот бакет.
 */

/** Потолок одного запроса range. */
export const MEDIA_RANGE_MAX = 1000;
/**
 * Потолок одного запроса курсорной ленты (`/media/feed`).
 *
 * Тысяча — как у `range`: страницу такого размера клиент просит только на наполнении
 * локального индекса (`GallerySync`), а при листании берёт 200–300 кадров.
 */
export const MEDIA_FEED_MAX = 1000;
/**
 * Потолок списка id в одном запросе ленты (`?ids=`). Синхронизация клиента присылает сюда
 * пачку правок журнала: больше — уже дешевле перечитать ленту страницами, чем одним
 * `= ANY(...)` на тысячи id.
 */
export const MEDIA_FEED_IDS_MAX = 500;
/**
 * Потолок одного запроса статусов превью. Список сверх него обрезается (об усечении
 * предупреждаем в логе): клиенту, который спрашивает статусы пачками, нужно присылать
 * не больше этого числа id за раз.
 */
export const MEDIA_STATUS_MAX = 500;
/**
 * Потолок точек карты: на кадр приходится одна точка, и они уходят в браузер целиком
 * (тепловой слой считает клиент). 50 000 точек — это ~3 МБ JSON, 400–500 КБ по сети
 * с brotli, и хватает на библиотеку в десятки тысяч геотегированных кадров.
 *
 * Потолок — на всякий случай, а не «бесплатный»: приложение всё равно схлопывает точки
 * в максимум 600 маркеров (`flutter/lib/features/map/map_screen.dart`, `_clusterMax`), то
 * есть на большой библиотеке почти вся эта выдача выбрасывается на клиенте. Серверной
 * кластеризации по зуму/bbox пока нет — это следующий шаг, если карта начнёт тормозить.
 */
export const MEDIA_MAP_MAX = 50_000;

/**
 * Точка на карте: запись с геометкой. Только то, что нужно карте, — ни имени, ни размера,
 * ни даты: миниатюра берётся по `entryId` (`/files/:id/thumb`), а дата и название — из
 * `/media/:entryId`, который запрашивается при открытии кадра. Координаты округлены до
 * пяти знаков (~1 м): лишние знаки только раздувают ответ.
 */
export interface MediaMapPoint {
  entryId: string;
  lat: number;
  lon: number;
}

/** Строка ленты «Медиа». */
export interface MediaItem {
  entryId: string;
  name: string;
  sha256?: string;
  /**
   * Момент съёмки в UTC (ISO). Это истинный момент, а не «время как в файле»: пояс съёмки
   * вычтен (см. `exifInstant`), поэтому печатать цифры строки как местное время нельзя —
   * для этого в ответе есть `tzOffsetMin`. Если даты в файле не было вовсе, здесь дата
   * загрузки или архива: отличить её от настоящей съёмки в контракте нечем.
   */
  capturedAt: string | null;
  mime: string;
  /**
   * 'none' — превью ещё собирается (или задача упала), 'done' — собрано, 'impossible' —
   * собрать нельзя (файл больше лимита, тип не поддержан: причина в `previewError`, который
   * в этот ответ не отдаётся). Разницу важно показывать в UI: иначе «ждём» и «не будет
   * никогда» выглядят одинаково.
   */
  previewState: string;
  /**
   * Состояние задачи конвертации (pending/processing/failed/null). Приложение его пока не
   * читает: иконки «в обработке» в клиенте нет, различать состояния нужно по `previewState`
   * (см. его описание). Поле оставлено в контракте — на него завязан `POST /media/status`.
   */
  jobState: string | null;
  size: number;
  /**
   * Пояс съёмки в минутах на восток от UTC из тегов файла (EXIF OffsetTimeOriginal, у видео —
   * пояс из com.apple.quicktime.creationdate) или null, если в файле его не было. Клиенту:
   * `capturedAt + tzOffsetMin` — «время как в файле», `null` — пояс брать из устройства.
   */
  tzOffsetMin: number | null;
}

/**
 * Позиция кадра в ленте — курсор листания.
 *
 * Лента упорядочена `capturedAt DESC NULLS LAST, id DESC`, и этой же парой адресуется её
 * любая точка: `at` — момент съёмки в UTC (ISO) либо `null` у кадров без даты (они идут
 * последними, «хвостом»), `id` — id записи, который разрывает ничьи по одинаковому моменту
 * и адресует сам хвост.
 */
export interface MediaCursor {
  /** Момент съёмки в UTC (ISO); `null` — курсор в хвосте ленты, у кадров без даты. */
  at: string | null;
  /**
   * id записи в дереве (не хэш): тот же, что `entryId` у кадра. Пустой id означает, что
   * позиция задана только моментом: у курсора без даты это край хвоста («с его начала» для
   * `before` и «к самым старым датированным» для `after`), у датированного — граница момента
   * (строго до/после него, без разрыва ничьих по одинаковому времени съёмки).
   */
  id: string;
}

/** Страница курсорной ленты: кадры в порядке ленты и признак, что за ними есть ещё. */
export interface MediaFeedPage {
  /** Кадры в порядке ленты — от свежих к старым. */
  items: MediaItem[];
  /**
   * Есть ли кадры дальше по направлению запроса: для `before` — старше последнего
   * отданного, для `after` — новее первого. Считается по лишней запрошенной строке,
   * а не по равенству длине страницы.
   */
  hasMore: boolean;
}

/**
 * Метаданные кадра для футера модалки «Медиа» (отдельная ручка /media/:entryId).
 *
 * Параметры съёмки берём из `MediaMeta.raw` — там лежит полный набор тегов: EXIF для фото
 * (диафрагма, выдержка, ISO, фокусное, объектив) и ffprobe для видео (длительность, fps,
 * кодеки). Отдельных колонок под них нет, поэтому поля «плоские» и nullable: у фото пусто
 * в видео-полях и наоборот, а у ассетов, разобранных до появления поля, — вообще везде.
 */
export interface MediaInfo {
  entryId: string;
  name: string;
  mime: string;
  size: number;
  sha256: string;
  capturedAt: string | null;
  width: number | null;
  height: number | null;
  make: string | null;
  model: string | null;
  latitude: number | null;
  longitude: number | null;
  /** Объектив (EXIF LensModel). */
  lens: string | null;
  /** Диафрагма, например 1.8 (показываем как f/1.8). */
  fNumber: number | null;
  /** Выдержка строкой из EXIF: «1/120» или «2.5 с». */
  exposureTime: string | null;
  iso: number | null;
  /** Фокусное расстояние, мм. */
  focalLength: number | null;
  /** Оно же в 35-мм эквиваленте, мм. */
  focalLength35: number | null;
  /** Видео: длительность, кадров в секунду, кодек. */
  durationSec: number | null;
  fps: number | null;
  videoCodec: string | null;
  /**
   * Пояс съёмки в минутах на восток от UTC (см. MediaItem.tzOffsetMin). Нужен, чтобы показать
   * время съёмки «как в файле»: `capturedAt` — уже пересчитанный UTC-момент.
   */
  tzOffsetMin: number | null;
}

/** Число из raw: всё, что не конечное число (включая строки и null), — это «нет данных». */
const rawNum = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);
/** Координата до пяти знаков: точнее метра карте не нужно, а хвост float только раздувает ответ. */
const round5 = (v: number): number => Math.round(v * 1e5) / 1e5;

/** Непустая строка из raw. */
const rawStr = (v: unknown): string | null => (typeof v === 'string' && v.trim() ? v : null);

/** Сырые строки запросов: Postgres отдаёт timestamptz как Date, bigint как BigInt. */
interface MediaRow {
  id: string;
  name: string;
  sha256: string | null;
  mime: string;
  previewState: string;
  jobState: string | null;
  size: bigint | number | null;
  capturedAt: Date | null;
  /** Значения из `MediaMeta.raw`, нужные только для пояса съёмки (см. parseTzOffsetMin). */
  rawOffsetTime: string | null;
  rawCreatedAt: string | null;
}

@Injectable()
export class MediaFeedService {
  private readonly logger = new Logger(MediaFeedService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
  ) {}

  /**
   * Все геометки ленты для вкладки «Карта»: по точке на кадр.
   *
   * Отдаём минимум полей: имена, размеры и sha256 карте не нужны — миниатюра берётся по
   * `entryId` (`/files/:id/thumb`), а детали кадра подтягиваются при открытии. Потолок —
   * MEDIA_MAP_MAX: `total` и `truncated` показывают, влезла ли библиотека целиком.
   *
   * Порядок точек — тот же, что у ленты (`capturedAt DESC NULLS LAST`, затем id), но индекс
   * точки НЕ равен индексу кадра в `/media/range`: здесь остаются только кадры с собранным
   * превью и с координатами, в ленте — все. Привязываться к этим индексам можно только внутри
   * массива точек.
   *
   * `total` считаем отдельным `count(*)`, а не оконной функцией в том же запросе: оконная
   * считается до `LIMIT`, то есть заставляет Postgres прочитать и отсортировать все гео-строки
   * пользователя ради числа, которое и так даёт дешёвый count.
   */
  async mapPoints(userId: string): Promise<{ total: number; truncated: boolean; points: MediaMapPoint[] }> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return { total: 0, truncated: false, points: [] };
    const where = Prisma.sql`
      FROM "MediaMeta" mm
      JOIN "Asset" a ON a."id" = mm."assetId"
      JOIN "FileEntry" f ON f."assetId" = a."id"
      WHERE f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
        -- Только кадры с собранным превью: на карте точка — это миниатюра, а тап открывает
        -- кадр. Без превью и то и другое мертво (миниатюра 404, просмотрщик — «не открылось»);
        -- в ленте такие кадры и так помечены как «Превью не собрано».
        AND a."previewState" = 'done'
        AND mm."latitude" IS NOT NULL
        AND mm."longitude" IS NOT NULL
    `;
    const [rows, totals] = await Promise.all([
      this.prisma.$queryRaw<Array<{ id: string; lat: number; lon: number }>>(Prisma.sql`
        SELECT f."id", mm."latitude" AS lat, mm."longitude" AS lon
        ${where}
        ORDER BY mm."capturedAt" DESC NULLS LAST, f."id" DESC
        LIMIT ${MEDIA_MAP_MAX}
      `),
      this.prisma.$queryRaw<Array<{ n: bigint | number }>>(Prisma.sql`
        SELECT count(*) AS n
        ${where}
      `),
    ]);
    const total = Number(totals[0]?.n ?? 0);
    return {
      total,
      truncated: total > rows.length,
      points: rows.map((r) => ({
        entryId: r.id,
        lat: round5(Number(r.lat)),
        lon: round5(Number(r.lon)),
      })),
    };
  }

  /** Общее число медиа зоны «Фото» — по нему клиент считает высоту скролла. */
  async count(userId: string): Promise<number> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return 0;
    const rows = await this.prisma.$queryRaw<Array<{ n: bigint | number }>>(Prisma.sql`
      SELECT count(*) AS n
      FROM "MediaMeta" mm
      JOIN "Asset" a ON a."id" = mm."assetId"
      JOIN "FileEntry" f ON f."assetId" = a."id"
      WHERE f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
    `);
    return Number(rows[0]?.n ?? 0);
  }

  /**
   * Срез ленты по абсолютному смещению: элементы [offset, offset+limit) в порядке ленты.
   *
   * Смещение умеет прыгнуть в любую точку (в отличие от keyset-курсора), и этим пользуется
   * прогрев миниатюр: он идёт по всей библиотеке страницами и нумерует их сам
   * (`ThumbCache.warmLibrary`). Листание галереи ходит в [feed] — там адресом кадра служит
   * его позиция в ленте, а не номер.
   *
   * Осторожно: смещение абсолютное и снимка состояния нет. Загрузка или удаление между
   * запросами сдвигает индексы, поэтому клиент, привязанный к номеру, может увидеть дубль
   * или пропуск.
   */
  async range(userId: string, offset = 0, limit = 300): Promise<MediaItem[]> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return [];
    const take = Math.min(Math.max(limit, 1), MEDIA_RANGE_MAX);
    const skip = Math.max(0, Math.floor(offset));
    const rows = await this.prisma.$queryRaw<MediaRow[]>(Prisma.sql`
      ${MediaFeedService.columns}
      ${MediaFeedService.scope(tree)}
      ORDER BY mm."capturedAt" DESC NULLS LAST, f."id" DESC
      LIMIT ${take} OFFSET ${skip}
    `);
    return rows.map(MediaFeedService.mapRow);
  }

  /**
   * Срез ленты по курсору: кадры старше (`before`) или новее (`after`) указанной позиции.
   *
   * Зачем это вместо смещения ([range]): номер кадра — не адрес. Библиотека живая (приложение
   * само выгружает фото с телефона), поэтому за время между двумя запросами состав ленты
   * меняется, и по номеру на уже показанном месте оказывается чужой кадр. Курсор
   * `(capturedAt, id)` указывает на сам кадр, и сдвиг ленты вокруг него ничего не ломает.
   *
   * Направления:
   *  • `before` — кадры СТАРШЕ курсора (листание в прошлое). Курсор с `at = null` адресует
   *    хвост ленты — кадры без даты съёмки, которые идут после всех датированных; датированный
   *    курсор хвост не захватывает, поэтому клиент дочитывает его отдельной страницей.
   *    Пустой `id` у датированного курсора — граница момента: строго до него, без разрыва
   *    ничьих (так клиент прыгает к месяцу, не зная id его первого кадра);
   *  • `after` — кадры НОВЕЕ курсора (листание к свежему). Курсор без даты означает «новее
   *    хвоста без даты»: с непустым id — остаток самого хвоста, с пустым — самые старые
   *    датированные кадры (они и примыкают к хвосту снизу);
   *  • `ids` — конкретные записи (`?ids=a,b,c`), без курсора: так синхронизация клиента
   *    забирает изменившееся по журналу одним запросом вместо запроса на кадр.
   *
   * Порядок кадров в ответе всегда ленты (свежие → старые), независимо от направления запроса:
   * клиент раскладывает страницу по своему окну, и разворачивать её ему незачем.
   */
  async feed(
    userId: string,
    opts: { before?: MediaCursor | null; after?: MediaCursor | null; ids?: string[]; limit?: number },
  ): Promise<MediaFeedPage> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return { items: [], hasMore: false };
    const take = Math.min(Math.max(Math.floor(opts.limit ?? 200), 1), MEDIA_FEED_MAX);

    // Конкретные записи: порядок как у ленты, продолжения у такой страницы не бывает.
    if (opts.ids && opts.ids.length) {
      const ids = [...new Set(opts.ids)].slice(0, MEDIA_FEED_IDS_MAX);
      const rows = await this.prisma.$queryRaw<MediaRow[]>(Prisma.sql`
        ${MediaFeedService.columns}
        ${MediaFeedService.scope(tree)}
          AND f."id" = ANY(${ids})
        ORDER BY mm."capturedAt" DESC NULLS LAST, f."id" DESC
      `);
      return { items: rows.map(MediaFeedService.mapRow), hasMore: false };
    }

    // Лишняя строка сверх страницы: только так видно, есть ли продолжение. Сравнивать длину
    // страницы с `limit` нельзя — ровно полная страница не значит, что за ней что-то есть.
    const probe = take + 1;

    if (opts.before !== undefined) {
      const c = opts.before;
      // `at` каста в timestamp без зоны: колонка `capturedAt` хранит UTC без зоны, а литерал
      // со смещением Postgres сначала приводит к timestamptz — и без `AT TIME ZONE 'UTC'`
      // результат зависел бы от пояса сессии.
      const rows = c && c.at
        ? await this.prisma.$queryRaw<MediaRow[]>(Prisma.sql`
            ${MediaFeedService.columns}
            ${MediaFeedService.scope(tree)}
              AND (mm."capturedAt" < (${c.at}::timestamptz AT TIME ZONE 'UTC')
                   ${c.id
                     ? Prisma.sql`OR (mm."capturedAt" = (${c.at}::timestamptz AT TIME ZONE 'UTC') AND f."id" < ${c.id})`
                     : Prisma.empty})
            ORDER BY mm."capturedAt" DESC NULLS LAST, f."id" DESC
            LIMIT ${probe}
          `)
        // Хвост без даты: он идёт после всех датированных кадров, поэтому и курсор у него свой
        // (`at = null`). Пустой `id` — начало хвоста (самый свежий его кадр).
        : await this.prisma.$queryRaw<MediaRow[]>(Prisma.sql`
            ${MediaFeedService.columns}
            ${MediaFeedService.scope(tree)}
              AND mm."capturedAt" IS NULL
              ${c && c.id ? Prisma.sql`AND f."id" < ${c.id}` : Prisma.empty}
            ORDER BY f."id" DESC
            LIMIT ${probe}
          `);
      return { items: rows.slice(0, take).map(MediaFeedService.mapRow), hasMore: rows.length > take };
    }

    if (opts.after !== undefined) {
      const c = opts.after;
      if (c && c.at) {
        // ASC — чтобы взять именно примыкающие к окну кадры, а не начало ленты; в порядок
        // ленты страница разворачивается ниже.
        const rows = await this.prisma.$queryRaw<MediaRow[]>(Prisma.sql`
          ${MediaFeedService.columns}
          ${MediaFeedService.scope(tree)}
            AND mm."capturedAt" IS NOT NULL
            AND (mm."capturedAt" > (${c.at}::timestamptz AT TIME ZONE 'UTC')
                 ${c.id
                   ? Prisma.sql`OR (mm."capturedAt" = (${c.at}::timestamptz AT TIME ZONE 'UTC') AND f."id" > ${c.id})`
                   : Prisma.empty})
          ORDER BY mm."capturedAt" ASC, f."id" ASC
          LIMIT ${probe}
        `);
        const page = rows.slice(0, take).reverse();
        return { items: page.map(MediaFeedService.mapRow), hasMore: rows.length > take };
      }
      // Курсор без даты: новее него идёт либо остаток хвоста (когда id назван), либо вся
      // датированная часть ленты. Во втором случае берём САМЫЕ СТАРЫЕ кадры — они и примыкают
      // к хвосту снизу; клиент, поднимающийся от хвоста вверх, ждёт именно их.
      const rows = c && c.id
        ? await this.prisma.$queryRaw<MediaRow[]>(Prisma.sql`
            ${MediaFeedService.columns}
            ${MediaFeedService.scope(tree)}
              AND mm."capturedAt" IS NULL
              AND f."id" > ${c.id}
            ORDER BY f."id" ASC
            LIMIT ${probe}
          `)
        : await this.prisma.$queryRaw<MediaRow[]>(Prisma.sql`
            ${MediaFeedService.columns}
            ${MediaFeedService.scope(tree)}
              AND mm."capturedAt" IS NOT NULL
            ORDER BY mm."capturedAt" ASC, f."id" ASC
            LIMIT ${probe}
          `);
      const page = rows.slice(0, take).reverse();
      return { items: page.map(MediaFeedService.mapRow), hasMore: rows.length > take };
    }

    // Ни одного курсора — начало ленты: самые свежие кадры (вместе с хвостом без даты, если
    // датированных меньше страницы).
    const rows = await this.prisma.$queryRaw<MediaRow[]>(Prisma.sql`
      ${MediaFeedService.columns}
      ${MediaFeedService.scope(tree)}
      ORDER BY mm."capturedAt" DESC NULLS LAST, f."id" DESC
      LIMIT ${probe}
    `);
    return { items: rows.slice(0, take).map(MediaFeedService.mapRow), hasMore: rows.length > take };
  }

  /**
   * Колонки строки ленты: ровно те, из которых собирается `MediaItem` (см. `MediaRow`).
   *
   * Общий кусок для `range` и `feed`: разъехавшись, они отдавали бы разные наборы полей,
   * и клиент получал бы то без пояса съёмки, то без состояния задачи.
   */
  private static readonly columns = Prisma.sql`
    SELECT f."id", f."name", a."sha256", a."mime", a."previewState", a."size", mm."capturedAt",
           j."state" AS "jobState",
           -- Пояс съёмки: у фото он в EXIF, у видео — в дате из Apple Keys. Достаём только
           -- эти два ключа, а не весь raw: строк в ответе до 1000.
           mm."raw"->>'offsetTime' AS "rawOffsetTime",
           mm."raw"->>'createdAt' AS "rawCreatedAt"
  `;

  /**
   * Таблицы и условия, одинаковые у всех запросов ленты: живые записи зоны «Фото» в поддереве
   * пользователя. Запрос дописывает к этому свои `AND` и `ORDER BY`.
   */
  private static scope(tree: string[]) {
    return Prisma.sql`
      FROM "MediaMeta" mm
      JOIN "Asset" a ON a."id" = mm."assetId"
      JOIN "FileEntry" f ON f."assetId" = a."id"
      LEFT JOIN LATERAL (
        SELECT "state" FROM "Job" WHERE "assetId" = a."id" ORDER BY "createdAt" DESC LIMIT 1
      ) j ON TRUE
      WHERE f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
    `;
  }

  /**
   * Индекс по месяцам для подписи у ползунка: строка на месяц (в порядке ленты, от свежих),
   * плюс «хвост» без даты съёмки (month = null) — он в ленте идёт самым последним. Кумулятивным
   * счётчиком клиент сопоставляет позицию скролла с точным месяцем/годом без загрузки самих фото.
   *
   * Пояс: `capturedAt` — UTC-момент (`TIMESTAMP(3)` без зоны, Prisma пишет туда UTC), а месяц
   * пользователь видит в своём поясе. Кадр, снятый 01.01 в 01:30 +03:00 (= 31.12 22:30Z),
   * без поправки попадал в бакет «2023-12», хотя в просмотрщике дата 01.01. Поэтому клиент
   * передаёт свой сдвиг в минутах на восток (`?tz=`), и бакеты считаются `capturedAt + tz`.
   * Без параметра считаем в UTC — как было раньше. Пояс сессии Postgres на результат не влияет:
   * колонка без зоны, а `to_char` над `timestamp` зону не применяет (проверено).
   *
   * Один проход вместо двух: строки без даты дают ту же группировку с month = null, отдельный
   * UNION ALL по тем же трём таблицам был вторым полным проходом на каждое открытие раздела.
   */
  async months(userId: string, tzOffsetMin = 0): Promise<Array<{ month: string | null; count: number }>> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return [];
    const tz = Number.isFinite(tzOffsetMin) ? Math.max(-840, Math.min(840, Math.trunc(tzOffsetMin))) : 0;
    const rows = await this.prisma.$queryRaw<Array<{ month: string | null; n: bigint | number }>>(Prisma.sql`
      SELECT to_char(mm."capturedAt" + make_interval(mins => ${tz}::int), 'YYYY-MM') AS month,
             count(*) AS n
      FROM "MediaMeta" mm
      JOIN "Asset" a ON a."id" = mm."assetId"
      JOIN "FileEntry" f ON f."assetId" = a."id"
      WHERE f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
      GROUP BY 1
      ORDER BY month DESC NULLS LAST
    `);
    return rows.map((r) => ({ month: r.month, count: Number(r.n) }));
  }

  /** Метаданные кадра для футера модалки. Чужое/удалённое/вне зоны «Фото» — null (404). */
  async info(userId: string, entryId: string): Promise<MediaInfo | null> {
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return null;
    const row = await this.prisma.fileEntry.findFirst({
      where: { id: entryId, deletedAt: null, zone: ZONE_PHOTOS, folderId: { in: tree } },
      select: {
        id: true,
        name: true,
        asset: {
          select: {
            sha256: true,
            mime: true,
            size: true,
            media: {
              select: {
                capturedAt: true,
                width: true,
                height: true,
                make: true,
                model: true,
                latitude: true,
                longitude: true,
                raw: true,
              },
            },
          },
        },
      },
    });
    if (!row) return null;
    const raw = (row.asset.media?.raw ?? null) as Record<string, unknown> | null;
    return {
      entryId: row.id,
      name: row.name,
      mime: row.asset.mime,
      size: Number(row.asset.size),
      sha256: row.asset.sha256,
      capturedAt: row.asset.media?.capturedAt ? new Date(row.asset.media.capturedAt).toISOString() : null,
      width: row.asset.media?.width ?? null,
      height: row.asset.media?.height ?? null,
      make: row.asset.media?.make ?? null,
      model: row.asset.media?.model ?? null,
      latitude: row.asset.media?.latitude ?? null,
      longitude: row.asset.media?.longitude ?? null,
      lens: rawStr(raw?.lens),
      fNumber: rawNum(raw?.fNumber),
      exposureTime: rawStr(raw?.exposureTime),
      iso: rawNum(raw?.iso),
      focalLength: rawNum(raw?.focalLength),
      focalLength35: rawNum(raw?.focalLength35),
      durationSec: rawNum(raw?.durationSec),
      fps: rawNum(raw?.fps),
      videoCodec: rawStr(raw?.videoCodec),
      // Фото: пояс съёмки в EXIF; видео: в дате из Apple Keys (`creation_time` пояса не знает).
      tzOffsetMin: parseTzOffsetMin(raw?.offsetTime) ?? parseTzOffsetMin(raw?.createdAt),
    };
  }

  private static mapRow(r: MediaRow): MediaItem {
    return {
      entryId: r.id,
      name: r.name,
      sha256: r.sha256 ?? undefined,
      capturedAt: r.capturedAt ? new Date(r.capturedAt).toISOString() : null,
      mime: r.mime,
      previewState: r.previewState,
      jobState: r.jobState ?? null,
      size: Number(r.size ?? 0),
      tzOffsetMin: parseTzOffsetMin(r.rawOffsetTime) ?? parseTzOffsetMin(r.rawCreatedAt),
    };
  }

  /**
   * Статусы превью по списку записей — клиент переспрашивает только неготовые снимки.
   *
   * Ручка живёт для этого сценария, но приложение её пока не зовёт (модель `MediaStatusItem`
   * и обёртка `CloudlyApi.mediaStatus` лежат в клиенте мёртвым кодом): «в обработке» в UI
   * различается по `previewState` в самой ленте. Список длиннее MEDIA_STATUS_MAX обрезается —
   * об этом предупреждаем в логе, в ответе признака усечения нет (контракт — массив).
   */
  async status(userId: string, entryIds: unknown): Promise<Array<{ entryId: string; previewState: string; jobState: string | null }>> {
    const all = [...new Set(Array.isArray(entryIds) ? entryIds : [])]
      .filter((id): id is string => typeof id === 'string' && id.length > 0);
    const ids = all.slice(0, MEDIA_STATUS_MAX);
    if (all.length > ids.length) {
      this.logger.warn(`/media/status: запрошено ${all.length} id, обрабатываем первые ${MEDIA_STATUS_MAX}`);
    }
    if (!ids.length) return [];
    const tree = await this.auth.subtreeIds(userId);
    if (!tree.length) return [];
    const rows = await this.prisma.$queryRaw<Array<{ id: string; previewState: string; jobState: string | null }>>(Prisma.sql`
      SELECT f."id", a."previewState", j."state" AS "jobState"
      FROM "FileEntry" f
      JOIN "Asset" a ON a."id" = f."assetId"
      LEFT JOIN LATERAL (
        SELECT "state" FROM "Job" WHERE "assetId" = a."id" ORDER BY "createdAt" DESC LIMIT 1
      ) j ON TRUE
      WHERE f."id" = ANY(${ids})
        AND f."deletedAt" IS NULL
        AND f."zone" = ${ZONE_PHOTOS}
        AND f."folderId" = ANY(${tree})
    `);
    return rows.map((r) => ({ entryId: r.id, previewState: r.previewState, jobState: r.jobState ?? null }));
  }
}
