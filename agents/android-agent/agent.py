"""Цикл агента: задача → наблюдение → действие → проверка — на телефоне, подключённом по ADB.

Как это попадает в чат: сервер (`src/ai/agent.service.ts`) дёргает `server.py` на маке, тот
поднимает этот цикл, отдаёт задачу модели шаг за шагом и возвращает добытый текст. То есть
телефон здесь — то же самое, что сервис поиска (`agents/search-server.py`), только вместо
Playwright на маке работает настоящее устройство: агент сам открывает Chrome, набирает запрос
в поисковике и читает выдачу.

Почему это отдельный цикл, а не инструмент модели чата: модель чата (Gemma 4 E4B) ненадёжна в
генерации вызовов инструментов, а решение шага здесь — это короткий ответ в строгом формате
(`ACTION: …`), который проверяется и разбирается на каждой итерации. Модель для шагов берётся та
же самая (LM Studio на маке), но запросы к ней идут по одному и до ответа человека в чате — по
скринридеру телефона.

Контекст устроен по принципу скользящего окна. В каждый запрос уходит только: задача +
накопленные заметки + текущее состояние экрана + последнее действие. Прошлые экраны
выбрасываются целиком: на замерах полный список выдачи дал 24 441 токен и переполнил окно в
32K, из-за чего цикл терял найденное и делал тринадцать поисков вместо трёх. Состояние экрана,
прочитанное структурно, весит 500–900 токенов, поэтому двадцать шагов укладываются в ~10K.

Память между шагами несут заметки: модель выписывает факты строкой `NOTE:`, и накапливаются
только они — десятки токенов вместо тысяч.
"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Callable

import android

# ------------------------------------------------------------------- модель

# Адрес модели на маке. Локальный LM Studio слушает 1234, но именно здесь, а не через туннель:
# агент работает на той же машине, что и модель, и лишний SSH-хоп дал бы только задержку.
LLM_BASE_URL = os.environ.get("AGENT_LLM_BASE_URL", "http://127.0.0.1:1234/v1").rstrip("/")
LLM_MODEL = os.environ.get("AGENT_LLM_MODEL", "google/gemma-4-e4b")
# Ключ: у локального LM Studio проверки ключа нет, но заголовок нужен непустой — на этом
# значении агент и проверялся, поэтому по умолчанию стоит оно. Переменная нужна на случай, если
# агента когда-нибудь направят в облако.
LLM_API_KEY = os.environ.get("AGENT_LLM_API_KEY", "lm-studio")

# Сколько ждать ответа модели на один шаг. С запасом: модель могут грузить в память с нуля
# (десятки секунд), а без запаса прогон падал бы на первом же шаге с «недоступна».
LLM_TIMEOUT = 180

# Сколько шагов делает агент, если сервер не попросил иначе. Двадцать пять — это примерно
# «зайти в поисковик, ввести запрос, открыть два-три результата и вернуться с ответом».
DEFAULT_MAX_STEPS = 25

# Что делать с моделью чата, если агент опять пойдёт не туда: режим разбора. Включается
# переменной окружения AGENT_DEBUG=1, и тогда в лог сервиса пишется то, на что агент смотрел:
# текст экрана, ответ модели и выполненное действие с подписью элемента. По умолчанию выключен —
# в логе мака не должно быть содержимого чужих страниц и переписки владельца.
DEBUG = os.environ.get("AGENT_DEBUG", "") == "1"

# Страница, с которой начинается каждый прогон. Нужна не для удобства, а чтобы у агента был
# предсказуемый первый экран: Chrome, открытый без адреса, показывает то, что решит сам —
# восстановленную вкладку прошлого сеанса или домашнюю страницу. На живом прогоне так и вышло:
# агент получил первым экраном Google Flights и искал «что такое ллм» в форме авиабилетов.
# Адрес можно сменить переменной окружения — если поисковик начнёт отдавать капчу или
# согласие на cookies, достаточно поставить здесь другой.
START_URL = os.environ.get("AGENT_START_URL", "https://www.google.com/")

# Как долго ждать, пока экран изменится после действия. Дольше — значит страница медленная или
# ничего не произошло; в обоих случаях идём дальше.
PAGE_CHANGE_TIMEOUT = 12.0

SYSTEM_PROMPT = """Ты управляешь телефоном. Ты видишь список элементов текущего экрана и выполняешь задачу пользователя по одному действию за раз.

