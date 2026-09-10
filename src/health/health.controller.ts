import { Controller, Get } from '@nestjs/common';
import { execFileSync } from 'child_process';
import { PrismaService } from '../prisma/prisma.service';
import { Public } from '../common/decorators';

/** Бинари, без которых конвертация медиа молча не работает. */
const MEDIA_BINS = ['ffmpeg', 'ffprobe', 'heif-convert'] as const;
const TOOLCHECK_TTL_MS = 10 * 60 * 1000;

interface Toolchain {
  ok: boolean;
  missing: string[];
  version: string | null;
}

@Controller()
export class HealthController {
  private tools: (Toolchain & { at: number }) | null = null;

  constructor(private readonly prisma: PrismaService) {}

  @Public()
  @Get('healthz')
  async healthz() {
    await this.prisma.$queryRaw`SELECT 1`;
    return {
      ok: true,
      ts: new Date().toISOString(),
      // Раньше healthz проверял только Postgres, поэтому отсутствие ffmpeg/heif-convert
      // на новом сервере обнаруживалось лишь по «навсегда зависшим» задачам конвертации.
      media: this.mediaToolchain(),
    };
  }

  /** Тулчейн с кэшем: спавнить ffmpeg на каждый health-запрос не нужно. */
  private mediaToolchain(): Toolchain {
    const now = Date.now();
    if (this.tools && now - this.tools.at < TOOLCHECK_TTL_MS) {
      return { ok: this.tools.ok, missing: this.tools.missing, version: this.tools.version };
    }
    const missing: string[] = [];
    for (const bin of MEDIA_BINS) {
      try {
        execFileSync('bash', ['-c', `command -v ${bin}`], { stdio: 'pipe', timeout: 5000 });
      } catch {
        missing.push(bin);
      }
    }
    let version: string | null = null;
    try {
      version =
        execFileSync('bash', ['-c', 'ffmpeg -version 2>/dev/null | head -1'], {
          encoding: 'utf8',
          timeout: 5000,
        }).trim() || null;
    } catch {
      version = null;
    }
    this.tools = { at: now, ok: missing.length === 0, missing, version };
    return { ok: missing.length === 0, missing, version };
  }
}
