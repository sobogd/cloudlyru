import { env } from '../config/env';

/**
 * Расчёт бюджета одного вызова локальной модели.
 *
 * Ограничение здесь не деньги, а окно контекста движка на маке (см. `LLM_CTX` в
 * `src/config/env.ts`): движок отвечает на слишком большой запрос кодом 400, а не урезает его,
 * поэтому весь бюджет выводится из окна, а не подбирается руками.
 *
 * Токены считаются по символам, а не настоящим токенизатором: своего токенизатора под
 * загруженный GGUF у нас нет, а держать его в синхроне с моделью — лишняя работа. Два символа
 * на токен — пессимистичная оценка для обоих письменных видов, которые тут встречаются
 * (кириллица ~2.5 символа на токен, латиница ~4), то есть оценка никогда не меньше правды и
 * окно не переполняется.
 */

/** Символов на токен, с округлением вниз — см. заголовок файла. */
const CHARS_PER_TOKEN = 2;

/** Токены, отданные системной подсказке и правилам перевода (~1200 токенов ≈ 2400 символов). */
const PROMPT_RESERVE_TOKENS = 1200;

/** Запас на то, что модель добавит от себя: подсказка это запрещает, но переполнение окна — это
 *  отказ движка и потерянный запрос, и немного свободного места дешевле доверия. */
const SLACK_TOKENS = 256;

/** Во сколько раз ответ может быть длиннее входа, в токенах. Перевод на русский растёт примерно
 *  в 1.6 раза по токенам (латиница плотнее кириллицы), а иногда модель разворачивает короткую
 *  фразу в предложение; 2.2 покрывает оба случая. */
const OUTPUT_GROWTH = 2.2;

/** Потолок входа одного вызова: вход плюс худший ответ плюс подсказка обязаны влезть в окно. */
const MAX_INPUT_CHARS = Math.floor(
  ((env.LLM_CTX - PROMPT_RESERVE_TOKENS - SLACK_TOKENS) / (1 + OUTPUT_GROWTH)) * CHARS_PER_TOKEN,
);

/** Размер одного куска при нарезке длинного текста, символов. Вдвое меньше максимума: меньший
 *  вызов быстрее считает префикс, а полное окно на маке — это около минуты префилла. */
export const CHUNK_CHARS = Math.min(8000, MAX_INPUT_CHARS);

/** Оценка числа токенов для текста, с округлением вверх (оценка должна быть верхней границей). */
function estimateTokens(chars: number): number {
  return Math.ceil(Math.max(0, chars) / CHARS_PER_TOKEN);
}

/**
 * Потолок ответа одного вызова, токены.
 *
 * Берётся большее из «хватает на перевод такой длины» и «сколько окно оставило после подсказки
 * и входа»: второе значение превышать нельзя ни при каких условиях, иначе движок откажет.
 */
export function maxOutputTokens(inputChars: number): number {
  const wanted = Math.ceil(estimateTokens(inputChars) * OUTPUT_GROWTH) + SLACK_TOKENS;
  const available = env.LLM_CTX - PROMPT_RESERVE_TOKENS - estimateTokens(inputChars) - SLACK_TOKENS;
  return Math.max(64, Math.min(wanted, available));
}

/**
 * Режет текст на куски не длиннее [limit], предпочитая границы абзаца, строки, предложения
 * и слова — именно в этом порядке.
 *
 * Нарезка нужна там, где письмо не влезает в окно целиком. Каждый кусок переводится отдельно,
 * поэтому резать следует по смысловым границам: разрез посреди предложения модель иногда
 * договаривает по-своему, и на стыке появляется мусор. Пустая строка (граница абзаца) —
 * лучший разрез, поэтому абзацы и собираются в кусок целиком, пока влезают.
 */
export function splitIntoChunks(text: string, limit: number = CHUNK_CHARS): string[] {
  if (text.length <= limit) return text.length > 0 ? [text] : [];

  const chunks: string[] = [];
  let current = '';
  for (const unit of units(text)) {
    // Абзац длиннее куска (стена текста без пустых строк) режется по предложениям, а затем
    // жёстко: иначе он не влез бы ни в один вызов.
    if (unit.length > limit) {
      if (current) {
        chunks.push(current);
        current = '';
      }
      chunks.push(...hardSplit(unit, limit));
      continue;
    }
    if (current.length + unit.length > limit) {
      chunks.push(current);
      current = '';
    }
    current += unit;
  }
  if (current) chunks.push(current);
  return chunks;
}

/**
 * Абзацы текста вместе с разделителем, который за ними шёл.
 *
 * Два уровня разбора намеренно: пустая строка отделяет абзацы, а одиночные переносы внутри
 * абзаца остаются его частью — так список или блок кода не разрезается посреди сборки кусков.
 */
function* units(text: string): Generator<string> {
  const parts = text.split(/(\n{2,})/);
  for (let i = 0; i < parts.length; i += 2) {
    const piece = parts[i];
    const after = parts[i + 1] ?? '';
    if (piece.length > 0 || after.length > 0) yield piece + after;
  }
}

/** Последняя линия обороны: режем по предложениям, пока влезают, затем жёстко по [limit],
 *  предпочитая пробел, чтобы слова оставались целыми. */
function hardSplit(text: string, limit: number): string[] {
  const out: string[] = [];
  let rest = text;
  while (rest.length > limit) {
    const window = rest.slice(0, limit);
    const cut = Math.max(
      window.lastIndexOf('. '),
      window.lastIndexOf('! '),
      window.lastIndexOf('? '),
      window.lastIndexOf('\n'),
      window.lastIndexOf(' '),
    );
    const at = cut > limit / 2 ? cut + 1 : limit;
    out.push(rest.slice(0, at));
    rest = rest.slice(at);
  }
  if (rest) out.push(rest);
  return out;
}
