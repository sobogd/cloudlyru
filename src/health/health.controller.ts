import { Controller, Get, Logger, OnModuleInit } from '@nestjs/common';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { PrismaService } from '../prisma/prisma.service';
import { Public } from '../common/decorators';

const execFileAsync = promisify(execFile);

/** Бинари, без которых конвертация медиа молча не работает. */
const MEDIA_BINS = ['ffmpeg', 'ffprobe', 'heif-convert', 'pdfinfo', 'pdftoppm'] as const;
const TOOLCHECK_TTL_MS = 10 * 60 * 1000;
const BIN_TIMEOUT_MS = 5000;

interface Toolchain {
  ok: boolean;
  missing: string[];
  version: string | null;
}

@Controller()
export class HealthController implements OnModuleInit {
  private readonly logger = new Logger(HealthController.name);
  private tools: (Toolchain & { at: number }) | null = null;
  /** Проверка уже идёт: второй параллельный запуск не нужен (healthz могут дёрнуть несколько раз). */
  private checking = false;

  constructor(private readonly prisma: PrismaService) {}

  // Прогреваем кэш сразу на старте, но в фоне: сам старт сервиса ждать проверку не должен.
  onModuleInit(): void {
    void this.refreshToolchain();
  }

  /**
   * Живость сервиса: процесс отвечает и БД доступна. `ok: true` — это именно про процесс и БД:
   * результат проверки тулчейна лежит отдельным полем `media`, потому что «процесс жив» и
   * «конвертация работает» — разные вещи (пауза очереди, недоступный S3 и неразбираемый файл
   * по-прежнему здесь не видны). Наружу не отдаём ни версии бинарей, ни их список: это карта
   * окружения, которую незачем показывать без авторизации — подробности идут в лог.
   */
  @Public()
  @Get('healthz')
  async healthz() {
    await this.prisma.$queryRaw`SELECT 1`;
    // Проверка тулчейна — в фоне: раньше она шла синхронно прямо в этом запросе (execFileSync),
    // блокировала event loop до ~25 секунд и на это время останавливала весь сервис — при том
    // что pm2 дёргает healthz каждые 2 секунды.
    if (!this.tools || Date.now() - this.tools.at >= TOOLCHECK_TTL_MS) void this.refreshToolchain();
    return {
      ok: true,
      ts: new Date().toISOString(),
      media: this.tools ? (this.tools.ok ? 'ok' : 'degraded') : 'unknown',
    };
  }

  /**
   * Тулчейн с кэшем на 10 минут и на процесс. Проверка асинхронная (execFile, а не execFileSync)
   * и наружу не бросает никогда: healthz не должен ни ждать её, ни падать из-за неё — именно
   * поэтому вызов с `void` в пути запроса безопасен.
   */
  private async refreshToolchain(): Promise<void> {
    if (this.checking) return;
    this.checking = true;
    try {
      const missing: string[] = [];
      for (const bin of MEDIA_BINS) {
        try {
          await execFileAsync('bash', ['-c', `command -v ${bin}`], { timeout: BIN_TIMEOUT_MS });
        } catch {
          missing.push(bin);
        }
      }
      let version: string | null = null;
      try {
        const { stdout } = await execFileAsync('bash', ['-c', 'ffmpeg -version 2>/dev/null | head -1'], {
          encoding: 'utf8',
          timeout: BIN_TIMEOUT_MS,
        });
        version = String(stdout).trim() || null;
      } catch {
        version = null;
      }
      const ok = missing.length === 0;
      // Предупреждаем только при смене состояния: pm2 спрашивает healthz каждые 2 секунды, и
      // «нет бинарей» на каждый запрос было спамом, в котором терялись остальные сообщения.
      const wasOk = this.tools?.ok;
      this.tools = { at: Date.now(), ok, missing, version };
      if (!ok && wasOk !== false) this.logger.warn(`нет бинарей для медиа: ${missing.join(', ')}`);
      if (ok && wasOk === false) this.logger.log('тулчейн для медиа снова на месте');
    } catch (err) {
      // сюда попадает только неожиданное (ошибки самого execFile уже разобраны выше):
      // состояние не портим, healthz продолжит отдавать предыдущий результат
      const error = err as Error;
      this.logger.error(`не удалось проверить тулчейн медиа: ${error?.message ?? String(err)}`);
    } finally {
      this.checking = false;
    }
  }
}
