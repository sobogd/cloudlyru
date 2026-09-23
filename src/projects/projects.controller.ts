import {
  Body,
  Controller,
  Delete,
  Get,
  HttpStatus,
  Logger,
  Param,
  Post,
  Query,
  Req,
  Res,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { Readable } from 'node:stream';
import { ApiError, badRequest, payloadTooLarge } from '../common/errors';
import { RateLimit } from '../common/decorators';
import { ProjectsError, ProjectsService } from './projects.service';
import {
  ActivitySnapshot,
  ProjectsActivityService,
} from './projects-activity.service';

/** Потолок длины сообщения агенту: его принимает и мост, но отказ лучше дать здесь, с текстом. */
const MAX_PROMPT_CHARS = 20_000;

/**
 * Потолок аудио голосового ввода.
 *
 * 16 МБ — это минуты речи в любом формате, который даёт платформа; больше — уже не реплика в
 * композер, а утечка памяти на сервере: запись целиком держится в буфере, прежде чем уйти на мак.
 */
const MAX_AUDIO_BYTES = 16 * 1024 * 1024;

/** Сколько распознаваний речи может идти одновременно: каждое держит запись в памяти. */
const MAX_TRANSCRIBE_PARALLEL = 2;

/**
 * Код «клиент ушёл»: запрос оборвал сам человек (ушёл с экрана, нажал «Стоп»).
 *
 * В стандарте HTTP такого кода нет — это общепринятое расширение nginx. Приложению он нужен
 * как признак «это не сбой»: по нему отмена не показывается ошибкой.
 */
const CLIENT_GONE = 499;

/**
 * Раздел «Проекты»: выбор папки проекта на домашнем маке и работа с агентом pi внутри неё.
 *
 * Агент, модель и история живут на маке, но запросы делает сервер.
 * Клиент приложения ходит только в ручки `/projects/*`, поэтому адреса туннеля, портов и
 * токенов в сборке нет; доступ закрыт той же сессией, что и остальные разделы.
 *
 * Агент работает в папке проекта — читает и правит файлы, запускает команды, — поэтому наружу
 * отдаются не только ответы, но и действия: карточки инструментов, вывод команд, состояние
 * контекста.
 *
 * Плата за это — доверие к маку: песочницы у pi нет, инструменты работают с правами
 * пользователя, и единственные границы — список разрешённых корней на маке (allowlist в
 * `~/.pi-bridge.json`) и то, что порт моста открыт только на loopback обоих концов туннеля.
 */
@Controller('projects')
export class ProjectsController {
  private readonly logger = new Logger(ProjectsController.name);

  /** Сколько распознаваний речи идёт прямо сейчас (см. MAX_TRANSCRIBE_PARALLEL). */
  private transcribing = 0;

  constructor(
    private readonly projects: ProjectsService,
    private readonly activity: ProjectsActivityService,
  ) {}

  /**
   * Состояние моста: версия харнесса, выбранная модель, разрешённые корни.
   *
   * Недоступный мак — это не сбой запроса, а состояние раздела: клиент по этому ответу решает,
   * показать список проектов или «мост недоступен, мак спит».
   */
  @Get('health')
  async health() {
    return this.wrap(() => this.projects.call<Record<string, unknown>>('GET', '/health'));
  }

  /** Проекты: папки внутри разрешённых корней, в которых можно работать. */
  @Get()
  async list() {
    return this.wrap(() => this.projects.call<Record<string, unknown>>('GET', '/projects'));
  }

  /**
   * Харнессы, которые стоят на маке: pi и Claude Code, с версиями.
   *
   * Приложение по этому списку решает, показывать ли выбор харнесса и что предлагать новой
   * сессии. Их отсутствие — не «харнессов нет», а «мост не ответил», и приложение это
   * различает: без списка оно не фильтрует разговоры, а показывает все.
   */
  @Get('harnesses')
  async harnesses() {
    return this.wrap(() => this.projects.call<Record<string, unknown>>('GET', '/harnesses'));
  }

  /**
   * Модели, доступные харнессу на маке: локальная и, если настроены, удалённые по API.
   *
   * Список целиком определяется настройками pi на маке (`~/.pi/agent/models.json` и его
   * каталог провайдеров) — сервер и приложение его только показывают. Ключи от API остаются
   * на маке и наружу не уходят: приложению приходит признак «ключ задан», а не сам ключ.
   *
   * Харнесс приходит от клиента (`?harness=pi|claude`): у pi модели задаются провайдерами, у
   * Claude Code — своим фиксированным набором. Мост без него отвечает моделями pi, поэтому
   * не пробрасывать параметр означает показывать в выборе Claude Code модели pi.
   */
  @Get('models')
  async models(@Query('harness') harness?: string) {
    const target = (harness ?? '').trim();
    const query = target ? `?harness=${encodeURIComponent(target)}` : '';
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>('GET', `/models${query}`),
    );
  }

  /**
   * Что считается на маке прямо сейчас и что закончилось, пока приложения не было.
   *
   * Сервер опрашивает мост сам (раз в пять секунд), поэтому снимок живёт независимо от того,
   * открыто ли приложение: вернувшись, оно видит «готово» у разговоров, которые дописались без
   * него. Настоящих уведомлений в фоне пока нет — это отдельная работа (push-канал).
   */
  @Get('activity')
  activitySnapshot(): ActivitySnapshot {
    return this.activity.snapshot();
  }

  /**
   * Провайдеры, настроенные у pi на маке: свои (со своим адресом и ключом) и встроенные.
   *
   * Ключи наружу не уходят ни целиком, ни хвостом — приложению приходит только признак «ключ
   * задан» и его длина. Сам ключ живёт на маке: в `models.json` для своих провайдеров и в
   * `auth.json` для встроенных, как того требует pi.
   */
  @Get('providers')
  async providers() {
    return this.wrap(() => this.projects.call<Record<string, unknown>>('GET', '/providers'));
  }

  /**
   * Создаёт или изменяет своего провайдера: адрес, API, ключ и список моделей.
   *
   * Пустой ключ при изменении означает «оставить прежний»: приложение не показывает сохранённый
   * ключ, поэтому человек правит адрес или название, не вводя ключ заново.
   */
  @Post('providers')
  async saveProvider(@Body() body: Record<string, unknown> = {}) {
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>('POST', '/providers', {
        body: {
          key: str(body.key),
          name: str(body.name),
          baseUrl: str(body.baseUrl),
          api: str(body.api),
          ...(str(body.apiKey) ? { apiKey: str(body.apiKey) } : {}),
          models: Array.isArray(body.models) ? body.models : [],
        },
        // запись в models.json на маке — мгновенная, но ждать её дольше секунды незачем
        timeoutMs: 30_000,
      }),
    );
  }

  /**
   * Проверяет адрес и ключ провайдера и возвращает его список моделей.
   *
   * Один запрос отвечает на два вопроса сразу: рабочий ли ключ и какие модели доступны, —
   * поэтому приложение подтягивает модели отсюда, а не просит вписать их руками.
   */
  @Post('providers/probe')
  async probeProvider(@Body() body: Record<string, unknown> = {}) {
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>('POST', '/providers/probe', {
        body: {
          baseUrl: str(body.baseUrl),
          provider: str(body.provider),
          ...(str(body.apiKey) ? { apiKey: str(body.apiKey) } : {}),
        },
        // провайдер может отвечать медленно, но дольше полуминуты ждать смысла нет
        timeoutMs: 40_000,
      }),
    );
  }

  /** Задаёт или убирает ключ встроенного провайдера pi (пустой ключ — убрать). */
  @Post('providers/key')
  async saveProviderKey(@Body() body: Record<string, unknown> = {}) {
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>('POST', '/providers/key', {
        body: { provider: str(body.provider), apiKey: str(body.apiKey) },
        timeoutMs: 30_000,
      }),
    );
  }

  /**
   * Удаляет своего провайдера из настроек pi.
   *
   * Провайдера по умолчанию мост удалить не даст: на нём работает мак, когда модель не выбрана.
   */
  @Delete('providers/:key')
  async deleteProvider(@Param('key') key: string) {
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>(
        'DELETE',
        `/providers/${encodeURIComponent(key)}`,
        { timeoutMs: 30_000 },
      ),
    );
  }

  /**
   * Сессии проекта или всех проектов сразу: их мост читает из файлов pi на маке.
   *
   * Без `path` приходят сессии всех разрешённых проектов одним списком, свежие сверху — по
   * нему приложение рисует общий список разговоров. С `path` — разговоры одной папки.
   */
  @Get('sessions')
  async sessions(@Query('path') path?: string) {
    const dir = (path ?? '').trim();
    const query = dir ? `?path=${encodeURIComponent(dir)}` : '';
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>('GET', `/sessions${query}`),
    );
  }

  /** Состояние открытой сессии: модель, занятость, расход контекста. */
  @Get('sessions/:id')
  async session(@Param('id') id: string) {
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>('GET', `/sessions/${encodeURIComponent(id)}`),
    );
  }

  /**
   * Переписка сессии в виде, готовом для экрана, — страницей от конца.
   *
   * `limit` и `before` уходят на мост как есть: он отдаёт последние `limit` сообщений до
   * индекса `before`, а вместе с ними — общее число сообщений и признак «выше есть ещё». Без
   * параметров мост отдаёт историю целиком: так работает сборка приложения, которая о страницах
   * ещё не знает.
   */
  @Get('sessions/:id/messages')
  async messages(
    @Param('id') id: string,
    @Query('limit') limit?: string,
    @Query('before') before?: string,
  ) {
    const query = new URLSearchParams();
    const size = Number.parseInt((limit ?? '').trim(), 10);
    const from = Number.parseInt((before ?? '').trim(), 10);
    if (Number.isFinite(size) && size > 0) query.set('limit', String(size));
    if (Number.isFinite(from) && from >= 0) query.set('before', String(from));
    const suffix = query.toString() ? `?${query}` : '';
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>(
        'GET',
        `/sessions/${encodeURIComponent(id)}/messages${suffix}`,
      ),
    );
  }

  /**
   * Открывает сессию в папке проекта: мост поднимает процесс pi (или продолжает [sessionId]).
   *
   * Сессия — это процесс на маке, и он занимает память под контекст модели, поэтому по простою
   * мост гасит его сам; продолжение разговора поднимает процесс заново из файла истории.
   */
  @Post('sessions')
  async open(@Body() body: Record<string, unknown> = {}) {
    const path = typeof body.path === 'string' ? body.path.trim() : '';
    if (!path) throw badRequest('path обязателен');
    const sessionId = typeof body.sessionId === 'string' ? body.sessionId.trim() : '';
    // какой агент ведёт разговор: без него мост открывает сессию pi, и выбранный Claude Code
    // молча превращался бы в разговор pi
    const harness = typeof body.harness === 'string' ? body.harness.trim() : '';
    // модель выбирается при открытии: у pi их бывает несколько (локальная и удалённая по API),
    // а после открытия её меняет ручка model, не перезапуская разговор
    const provider = typeof body.provider === 'string' ? body.provider.trim() : '';
    const model = typeof body.model === 'string' ? body.model.trim() : '';
    // уровень усилия — выбор Claude Code; он не записывается в файл разговора, поэтому уезжает
    // и для существующей сессии, иначе возобновлённый процесс взял бы умолчание модели
    const effort = typeof body.effort === 'string' ? body.effort.trim() : '';
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>('POST', '/sessions', {
        body: {
          path,
          ...(sessionId ? { sessionId } : {}),
          ...(harness ? { harness } : {}),
          ...(provider ? { provider } : {}),
          ...(model ? { model } : {}),
          ...(effort ? { effort } : {}),
        },
        // запуск процесса pi на маке — секунды, но не мгновение
        timeoutMs: 120_000,
      }),
    );
  }

  /**
   * Отправляет сообщение агенту и отдаёт поток событий ответа.
   *
   * Тело ответа моста перекладывается в ответ клиенту как есть (SSE), а разрыв соединения с
   * приложением гасит и работу агента: по обрыву мост шлёт `abort` в pi, поэтому команды не
   * продолжают выполняться на маке, когда экран уже закрыт.
   */
  @Post('sessions/:id/prompt')
  @RateLimit(20, 60_000)
  async prompt(
    @Param('id') id: string,
    @Body() body: Record<string, unknown> = {},
    @Req() req: Request,
    @Res() res: Response,
  ) {
    const text = typeof body.text === 'string' ? body.text.trim() : '';
    // Идентификатор сообщения от приложения: мост по нему отличает повтор от осознанно
    // повторённого вопроса, а не сравнивает текст (два «продолжай» подряд — разные сообщения).
    const messageId = str(body.id);
    if (!text) throw badRequest('text обязателен');
    if (text.length > MAX_PROMPT_CHARS) {
      throw badRequest(`сообщение длиннее ${MAX_PROMPT_CHARS} символов`);
    }

    const abort = new AbortController();
    req.on('close', () => abort.abort());

    // Запрос к мосту делается ДО отправки заголовков потока: отказ (занятая сессия, мост
    // недоступен) должен прийти обычным HTTP-кодом с текстом, а не молчанием в потоке.
    const upstream = await this.wrap(() =>
      this.projects.stream(
        `/sessions/${encodeURIComponent(id)}/prompt`,
        { text, ...(messageId ? { id: messageId } : {}) },
        { signal: abort.signal },
      ),
    );

    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    // без этого nginx копит ответ в буфере и поток превращается в «ответ приходит целиком в конце»
    res.setHeader('X-Accel-Buffering', 'no');
    res.flushHeaders?.();

    const body_ = Readable.fromWeb(upstream as Parameters<typeof Readable.fromWeb>[0]);
    // Ошибки чтения (обрыв туннеля, отмена) закрывают ответ событием ошибки: без него клиент
    // видит просто конец потока и остаётся в состоянии ожидания, пока не сработает watchdog.
    body_.on('error', (e) => {
      this.logger.warn(`поток агента прерван: ${String(e)}`);
      this.closeStream(res, 'связь с агентом прервалась');
    });
    body_.pipe(res);
  }

  /**
   * Дописывает сообщение в занятую сессию: оно уйдёт агенту по завершении текущего прогона.
   *
   * Отдельная ручка от `prompt` нужна приложению, у которого уже открыт поток: второй поток
   * дал бы двойной текст на экране. Ответ моста передаётся как есть — `{queued, position}`,
   * причём `queued: false` означает, что сессия успела освободиться и сообщение надо отправить
   * обычным `prompt`; решает это приложение.
   */
  @Post('sessions/:id/queue')
  @RateLimit(20, 60_000)
  async queue(@Param('id') id: string, @Body() body: Record<string, unknown> = {}) {
    const text = typeof body.text === 'string' ? body.text.trim() : '';
    const messageId = str(body.id);
    if (!text) throw badRequest('text обязателен');
    // Потолок длины тот же, что у prompt: он общий с мостом (MAX_MESSAGE_CHARS), и отказ с
    // текстом лучше отдать здесь, не гоняя запрос через туннель.
    if (text.length > MAX_PROMPT_CHARS) {
      throw badRequest(`сообщение длиннее ${MAX_PROMPT_CHARS} символов`);
    }
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>(
        'POST',
        `/sessions/${encodeURIComponent(id)}/queue`,
        { body: { text, ...(messageId ? { id: messageId } : {}) } },
      ),
    );
  }

  /**
   * Подключает приложение к уже идущему прогону агента.
   *
   * Нужно, когда разговор идёт (его начали с другого устройства или экран открыли заново во
   * время работы): вместо отказа «сессия занята» приложение смотрит ответ со стороны. Разрыв
   * этого соединения работу не прерывает — за прерывание отвечает `abort`.
   */
  @Get('sessions/:id/events')
  async events(@Param('id') id: string, @Req() req: Request, @Res() res: Response) {
    const abort = new AbortController();
    req.on('close', () => abort.abort());

    const upstream = await this.wrap(() =>
      this.projects.stream(
        `/sessions/${encodeURIComponent(id)}/events`,
        undefined,
        { signal: abort.signal, method: 'GET' },
      ),
    );

    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('X-Accel-Buffering', 'no');
    res.flushHeaders?.();

    const body = Readable.fromWeb(upstream as Parameters<typeof Readable.fromWeb>[0]);
    body.on('error', () => this.closeStream(res, 'связь с агентом прервалась'));
    body.pipe(res);
  }

  /** Останавливает генерацию: мост шлёт `abort` в pi и дожидается свободной сессии. */
  @Post('sessions/:id/abort')
  async abort(@Param('id') id: string) {
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>(
        'POST',
        `/sessions/${encodeURIComponent(id)}/abort`,
        { timeoutMs: 60_000 },
      ),
    );
  }

  /**
   * Сжимает контекст сессии: длинная работа иначе перестанет влезать в окно модели.
   *
   * Таймаут большой осознанно: это отдельный вызов модели на маке, и на девятимиллиардной
   * модели пересказ длинного разговора идёт минутами.
   */
  @Post('sessions/:id/compact')
  async compact(@Param('id') id: string, @Body() body: Record<string, unknown> = {}) {
    const instructions = typeof body.instructions === 'string' ? body.instructions : '';
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>(
        'POST',
        `/sessions/${encodeURIComponent(id)}/compact`,
        { body: { ...(instructions ? { instructions } : {}) }, timeoutMs: 15 * 60_000 },
      ),
    );
  }

  /** Смена модели для сессии: список моделей живёт у pi. */
  @Post('sessions/:id/model')
  async model(@Param('id') id: string, @Body() body: Record<string, unknown> = {}) {
    const provider = typeof body.provider === 'string' ? body.provider.trim() : '';
    const modelId = typeof body.modelId === 'string' ? body.modelId.trim() : '';
    if (!provider || !modelId) throw badRequest('нужны provider и modelId');
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>(
        'POST',
        `/sessions/${encodeURIComponent(id)}/model`,
        { body: { provider, modelId } },
      ),
    );
  }

  /**
   * Смена уровня усилия у сессии Claude Code (быстрее — дешевле, выше — умнее).
   *
   * Пустая строка означает «вернуться к умолчанию модели»: это осмысленный выбор, поэтому
   * пустое значение не отклоняем. У pi такого выбора нет — там размышления задаёт сама модель.
   */
  @Post('sessions/:id/effort')
  async effort(@Param('id') id: string, @Body() body: Record<string, unknown> = {}) {
    const effort = typeof body.effort === 'string' ? body.effort.trim() : '';
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>(
        'POST',
        `/sessions/${encodeURIComponent(id)}/effort`,
        { body: { effort } },
      ),
    );
  }

  /**
   * Ставит сессии новое имя.
   *
   * Имя хранят сами харнессы, в журнале разговора (у pi — запись `session_info`, у Claude Code —
   * `custom-title`), поэтому открытый процесс для этого не нужен: переименовать можно и закрытый
   * разговор. Пустое имя — ошибка: снять имя совсем нельзя.
   */
  @Post('sessions/:id/name')
  async rename(@Param('id') id: string, @Body() body: Record<string, unknown> = {}) {
    const name = typeof body.name === 'string' ? body.name : '';
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>(
        'POST',
        `/sessions/${encodeURIComponent(id)}/name`,
        { body: { name } },
      ),
    );
  }

  /**
   * Удаляет сессию: процесс гасится, файл истории стирается с мака.
   *
   * Необратимо, поэтому в приложении это действие с подтверждением.
   */
  @Delete('sessions/:id')
  async remove(@Param('id') id: string) {
    return this.wrap(() =>
      this.projects.call<Record<string, unknown>>(
        'DELETE',
        `/sessions/${encodeURIComponent(id)}`,
      ),
    );
  }

  /**
   * Распознаёт записанную речь в текст для голосового ввода в композере разговора.
   *
   * Тело — само аудио (`application/octet-stream`), а не JSON: сервер его не разбирает, а
   * перекладывает на локальный whisper.cpp на маке. Мимо JSON-парсера такие тела проходят как
   * есть (см. комментарий к `express.json` в `main.ts`), поэтому поток читаем сами и сразу
   * считаем длину — иначе один цикл залил бы всю память процесса.
   */
  @Post('transcribe')
  @RateLimit(60, 60_000)
  async transcribe(@Req() req: Request) {
    // Тип приходит от клиента и нужен только как подсказка whisper: своего разбора форматов
    // здесь нет, поэтому незнакомый (или вовсе отсутствующий) тип отправляем как есть.
    const mime = String(req.headers['content-type'] ?? '')
      .split(';')[0]
      .trim();

    const contentLength = Number(req.headers['content-length'] ?? 0);
    if (Number.isFinite(contentLength) && contentLength > MAX_AUDIO_BYTES) {
      throw payloadTooLarge('запись слишком длинная');
    }

    const chunks: Buffer[] = [];
    let total = 0;
    for await (const chunk of req) {
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      total += buf.length;
      if (total > MAX_AUDIO_BYTES) throw payloadTooLarge('запись слишком длинная');
      chunks.push(buf);
    }
    if (total === 0) throw badRequest('пустая запись');

    // Параллельные распознавания ограничены: каждое держит всю запись в памяти (до 16 МБ),
    // и десяток одновременных диктовок съел бы память сервера вместе с загрузками и файлами.
    if (this.transcribing >= MAX_TRANSCRIBE_PARALLEL) {
      throw new ApiError(
        HttpStatus.SERVICE_UNAVAILABLE,
        'распознавание речи занято, попробуйте ещё раз',
        'stt_busy',
      );
    }
    this.transcribing += 1;
    try {
      const text = await this.wrap(() =>
        this.projects.transcribe(Buffer.concat(chunks), mime),
      );
      return { text };
    } finally {
      this.transcribing -= 1;
    }
  }

  /**
   * Переводит ошибку моста в HTTP-ответ с тем же кодом и текстом.
   *
   * Коды сохраняются намеренно: 409 значит «сессия занята» и приложение показывает это
   * отдельной подсказкой, а 502/504 — «мост недоступен», где повторять бессмысленно. Тексты
   * моста уже сформулированы для человека, поэтому уходят клиенту без правки.
   */
  private async wrap<T>(run: () => Promise<T>): Promise<T> {
    try {
      return await run();
    } catch (e) {
      if (!(e instanceof ProjectsError)) throw e;
      // 499 — внутренний признак «человек ушёл» (клиент оборвал запрос). Это не ошибка клиента
      // и не сбой сервера: отдаём код как есть, чтобы приложение не показывало отмену как сбой
      // и не предлагало «Повторить» там, где повторять нечего.
      const status = e.status;
      if (status >= 500 && status !== CLIENT_GONE) {
        this.logger.warn(`проекты: ${status} ${e.message}`);
      }
      throw new ApiError(status as HttpStatus, e.message, codeFor(status));
    }
  }

  /**
   * Закрывает поток событий, отправив причину событием `error`.
   *
   * Просто `res.end()` клиент видит как «поток закончился сам»: у него нет ни `done`, ни
   * ошибки, и экран остаётся в состоянии ожидания до срабатывания watchdog'а. Событие ошибки
   * доводит причину до человека, не дописывая в переписку пустой ответ.
   */
  private closeStream(res: Response, message: string): void {
    try {
      res.write(`data: ${JSON.stringify({ type: 'error', message })}\n\n`);
    } catch {
      // соединение уже мертво — писать некуда, молчание тут честнее исключения
    }
    res.end();
  }
}

/** Строка из тела запроса: у необязательных полей пустая строка вместо `undefined`. */
function str(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

/**
 * Машиночитаемый код ответа по коду HTTP.
 *
 * Нужен приложению: по нему оно различает «сессия занята» и «мост недоступен» независимо от
 * текста, который может поменяться на стороне моста.
 */
function codeFor(status: number): string {
  switch (status) {
    case HttpStatus.BAD_REQUEST:
      return 'bad_request';
    case HttpStatus.CONFLICT:
      return 'busy';
    case CLIENT_GONE:
      // Отмена человеком: приложение по этому коду не показывает ошибку и не предлагает повтор
      return 'cancelled';
    case HttpStatus.SERVICE_UNAVAILABLE:
    case HttpStatus.BAD_GATEWAY:
    case HttpStatus.GATEWAY_TIMEOUT:
      return 'bridge_unavailable';
    default:
      return 'error';
  }
}
