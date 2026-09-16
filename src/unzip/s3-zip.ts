import { createHash } from 'crypto';
import { createInflateRaw } from 'zlib';
import { Readable, Transform } from 'stream';

/**
 * Чтение ZIP-архива, лежащего в S3, без скачивания на диск.
 *
 * ZIP-структура читается по HTTP Range-запросам к объекту:
 *   End of Central Directory (в конце файла) → ZIP64-локатор (если есть) →
 *   центральный каталог (имена, размеры, смещения) → по каждому файлу
 *   локальный заголовок + сжатые данные инкрементально.
 *
 * Так распаковывается 53-гигабайтный архив на VPS с 5 ГБ свободного диска.
 */

/** Минимальный интерфейс источника: размер и чтение диапазона байт. */
export interface RangeSource {
  size(): number;
  readRange(start: number, endInclusive: number): Promise<Buffer>;
}

/**
 * Архив как контейнер нечитаем: нет EOCD, битый центральный каталог, превышен потолок числа
 * записей. Повторять такую задачу бессмысленно — вызывающий помечает её failed сразу.
 */
export class ZipFormatError extends Error {}

/**
 * Не читается отдельный член архива: метод сжатия не поддержан (AES/Zip64-сжатие), не сошёлся
 * CRC32 или размер. Остальные члены архива при этом читаются, поэтому такой член надо
 * пропускать, а не валить всю задачу (см. обработку в unzip.service.ts).
 */
export class ZipEntryError extends Error {}

/** Предохранители чтения. Значения задаёт вызывающий (см. src/unzip/unzip.limits.ts). */
export interface RemoteZipLimits {
  /**
   * Потолок числа записей центрального каталога. Размер каталога называет сам архив:
   * `totalEntries` берётся из EOCD/ZIP64 (в ZIP64 — до 2^64) и ограничен только размером
   * файла, то есть 5-гигабайтный архив с каталогом из минимальных 46-байтовых записей даёт
   * десятки миллионов объектов и OOM ещё до распаковки. Суммарный распакованный объём,
   * коэффициент сжатия и глубину путей проверяет вызывающий — здесь только каталог.
   */
  maxEntries?: number;
}

export interface ZipEntryInfo {
  name: string;
  /** 0 = stored, 8 = deflate */
  method: number;
  crc32: number;
  compressedSize: number;
  uncompressedSize: number;
  localHeaderOffset: number;
  isDirectory: boolean;
  /**
   * Время изменения файла из архива (DOS-дата/время или extended timestamp). Это НЕ дата
   * съёмки: Google Takeout кладёт сюда время упаковки архива, поэтому для Takeout-выгрузок
   * дата берётся из сайдкара, а DOS-дата используется только для обычных архивов
   * (см. `isTakeout ? null : e.lastModified` в unzip.service.ts).
   */
  lastModified: Date | null;
}

/**
 * Время из полей DOS (2 байта даты, 2 байта времени) — формат ZIP по умолчанию.
 * Секунды хранятся с точностью до двух, год — со смещением от 1980.
 */
function dosDateTime(dateRaw: number, timeRaw: number): Date | null {
  if (dateRaw === 0) return null;
  const day = dateRaw & 0x1f;
  const month = (dateRaw >> 5) & 0x0f;
  const year = 1980 + ((dateRaw >> 9) & 0x7f);
  const seconds = (timeRaw & 0x1f) * 2;
  const minutes = (timeRaw >> 5) & 0x3f;
  const hours = (timeRaw >> 11) & 0x1f;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  // дата в архиве — локальная для того, кто упаковывал; читаем как UTC, чтобы не сдвигать
  const ms = Date.UTC(year, month - 1, day, hours, minutes, seconds);
  return Number.isFinite(ms) ? new Date(ms) : null;
}

/** Дополнительное поле 0x5455 (extended timestamp): unix-время, если упаковщик его положил. */
function unixTimeFromExtra(extra: Buffer): Date | null {
  let e = 0;
  while (e + 4 <= extra.length) {
    const id = extra.readUInt16LE(e);
    const len = extra.readUInt16LE(e + 2);
    if (id === 0x5455 && len >= 5) {
      const flags = extra.readUInt8(e + 4);
      if (flags & 0x1 && len >= 9) return new Date(extra.readUInt32LE(e + 5) * 1000);
    }
    e += 4 + len;
  }
  return null;
}

