#!/usr/bin/env python3
"""phone.py — управление браузером на телефоне: ADB плюс Chrome DevTools Protocol.

Зачем именно так, а не снимками экрана, как было в прежнем агенте. Телефон нужен ради
двух вещей: его браузер (настоящий Chrome, с сессиями и домашним адресом) и его
поисковая строка. Читать экран через `uiautomator` и тыкать по координатам можно, но
это дорого и неточно: текст теряется, разметка не видна, а каждый шаг требует снимка.
Chrome на Android отдаёт отладочный сокет (`chrome_devtools_remote`), через который
доступен тот же протокол, что у инструментов разработчика в настольном браузере:

  - `Target.createTarget` — открыть вкладку с адресом (вкладка появляется на экране,
    человек видит, что агент действительно работает на телефоне);
  - `Runtime.evaluate` — выполнить JS на странице и получить точный текст и ссылки;
  - `Input.insertText` — ввести текст в сфокусированное поле ЛЮБЫМ юникодом (старый
    агент этого не умел: `adb shell input text` понимает только ASCII, и кириллица
    молча терялась — поэтому он и запрещал себе набирать запрос в поле);
  - `Input.dispatchMouseEvent` — нажать кнопку поиска там, где форма не отправляется
    по Enter (на мобильном Amazon именно так).

ADB при этом нужен для того, чего в CDP нет: разбудить телефон, поднять Chrome,
проверить модель устройства. Никаких тыков по координатам в обычном пути нет.
"""

from __future__ import annotations

import asyncio
import json
import re
import subprocess
import time
import urllib.request

import websockets

# Пути к adb на этом маке: `adb` не лежит в PATH, а живёт в комплекте Android-инструментов.
ADB_CANDIDATES = (
    "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
    "/opt/homebrew/bin/adb",
    "adb",
)

# Пакет и активность Chrome: агент обязан работать в браузере, а не в приложении Google.
CHROME_PACKAGE = "com.android.chrome"
CHROME_ACTIVITY = "com.google.android.apps.chrome.Main"

# Локальный порт, куда пробрасывается отладочный сокет Chrome. 9222 — стандартный, но
# если он занят другим процессом на маке, проброс молча не сработает, поэтому порт
# вынесен в константу и проверяется по ответу /json/version.
CDP_PORT = 9222
CDP_HTTP = f"http://127.0.0.1:{CDP_PORT}"

# Сколько ждать полной загрузки страницы и сколько — «дорисовки» после неё. Выдача
# поисковика и карточки товаров появляются скриптами уже после readyState=complete,
# поэтому одной готовности документа мало.
LOAD_TIMEOUT = 25.0
SETTLE_SECONDS = 2.0


class PhoneError(Exception):
    """Действие на телефоне не удалось: текст пригоден для лога и для ответа клиенту."""


def find_adb() -> str:
    """Путь к adb: первый существующий из кандидатов."""
    import os

    for path in ADB_CANDIDATES:
        if path == "adb" or os.path.exists(path):
            return path
    raise PhoneError("adb не найден: телефон без него недоступен")