Отвечай СТРОГО в одном из форматов, без пояснений:

ACTION: click N        — кликнуть по элементу с номером N
ACTION: type N | текст — ввести текст в поле с номером N
ACTION: press enter    — нажать Enter
ACTION: scroll down    — прокрутить экран вниз
NOTE: факт             — записать важный факт (можно вместе с действием)
ACTION: done ответ     — задача решена, вот ответ

Правила:
- Делай РОВНО ОДНО действие за ответ.
- Номер элемента бери из списка экрана. Не выдумывай номера и не бери числа из задачи.
- Работу ты начинаешь на странице поисковика. Первым делом найди ответ через поиск: введи запрос в поле поиска и нажми Enter.
- Если экран показывает не поисковик и не результат поиска — это чужая страница. Не заполняй на ней никакие формы: нажми Back или открой новую вкладку и вернись к поиску.
- Если нужного элемента нет в списке — прокрути экран (ACTION: scroll down).
- Внимательно читай блок «ТЕКСТ НА ЭКРАНЕ»: ответ на вопрос часто уже там, и тогда нужно сразу выдать ACTION: done.
- Перед ответом запиши найденные факты через NOTE.
- Не повторяй действие, которое уже не сработало. Попробуй другой способ.

ВАЖНО на этом устройстве: ввод текста поддерживает ТОЛЬКО латиницу.
Пиши поисковые запросы по-английски, например "1500 usd to eur" вместо
«1500 долларов в евро». Кириллица не наберётся вообще, и действие провалится."""


@dataclass
class AgentResult:
    """Чем закончился прогон: что добыто, за сколько шагов и почему остановились."""

    # Ответ агента: то, что модель написала после `ACTION: done`, либо честное «не успел» —
    # с перечислением того, что успело попасть в заметки.
    answer: str
    # Сколько шагов успели сделать. В лог сервера — чтобы видеть, упёрся ли прогон в лимит.
    steps: int
    # Причина остановки, кроме «модель сама сказала done». Пусто, если задача решена.
    stop_reason: str = ""


@dataclass
class Agent:
    """Агент с постоянным размером контекста, работающий на подключённом телефоне."""

    # serial нужен, когда к маку подключено больше одного устройства; обычно он один.
    serial: str | None = None
    max_steps: int = DEFAULT_MAX_STEPS
    # Короткие структурные сообщения о ходе прогона («шаг 3: 42 элемента, click»). Ни текста
    # экрана, ни заметок здесь нет: логи мака читаемы, а содержимое чужой переписки в них не
    # оседает. Нужны ровно затем, чтобы по логу было видно, на чём прогон застрял.
    progress: Callable[[str], None] | None = None
    notes: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        # Устройство выбирается один раз, в начале прогона: если его выдернули по дороге, узнать
        # об этом нужно сразу и с внятной причиной, а не на середине работы с чужим экраном.
        self.serial = android.pick_device(self.serial)

    def _tell(self, message: str) -> None:
        """Сообщить о ходе прогона, если за нами кто-то наблюдает."""
        if self.progress:
            self.progress(message)

    # ---------- взаимодействие с моделью ----------

    def _ask(self, task: str, screen_text: str, last_action: str) -> str:
        """Спросить модель, что делать дальше.

        В промпт уходит только текущий экран — прошлые не попадают. Это и есть скользящее окно:
        размер контекста не зависит от числа шагов.
        """
        notes_block = "\n".join(f"- {note}" for note in self.notes) or "(пока пусто)"
        user = (
            f"ЗАДАЧА: {task}\n\n"
            f"УЖЕ ИЗВЕСТНО:\n{notes_block}\n\n"
            f"ПОСЛЕДНЕЕ ДЕЙСТВИЕ: {last_action or '(начало работы)'}\n\n"
            f"СОСТОЯНИЕ ЭКРАНА:\n{screen_text}\n\n"
            f"Что делаешь?"
        )
        payload = {
            "model": LLM_MODEL,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user},
            ],
            "temperature": 0.6,
            "top_p": 0.95,
            # Лимит с большим запасом: Gemma «думающая» и тратит 300–500 токенов на рассуждения
            # даже в простом шаге. При 400 действие не помещалось — модель обрывалась с пустым
            # ответом, и цикл вставал с «модель не выдала действие».
            "max_tokens": 2500,
        }
        headers = {"Content-Type": "application/json"}
        if LLM_API_KEY:
            headers["Authorization"] = f"Bearer {LLM_API_KEY}"

        request = urllib.request.Request(
            f"{LLM_BASE_URL}/chat/completions",
            data=json.dumps(payload).encode(),
            headers=headers,
        )
        try:
            with urllib.request.urlopen(request, timeout=LLM_TIMEOUT) as response:
                data = json.load(response)
        except urllib.error.HTTPError as error:
            body = error.read().decode()[:300]
            raise RuntimeError(f"модель вернула HTTP {error.code}: {body}") from error
        except urllib.error.URLError as error:
            raise RuntimeError(f"модель недоступна ({LLM_BASE_URL}): {error}") from error

        message = data["choices"][0]["message"]
        content = (message.get("content") or "").strip()
        if not content:
            # Пустой content при непустом reasoning означает обрыв по лимиту токенов: модель не
            # успела закончить размышления. Это стоит называть своим именем, иначе выглядит как
            # молчание модели.
            usage = data.get("usage", {}) or {}
            reasoning = (usage.get("completion_tokens_details") or {}).get("reasoning_tokens", 0)
            if reasoning:
                raise RuntimeError(
                    f"модель израсходовала {reasoning} токенов на размышления и не успела "
                    f"выдать действие — подними max_tokens в agent.py"
                )
        return content

    # ---------- разбор ответа ----------

    def _parse(self, reply: str) -> tuple[str, str, list[str]]:
        """Вытащить заметки, действие и его аргумент.

        Отделяем ТОЛЬКО глагол, всё остальное оставляем в detail целиком. Резать по «|» здесь
        нельзя: номер элемента стоит перед разделителем, и если унести его в action, исполнитель
        начнёт искать номер внутри текста и найдёт число из задачи — это уже случалось.
        """
        found_notes: list[str] = []
        action = ""
        detail = ""
        for line in reply.splitlines():
            line = line.strip()
            if line.upper().startswith("NOTE:"):
                found_notes.append(line[5:].strip())
            elif line.upper().startswith("ACTION:") and not action:
                body = line[7:].strip()
                parts = body.split(None, 1)
                action = parts[0].lower() if parts else ""
                detail = parts[1].strip() if len(parts) > 1 else ""
        if not action:
            # Модель не последовала формату — ищем хоть что-то похожее.
            match = re.search(r"(click|type|press|scroll|done)\s*([^\n]*)", reply, re.I)
            if match:
                action = match.group(1).lower()
                detail = match.group(2).strip()
        return action, detail, found_notes

    # ---------- действия ----------

    @staticmethod
    def _pick(detail: str, elements: list):
        """Найти элемент по номеру, который назвала модель.

        Берём ПЕРВОЕ число — это номер элемента. Текст для ввода идёт после «|» и на поиск
        номера не влияет.
        """
        match = re.search(r"\d+", detail)
        if not match:
            return None
        index = int(match.group())
        return next((element for element in elements if element.index == index), None)

    @staticmethod
    def _bad_index(action: str, detail: str, elements: list) -> str:
        """Сообщение о неверном номере — модель увидит его и исправится."""
        match = re.search(r"\d+", detail)
        got = match.group() if match else "(номер не указан)"
        return (
            f"{action}: элемента №{got} нет. "
            f"В списке номера от 1 до {len(elements)} — выбери номер из списка."
        )

    def _execute(self, action: str, detail: str, elements: list) -> str:
        """Выполнить действие и вернуть его описание для следующего запроса.

        Номер переводится в координаты здесь: модель координат не видит и не угадывает, поэтому
        промахи исключены по построению. В описание для модели попадает название элемента — оно
        нужно ей, чтобы понимать, что произошло; в лог сервера уходит только глагол.
        """
        if action.startswith("click"):
            target = self._pick(detail, elements)
            if target is None:
                return self._bad_index("click", detail, elements)
            android.tap(*target.center, serial=self.serial)
            return f'click {target.index} ({target.short_role()} "{target.label[:40]}")'

        if action.startswith("type"):
            target = self._pick(detail, elements)
            if target is None:
                return self._bad_index("type", detail, elements)
            text = detail.split("|", 1)[1].strip() if "|" in detail else ""
            if not text:
                return "type — не указан текст, повтори в формате: type N | текст"
            android.tap(*target.center, serial=self.serial)
            android.clear_field(target, self.serial)
            warning = android.type_text(text, self.serial)
            return f'type {target.index} "{text}"' + (f" [{warning}]" if warning else "")

        if action.startswith("press"):
            key = detail.strip().lower() or "enter"
            if "enter" in key or "return" in key:
                key = "enter"
            android.press_key(key, self.serial)
            return f"press {key}"

        if action.startswith("scroll"):
            down = "up" not in detail.lower()
            if down:
                android.scroll_down(self.serial)
                return "scroll down"
            # Вверх на телефоне не прокручиваем: в промпте такого действия нет, а смахивание
            # вверх на длинной выдаче возвращает страницу не туда, куда модель ожидала. Сказать
            # об этом прямо дешевле, чем молча ничего не сделать.
            return "scroll up — не поддерживается, прокрутка только вниз"

        return f"неизвестное действие: {action} {detail}"

    # ---------- основной цикл ----------

    def _read(self):
        """Прочитать текущий экран телефона.

        Отдельным методом, потому что чтение нужно в двух местах: в начале шага (там важен текст
        для модели) и в ожидании смены экрана (там важен только отпечаток). Сбой чтения поднимает
        RuntimeError — вызывающий решает, обрывать прогон или подождать.
        """
        return android.read_page(self.serial)

    def run(self, task: str) -> AgentResult:
        """Выполнить задачу и вернуть то, что агент добыл.

        Прогон всегда начинается со стартовой страницы в Chrome: без этой привязки агент получает
        первым экраном то, что решит показать сам Chrome, — и спокойно начинает работать там, где
        оказался. Так уже было дважды: агент оказался в приложении Google вместо браузера, а на
        телефоне владельца Chrome открылся на восстановленной вкладке Google Flights, и агент
        искал «что такое ллм» в форме поиска авиабилетов.
        """
        # Экран гасится сам по таймауту, а на погашенном экране команды ввода игнорируются
        # молча: агент слал бы клики в никуда. Поэтому будим и просим не гасить до конца работы.
        android.wake(self.serial)
        time.sleep(0.5)
        # Стартовая страница открывается всегда, а не «если мы не в Chrome»: браузер, открытый на
        # чужой вкладке, — это тоже Chrome, и такая проверка пропустила бы открытие.
        android.open_page(START_URL, self.serial)
        android.ensure_chrome(self.serial)
        if DEBUG:
            self._tell(f"задача: {task}")

        last_action = ""
        seen_pages: dict[int, int] = {}
        fail_streak = 0
        scroll_streak = 0

        for step in range(1, self.max_steps + 1):
            try:
                page = self._read()
            except RuntimeError as error:
                # Чаще всего это отключение телефона по USB: дальше работать нечем, и лучше
                # сказать об этом прямо, чем падать стектрейсом посреди чужого прогона.
                return AgentResult(
                    answer=f"Работу прервал на шаге {step}: {error}. Известно: {self.notes}",
                    steps=step,
                    stop_reason=str(error),
                )
            screen_text = android.format_for_model(page)
            signature = page.signature
            # Что именно видел агент, принимая решение. Без этого разобрать «он пошёл не туда»
            # нечем: в обычном логе остаются только счётчики элементов и глагол действия.
            if DEBUG:
                self._tell(f"шаг {step}, экран ({android.current_package(self.serial)}):\n{screen_text}")

            # Ушли из Chrome — вернуть, иначе агент начнёт действовать в чужом приложении.
            package = android.current_package(self.serial)
            if package and package != android.CHROME_PACKAGE:
                android.ensure_chrome(self.serial)
                self._tell(f"шаг {step}: вернул в Chrome (был в {package})")
                continue

            # Защита от зацикливания: один и тот же экран слишком часто — значит агент ходит по
            # кругу, и надо останавливаться, а не жечь лимит шагов.
            seen_pages[signature] = seen_pages.get(signature, 0) + 1
            if seen_pages[signature] > 4:
                return AgentResult(
                    answer=f"Остановлен: экран повторился {seen_pages[signature]} раза. Известно: {self.notes}",
                    steps=step,
                    stop_reason="экран не меняется",
                )

            reply = self._ask(task, screen_text, last_action)
            action, detail, found_notes = self._parse(reply)
            self.notes.extend(note for note in found_notes if note)
            if DEBUG:
                self._tell(f"шаг {step}, модель ответила: {reply.strip()[:400]}")

            if not action:
                return AgentResult(
                    answer=f"Модель не выдала действие. Ответ: {reply[:200]}",
                    steps=step,
                    stop_reason="модель нарушила формат",
                )
            if action.startswith("done"):
                # Заметки идут в ответ вместе с финальной репликой: модель часто пишет «готово»
                # коротко, а весь добытый текст остаётся в заметках — без них ответ в чат
                # пришёл бы пустым.
                answer = detail or reply
                if self.notes:
                    answer = f"{answer}\n\nДобытые факты:\n" + "\n".join(f"- {n}" for n in self.notes)
                return AgentResult(answer=answer, steps=step)

            last_action = self._execute(action, detail, page.elements)
            self._tell(f"шаг {step}: экран {len(page.elements)} элем., {action}")
            # В обычном режиме в лог уходит только глагол: подпись элемента — это текст со
            # страницы, ему в логах мака не место.
            if DEBUG:
                self._tell(f"шаг {step}, выполнено: {last_action}")

            # Если действие не срабатывает подряд, сообщаем модели об этом прямым текстом: сама
            # она этого не замечает и повторяет одно и то же, пока не кончится лимит шагов.
            if "нет такого элемента" in last_action or "не указан текст" in last_action:
                fail_streak += 1
                if fail_streak >= 2:
                    last_action += (
                        " ← это уже не срабатывало дважды. Смени тактику: "
                        "прокрути экран или выбери другой элемент."
                    )
            else:
                fail_streak = 0

            # Прокрутка — самый частый способ застрять: модель листает страницу, не находя
            # ответа, и тратит на это весь лимит шагов. После трёх подряд говорим прямо.
            if last_action.startswith("scroll"):
                scroll_streak += 1
                if scroll_streak >= 3:
                    last_action += (
                        " ← ты прокрутил уже три раза подряд и не нашёл нужного. "
                        "Не прокручивай больше: вернись назад кнопкой Back или "
                        "выдай ответ тем, что уже известно (ACTION: done)."
                    )
            else:
                scroll_streak = 0

            # Ждём, пока экран реально изменится: иначе следующее чтение вернёт старое состояние
            # и решение будет принято по устаревшим данным.
            waited = 0.0
            while waited < PAGE_CHANGE_TIMEOUT:
                time.sleep(0.4)
                waited += 0.4
                try:
                    if self._read().signature != signature:
                        break
                except RuntimeError as error:
                    return AgentResult(
                        answer=f"Работу прервал на шаге {step}: {error}. Известно: {self.notes}",
                        steps=step,
                        stop_reason=str(error),
                    )

        return AgentResult(
            answer=f"Лимит шагов исчерпан. Известно: {self.notes}",
            steps=self.max_steps,
            stop_reason="лимит шагов",
        )