/**
 * Ключ сопоставления файла с сайдкаром. Google в выгрузках добавляет маркеры дублей
 * (`IMG_1234.HEIC`, `IMG_1234 (2).HEIC`, `20220828_162655~4.mp4`) и суффиксы к самому
 * сайдкару (`.supplemental-metadata(29).json`), поэтому сравнивать имена как есть нельзя.
 */
export function mediaKey(name: string): string {
  const base = name.slice(name.lastIndexOf('/') + 1);
  return base
    .replace(/\.supplemental-metadata(\(\d+\))?\.json$/i, '')
    .replace(/\.json$/i, '')
    .replace(/~(?:copy )?\d+(?=\.[^.]+$)/i, '')
    .replace(/[ _-](?:edited|copy)(?=\.[^.]+$)/i, '')
    .replace(/ ?\(\d+\)(?=\.[^.]+$)/, '')
    .toLowerCase();
}

const SIG_EOCD = 0x06054b50;
const SIG_EOCD64 = 0x06064b50;
const SIG_EOCD64_LOCATOR = 0x07064b50;
const SIG_CENTRAL = 0x02014b50;
const SIG_LOCAL = 0x04034b50;

const READ_CHUNK = 4 * 1024 * 1024;

// ---- CRC32 (для самопроверки распакованных данных) ----
let crcTable: Uint32Array | null = null;
function crcTableOf(): Uint32Array {
  if (crcTable) return crcTable;
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c >>> 0;
  }
  crcTable = t;
  return t;
}