class Phone:
    """Телефон: adb-операции и одна переиспользуемая вкладка Chrome через CDP.

    Работает синхронно снаружи (`with Phone() as p: p.search(...)`) и асинхронно внутри —
    так вызывающий код не думает про цикл событий, а HTTP-сервер остаётся простым.
    """

    def __init__(self, serial: str | None = None):
        self.adb = find_adb()
        self.serial = serial
        self._loop: asyncio.AbstractEventLoop | None = None
        self._ws = None
        self._target_id: str | None = None
        self._session: str | None = None
        self._seq = 0
        # Все вкладки, которые открыл этот объект. Список, а не одно поле: за прогон агент
        # может открыть несколько вкладок, и «закрыть последнюю» оставило бы мусор на
        # телефоне — ровно это и случилось на пробах: в Chrome осталось девять чужих вкладок.
        self._created: list[str] = []

    # ---------- adb ----------

    def _adb(self, *args: str, timeout: float = 60.0) -> str:
        """Выполняет команду adb и возвращает stdout; ошибку превращает в PhoneError."""
        cmd = [self.adb]
        if self.serial:
            cmd += ["-s", self.serial]
        cmd += list(args)
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired as e:
            raise PhoneError(f"adb не ответил за {timeout:.0f} с: {' '.join(args)}") from e
        if res.returncode != 0:
            raise PhoneError(f"adb {args[0]} вернул {res.returncode}: {(res.stderr or '').strip()[:200]}")
        return res.stdout

    def device(self) -> str:
        """Серийный номер подключённого телефона; без него работать нечем."""
        if self.serial:
            return self.serial
        out = subprocess.run([self.adb, "devices"], capture_output=True, text=True, timeout=30).stdout
        for line in out.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "device":
                self.serial = parts[0]
                return parts[0]
        raise PhoneError("телефон не подключён по USB (adb не видит устройство)")

    def prepare(self) -> None:
        """Готовит телефон к работе: будит экран, поднимает Chrome, пробрасывает сокет отладки.

        Chrome поднимаем всегда, а не «если не запущен»: агент должен начинать с браузера,
        а не с того приложения, которое осталось открытым (на живом прогоне прежней версии
        агент стартовал в форме поиска авиабилетов и искал там «что такое ллм»).
        """
        self.device()
        self._adb("shell", "input", "keyevent", "KEYCODE_WAKEUP", timeout=20)
        time.sleep(0.5)
        self._adb(
            "shell", "am", "start", "-n", f"{CHROME_PACKAGE}/{CHROME_ACTIVITY}",
            "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER",
            timeout=30,
        )
        time.sleep(2.0)
        self._adb("forward", f"tcp:{CDP_PORT}", "localabstract:chrome_devtools_remote", timeout=30)
        for _ in range(10):
            try:
                self._http_json("/json/version")
                return
            except Exception:
                time.sleep(0.7)
        raise PhoneError("Chrome не отдал отладочный сокет (включена ли отладка по USB?)")

    # ---------- CDP ----------

    def _http_json(self, path: str) -> dict:
        """GET на HTTP-часть CDP."""
        with urllib.request.urlopen(f"{CDP_HTTP}{path}", timeout=10) as r:
            return json.load(r)

    def _run(self, coro):
        """Выполняет корутину в постоянном цикле событий (соединение с Chrome живёт между вызовами)."""
        if self._loop is None:
            self._loop = asyncio.new_event_loop()
        return self._loop.run_until_complete(coro)

    async def _connect(self) -> None:
        """Подключается к browser-сокету Chrome и открывает одну переиспользуемую вкладку."""
        if self._ws is not None:
            return
        version = self._http_json("/json/version")
        self._ws = await websockets.connect(version["webSocketDebuggerUrl"], max_size=40 * 1024 * 1024)
        created = await self._call("Target.createTarget", {"url": "about:blank"})
        self._target_id = created["targetId"]
        self._created.append(self._target_id)
        attached = await self._call("Target.attachToTarget", {"targetId": self._target_id, "flatten": True})
        self._session = attached["sessionId"]
        await self._call("Page.enable")
        await self._call("Runtime.enable")

    async def _call(self, method: str, params: dict | None = None, timeout: float = 30.0) -> dict:
        """Один вызов CDP с ожиданием ответа по идентификатору."""
        self._seq += 1
        mid = self._seq
        msg: dict = {"id": mid, "method": method, "params": params or {}}
        if self._session:
            msg["sessionId"] = self._session
        await self._ws.send(json.dumps(msg))
        deadline = time.time() + timeout
        while time.time() < deadline:
            raw = await asyncio.wait_for(self._ws.recv(), timeout=max(1.0, deadline - time.time()))
            data = json.loads(raw)
            if data.get("id") == mid:
                if "error" in data:
                    raise PhoneError(f"{method}: {data['error'].get('message', data['error'])}")
                return data.get("result", {})
        raise PhoneError(f"{method}: Chrome не ответил за {timeout:.0f} с")

    def open(self, url: str, settle: float = SETTLE_SECONDS) -> None:
        """Открывает адрес в той самой вкладке и ждёт, пока страница дорисуется."""
        self._run(self._open(url, settle))

    async def _open(self, url: str, settle: float) -> None:
        await self._connect()
        await self._call("Target.activateTarget", {"targetId": self._target_id})
        await self._call("Page.navigate", {"url": url}, timeout=LOAD_TIMEOUT)
        await self._wait_ready()

    async def _wait_ready(self) -> None:
        """Ждёт `readyState=complete`, затем паузу на дорисовку скриптами."""
        deadline = time.time() + LOAD_TIMEOUT
        while time.time() < deadline:
            try:
                state = await self._evaluate("document.readyState")
            except PhoneError:
                state = None
            if state == "complete":
                await asyncio.sleep(SETTLE_SECONDS)
                return
            await asyncio.sleep(0.4)
        # Не ошибка: часть страниц (бесконечная лента) не доходит до complete — берём как есть.

    def eval_js(self, expression: str, timeout: float = 30.0):
        """Выполняет JS на текущей странице и возвращает значение."""
        return self._run(self._evaluate(expression, timeout))

    async def _evaluate(self, expression: str, timeout: float = 30.0):
        res = await self._call(
            "Runtime.evaluate",
            {"expression": expression, "returnByValue": True, "awaitPromise": True},
            timeout=timeout,
        )
        if "exceptionDetails" in res:
            # Показываем НАСТОЯЩИЙ текст ошибки JS, а не дамп объекта: при отладке разбора
            # страниц важно, что именно не так в выражении, а не номера строк.
            details = res["exceptionDetails"]
            description = (details.get("exception") or {}).get("description") or details.get("text")
            raise PhoneError(f"JS упал: {str(description)[:300]}")
        return res.get("result", {}).get("value")

    def url(self) -> str:
        """Адрес открытой страницы."""
        return str(self.eval_js("location.href") or "")

    def settle(self, seconds: float) -> None:
        """Ждёт [seconds] секунд, пока страница дорисуется скриптами.

        Нужно после нажатия «искать»: выдача и карточки товаров появляются уже после
        готовности документа, и без этой паузы разбор увидит пустую страницу.
        """
        time.sleep(seconds)

    def title(self) -> str:
        """Заголовок открытой страницы."""
        return str(self.eval_js("document.title") or "").strip()

    def text(self, limit: int = 0) -> str:
        """Текст страницы: `innerText` без разметки, схлопнутые пробелы.

        [limit] > 0 обрезает текст по границе слова — так же, как это делает сервис
        чтения страниц на маке, чтобы модель не получала половину слова в конце.
        """
        raw = str(self.eval_js("document.body ? document.body.innerText : ''") or "")
        flat = re.sub(r"[ \t\u00a0]+", " ", raw)
        flat = re.sub(r"\n{3,}", "\n\n", flat).strip()
        if limit and len(flat) > limit:
            cut = flat.rfind(" ", 0, limit)
            flat = flat[: cut if cut > limit * 0.8 else limit].rstrip()
        return flat

    def type_text(self, text: str) -> None:
        """Вводит текст в сфокусированное поле — юникод поддерживается (CDP, не adb)."""
        self._run(self._call("Input.insertText", {"text": text}))

    def press_enter(self) -> None:
        """Нажимает Enter в текущем поле (не все формы это понимают — есть ещё [tap_selector])."""
        async def _press():
            for kind in ("keyDown", "keyUp"):
                await self._call("Input.dispatchKeyEvent", {
                    "type": kind, "key": "Enter", "code": "Enter", "text": "\r",
                    "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13,
                })
        self._run(_press())

    def tap_selector(self, selector: str) -> bool:
        """Нажимает элемент так, как это сделал бы палец: настоящий тап по его координатам.

        Именно так работает кнопка поиска на мобильном Amazon: отправку формы Enter там
        не запускает, а программный `element.click()` часть обработчиков не трогает.
        """
        box = self.eval_js(
            "(() => { const el = document.querySelector(%s); if (!el) return null;"
            " el.scrollIntoView({block:'center'}); const r = el.getBoundingClientRect();"
            " return {x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height}; })()"
            % json.dumps(selector)
        )
        if not box or not box.get("w"):
            return False
        self._run(self._tap(box["x"], box["y"]))
        return True

    async def _tap(self, x: float, y: float) -> None:
        for kind in ("mousePressed", "mouseReleased"):
            await self._call("Input.dispatchMouseEvent", {
                "type": kind, "x": x, "y": y, "button": "left", "clickCount": 1,
            })
        await asyncio.sleep(0.4)

    def tap_deep(self, selectors: tuple[str, ...]) -> bool:
        """Нажимает первый подходящий элемент, включая элементы внутри shadow DOM.

        `document.querySelector` в shadow-дерево не заглядывает, а современные сайты прячут туда
        именно поля и кнопки: у Reddit поисковая строка — это `textarea[name=q]` внутри
        `<faceplate-search-input>`, и обычный селектор её не видит. Ищем вручную по дереву,
        прокручиваем к элементу и жмём настоящим тапом по его координатам.
        """
        box = self.eval_js("""
        (() => {
          const sels = %s;
          const deep = (sel) => {
            const walk = (root, depth) => {
              if (depth > 6) return null;
              for (const el of root.querySelectorAll('*')) {
                if (el.shadowRoot) {
                  const hit = el.shadowRoot.querySelector(sel);
                  if (hit) return hit;
                  const nested = walk(el.shadowRoot, depth + 1);
                  if (nested) return nested;
                }
              }
              return null;
            };
            return document.querySelector(sel) || walk(document, 0);
          };
          for (const sel of sels) {
            const el = deep(sel);
            if (!el) continue;
            el.scrollIntoView({block: 'center'});
            const r = el.getBoundingClientRect();
            if (!r.width && !r.height) continue;
            return {x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height, sel};
          }
          return null;
        })()
        """ % json.dumps(list(selectors)))
        if not box or not box.get('w'):
            return False
        self._run(self._tap(box['x'], box['y']))
        return True

    def close(self) -> None:
        """Закрывает вкладку и соединение: за телефоном не должно оставаться мусора."""
        async def _shutdown():
            # Закрываем ВСЕ вкладки, которые открыл этот объект, и глушим их перебором:
            # одна непокрывшаяся вкладка не должна мешать закрыть остальные.
            for target in list(self._created):
                try:
                    if self._ws is not None:
                        await self._call("Target.closeTarget", {"targetId": target})
                except Exception:
                    pass
            self._created.clear()
            if self._ws is not None:
                try:
                    await self._ws.close()
                except Exception:
                    pass
        if self._loop is not None:
            try:
                self._loop.run_until_complete(_shutdown())
            except Exception:
                pass
            self._loop.close()
        self._ws = None

    def __enter__(self) -> "Phone":
        self.prepare()
        return self

    def __exit__(self, *_exc) -> None:
        self.close()
