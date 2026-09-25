#!/bin/bash
# =============================================================================
# run-llm-mt.sh — keeps the local translation model (TranslateGemma-4B) serving translation.
#
# Managed by launchd (com.agent.llm-mt, RunAtLoad + KeepAlive). Это второй текстовый движок
# рядом с com.agent.llm: там универсальная Qwen3.8-27B под поиск, код и чат, а здесь —
# специализированная переводческая модель на 127.0.0.1:1235.
#
# Зачем отдельная модель под перевод. Замерено на этой машине на живом тексте (страница
# apple.com/es, 18 строк маркетинговых копий с каламбурами): TranslateGemma-4B сохранила
# все 18 строк построчно и передала игру слов («Haz películas de película» -> «Снимай
# кино», «La inteligencia pisa el acelerador» -> «Интеллект задаёт темп»), прогон занял
# 8,4 с; Qwen3.5-9B на том же тексте дала 15,0 с при сопоставимом качестве. Пробовали
# ещё Hy-MT2-7B от Tencent — она склеила и потеряла часть строк, «Mucho Pro» перевела как
# «Удачи», а с промптом про стиль вообще пересказала текст абзацем, выкинув половину
# строк. Отсюда выбор: не по рейтингам, а по слепому сравнению на своих текстах.
#
# Почему --no-jinja. Родной шаблон TranslateGemma требует, чтобы content был списком ровно
# из одного объекта с ключами type/source_lang_code/target_lang_code/text, и llama.cpp не
# может построить по нему парсер — сервер даже не стартует:
#   chat template parsing error: Unable to generate parser for this template
# С --no-jinja берётся встроенный gemma-шаблон, и промпт надо подавать текстом ровно в том
# виде, в каком его собирает родной шаблон, — модель обучена именно на нём:
#
#   You are a professional {Язык источника} ({код}) to {Целевой язык} ({код}) translator.
#   Your goal is to accurately convey the meaning and nuances of the original {Язык источника}
#   text while adhering to {Целевой язык} grammar, vocabulary, and cultural sensitivities.
#   Produce only the {Целевой язык} translation, without any additional explanations or
#   commentary. Please translate the following {Язык источника} text into {Целевой язык}:
#
#   {текст}
#
# В чате эту модель не выбрать, и это не про флаги: входное окно у неё 2K токенов, а любой
# агент (pi, CloudlyRu) отправляет системный промпт со схемами инструментов на 3K+ —
# замерено: на 3115 токенов модель отвечает двумя токенами и замолкает. Переводчику это не
# мешает: он собирает свой короткий промпт сам (см. lib/translate.ts).
#
# Языки подставляются полными английскими именами (Spanish, Russian), коды — ISO 639-1
# (es, ru). Это забота вызывающей стороны: сервер промпт не подставляет.
#
# Ограничение модели, о котором надо помнить: входной контекст 2K токенов. Длинные тексты
# режет и склеивает вызывающая сторона, сервер об этом не знает; -c 4096 взят с запасом
# под служебную часть промпта. Ещё в этом GGUF нет mmproj, то есть перевода текста с
# картинок (модель это умеет) здесь нет — только текст.
#
# Думания у этой модели нет: TranslateGemma построена на Gemma 3, без thinking-токенов.
# Это отличие от gemma-4-E4B, где шаблон включает думание всякий раз, когда в запросе есть
# system-промпт или инструменты.
#
# Что проверяет сторож: сервер отвечает на /health и в ответе есть хотя бы одна модель.
# Как и в run-llm.sh, одного открытого порта недостаточно — на порту мог остаться чужой
# процесс, который отвечает телом с ошибкой и кодом 200.
# =============================================================================
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LLAMA_SERVER=/opt/homebrew/bin/llama-server
MODEL="$HOME/models/translategemma-4b-it-Q5_K_M.gguf"
ALIAS="translategemma-4b"
PORT=1235
CTX=4096
LOG=/tmp/llm-mt.log
CHECK_EVERY=30

# Прошлое состояние — чтобы писать в лог только переходы, а не строку каждые 30 секунд.
state=""

say() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

server_ok() {
  curl -sf -m 5 "http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -q '"status":"ok"'
}

start_server() {
  # Логи сервера идут в отдельный файл: launchd пишет сюда только переходы состояния.
  nohup "$LLAMA_SERVER" \
    -m "$MODEL" --alias "$ALIAS" \
    --host 127.0.0.1 --port "$PORT" \
    --no-jinja \
    -ngl 999 \
    -c "$CTX" \
    --flash-attn on \
    >>"$LOG" 2>&1 &
  say "llama-server (перевод) запущен (pid $!), лог: $LOG"
}

if [ ! -x "$LLAMA_SERVER" ]; then
  say "нет $LLAMA_SERVER — поставь llama.cpp: brew install llama.cpp"
  exit 1
fi
if [ ! -f "$MODEL" ]; then
  say "нет файла модели $MODEL — скачай GGUF в $HOME/models"
  exit 1
fi

while :; do
  if ! server_ok; then
    # Убиваем возможный подвисший процесс, чтобы не плодить слушателей на одном порту:
    # порт занят мёртвым процессом — классическая причина «перезапустил, а всё равно молчит».
    pkill -f "llama-server.*--port ${PORT}" 2>/dev/null
    sleep 1
    start_server
    for _ in $(seq 1 20); do
      server_ok && break
      sleep 1.5
    done
  fi

  now=down
  server_ok && now=up
  [ "$now" != "$state" ] && say "состояние: ${now}"
  state="$now"

  sleep "$CHECK_EVERY"
done