export function crc32(buf: Buffer, seed = 0): number {
  const t = crcTableOf();
  let c = (seed ^ 0xffffffff) >>> 0;
  for (let i = 0; i < buf.length; i++) c = t[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export class RemoteZip {
  private readonly blockSize = 8 * 1024 * 1024;
  private cache: { start: number; data: Buffer } | null = null;
  private readonly maxEntries: number;

  constructor(
    private readonly src: RangeSource,
    limits: RemoteZipLimits = {},
  ) {
    // потолок по умолчанию нужен и самому читателю: без него `entries()` — открытая дверь
    // для мусорного каталога (см. RemoteZipLimits.maxEntries)
    this.maxEntries = limits.maxEntries ?? 20_000;
  }

  /** Последовательное чтение с буфером на blockSize: одна S3-операция на блок. */
  private async readAt(pos: number, len: number): Promise<Buffer> {
    if (this.cache && pos >= this.cache.start && pos + len <= this.cache.start + this.cache.data.length) {
      const rel = pos - this.cache.start;
      return this.cache.data.subarray(rel, rel + len);
    }
    const size = this.src.size();
    if (pos + len > size) throw new Error(`чтение за границей файла: ${pos}+${len} > ${size}`);
    const end = Math.min(size - 1, pos + Math.max(len, this.blockSize) - 1);
    const data = await this.src.readRange(pos, end);
    this.cache = { start: pos, data };
    return data.subarray(0, len);
  }

  /** Список файлов архива (из центрального каталога). */
  async entries(): Promise<ZipEntryInfo[]> {
    const size = this.src.size();
    const tailLen = Math.min(size, 66_000);
    const tail = await this.src.readRange(size - tailLen, size - 1);

    let eocd = -1;
    for (let i = tail.length - 22; i >= 0; i--) {
      if (tail.readUInt32LE(i) === SIG_EOCD) {
        const commentLen = tail.readUInt16LE(i + 20);
        if (i + 22 + commentLen === tail.length) { eocd = i; break; }
      }
    }
    if (eocd < 0) throw new ZipFormatError('EOCD не найден — это не ZIP или файл обрезан');

    let totalEntries = tail.readUInt16LE(eocd + 10);
    let cdSize = tail.readUInt32LE(eocd + 12);
    let cdOffset = tail.readUInt32LE(eocd + 16);

    // ZIP64: заглушки → настоящие значения в ZIP64 EOCD
    if (totalEntries === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) {
      let locator = -1;
      for (let i = eocd - 20; i >= 0; i--) {
        if (tail.readUInt32LE(i) === SIG_EOCD64_LOCATOR) { locator = i; break; }
      }
      if (locator < 0) throw new ZipFormatError('ZIP64 locator не найден');
      const z64Offset = Number(tail.readBigUInt64LE(locator + 8));
      const z64 = await this.src.readRange(z64Offset, z64Offset + 55);
      if (z64.readUInt32LE(0) !== SIG_EOCD64) throw new ZipFormatError('ZIP64 EOCD повреждён');
      totalEntries = Number(z64.readBigUInt64LE(32));
      cdSize = Number(z64.readBigUInt64LE(40));
      cdOffset = Number(z64.readBigUInt64LE(48));
    }

    // каталог целиком внутри файла? иначе дальше пошли бы Range-запросы за границей объекта
    if (cdOffset + cdSize > size) {
      throw new ZipFormatError(`центральный каталог выходит за границы файла (${cdOffset}+${cdSize} > ${size})`);
    }
    // потолок проверяем ДО разбора каталога: он и защищает от «миллионов записей»
    if (totalEntries > this.maxEntries) {
      throw new ZipFormatError(`в архиве ${totalEntries} записей — больше потолка ${this.maxEntries}`);
    }

    const out: ZipEntryInfo[] = [];
    let pos = cdOffset;
    const cdEnd = cdOffset + cdSize;
    let block: Buffer = Buffer.alloc(0);
    let blockStart = 0;

    const ensure = async (need: number): Promise<Buffer> => {
      if (block.length && pos + need <= blockStart + block.length) return block;
      const end = Math.min(this.src.size() - 1, pos + Math.max(need, this.blockSize) - 1);
      block = await this.src.readRange(pos, end);
      blockStart = pos;
      return block;
    };

    while (pos < cdEnd && out.length < totalEntries) {
      await ensure(46);
      let off = pos - blockStart;
      if (block.readUInt32LE(off) !== SIG_CENTRAL) throw new ZipFormatError(`центральный каталог повреждён на ${pos}`);

      const method = block.readUInt16LE(off + 10);
      const crc = block.readUInt32LE(off + 16);
      const compressedSize32 = block.readUInt32LE(off + 20);
      const uncompressedSize32 = block.readUInt32LE(off + 24);
      const nameLen = block.readUInt16LE(off + 28);
      const extraLen = block.readUInt16LE(off + 30);
      const commentLen = block.readUInt16LE(off + 32);
      const localOffset32 = block.readUInt32LE(off + 42);
      const dosTime = block.readUInt16LE(off + 12);
      const dosDate = block.readUInt16LE(off + 14);

      await ensure(46 + nameLen + extraLen + commentLen);
      off = pos - blockStart;
      const name = block.subarray(off + 46, off + 46 + nameLen).toString('utf8');
      const extra = block.subarray(off + 46 + nameLen, off + 46 + nameLen + extraLen);

      let compressedSize = compressedSize32;
      let uncompressedSize = uncompressedSize32;
      let localHeaderOffset = localOffset32;

      // ZIP64 extra (0x0001): значения в порядке объявленных заглушек
      if (compressedSize32 === 0xffffffff || uncompressedSize32 === 0xffffffff || localOffset32 === 0xffffffff) {
        let e = 0;
        while (e + 4 <= extra.length) {
          const id = extra.readUInt16LE(e);
          const len = extra.readUInt16LE(e + 2);
          if (id === 0x0001) {
            let p = e + 4;
            if (uncompressedSize32 === 0xffffffff) { uncompressedSize = Number(extra.readBigUInt64LE(p)); p += 8; }
            if (compressedSize32 === 0xffffffff) { compressedSize = Number(extra.readBigUInt64LE(p)); p += 8; }
            if (localOffset32 === 0xffffffff) { localHeaderOffset = Number(extra.readBigUInt64LE(p)); p += 8; }
            break;
          }
          e += 4 + len;
        }
      }

      out.push({
        name,
        method,
        crc32: crc,
        compressedSize,
        uncompressedSize,
        localHeaderOffset,
        isDirectory: name.endsWith('/'),
        lastModified: unixTimeFromExtra(extra) ?? dosDateTime(dosDate, dosTime),
      });
      pos += 46 + nameLen + extraLen + commentLen;
    }

    return out;
  }

  /**
   * Сжатые байты файла как поток (с backpressure).
   * ВАЖНО: читаем через readAt (кэш на 8 МБ), а не напрямую в S3 — файлы в
   * архиве лежат подряд, поэтому один Range-запрос обслуживает десятки мелких
   * файлов. Без кэша на каждый файл уходило 2 запроса (заголовок + данные),
   * и распаковка упиралась в latency S3 (~270 файлов/мин).
   */
  private async *compressedChunks(entry: ZipEntryInfo): AsyncGenerator<Buffer> {
    const lh = await this.readAt(entry.localHeaderOffset, 30);
    if (lh.readUInt32LE(0) !== SIG_LOCAL) throw new ZipFormatError(`локальный заголовок повреждён: ${entry.name}`);
    const nameLen = lh.readUInt16LE(26);
    const extraLen = lh.readUInt16LE(28);
    const dataStart = entry.localHeaderOffset + 30 + nameLen + extraLen;

    let read = 0;
    while (read < entry.compressedSize) {
      const len = Math.min(READ_CHUNK, entry.compressedSize - read);
      const buf = await this.readAt(dataStart + read, len);
      read += buf.length;
      yield buf;
    }
  }

  /**
   * Распакованное содержимое файла как поток.
   * Неподдержанный метод сжатия — ошибка ОДНОГО члена (ZipEntryError): AES-шифрованные
   * записи и Deflate64 распространены в чужих архивах, и валить из-за них всю задачу нельзя.
   */
  readEntryStream(entry: ZipEntryInfo): Readable {
    const source = Readable.from(this.compressedChunks(entry));
    if (entry.method === 0) return source;
    if (entry.method === 8) {
      const inflater = createInflateRaw();
      source.on('error', (e) => inflater.destroy(e));
      source.pipe(inflater);
      return inflater;
    }
    throw new ZipEntryError(`метод сжатия ${entry.method} не поддерживается (${entry.name})`);
  }

  /** Полностью распаковать файл в память (для небольших файлов + самопроверки CRC). */
  async readEntryBuffer(entry: ZipEntryInfo): Promise<Buffer> {
    const chunks: Buffer[] = [];
    for await (const c of this.readEntryStream(entry)) chunks.push(Buffer.from(c));
    const buf = Buffer.concat(chunks);
    if (entry.uncompressedSize && buf.length !== entry.uncompressedSize) {
      throw new ZipEntryError(`${entry.name}: размер ${buf.length} ≠ ожидаемого ${entry.uncompressedSize}`);
    }
    if (entry.crc32 && crc32(buf) !== entry.crc32) throw new ZipEntryError(`${entry.name}: CRC32 не совпал`);
    return buf;
  }
}

/**
 * Трансформ: считает sha256, размер и CRC32 на лету, пропуская данные дальше.
 * Нужен, чтобы заливать крупный член архива в S3 одним проходом: ключ объекта
 * content-addressed, поэтому хэш узнаётся уже после загрузки (заливка идёт во временный
 * ключ, см. unzip.service.ts), а `crc32` сверяется с центральным каталогом.
 */
export function hashTee(): {
  transform: Transform;
  result: () => { sha256: string; size: number; crc32: number };
} {
  const hash = createHash('sha256');
  let size = 0;
  let sum = 0;
  const transform = new Transform({
    transform(chunk, _enc, cb) {
      hash.update(chunk);
      sum = crc32(chunk, sum);
      size += chunk.length;
      cb(null, chunk);
    },
  });
  return { transform, result: () => ({ sha256: hash.digest('hex'), size, crc32: sum }) };
}
