"""Управление телефоном через ADB: агент из раздела «Чат» работает на нём, а не на маке.

Почему телефон, а не мак: агент занимает устройство целиком на всё время прогона, и когда он
работает на маке, мак становится недоступен. Телефон лежит подключённым по USB и работает, а
машина остаётся свободной — и заодно продолжает обслуживать остальной раздел «Чат».

Почему Android тут даже удобнее мака:
- `uiautomator dump` — штатный фреймворк Google для тестирования. Отдаёт готовый XML с текстом,
  идентификаторами и границами элементов, без трюков вроде пробуждения дерева доступности.
- `input tap` — настоящее касание в подсистеме ввода, а не инжекция в браузер.
- Реальное устройство с реальным аккаунтом выглядит для сайтов обычным пользователем, поэтому
  и выдача поисковиков приходит нормальная, без капчи.

Главное ограничение: `input text` не умеет юникод — только ASCII. Кириллицу он молча теряет,
поле остаётся пустым, и агент зацикливается; поэтому не-ASCII текст здесь не набирается, а
честно возвращается пометкой о том, что введено частично (см. [type_text]).
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

# Где искать adb: сначала PATH, потом стандартные места установки SDK.
ADB_CANDIDATES = [
    "adb",
    "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
    os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"),
]

# Сколько ждать ответа от устройства. Прошивка отвечает медленно, но
# бесконечно ждать нельзя — иначе агент зависнет на первом же шаге.
ADB_TIMEOUT = 30

# Роли узлов, по которым есть смысл кликать.
CLICKABLE_CLASSES = {
    "android.widget.Button",
    "android.widget.ImageButton",
    "android.widget.EditText",
    "android.widget.TextView",  # часто используется как ссылка
    "android.widget.CheckBox",
    "android.widget.RadioButton",
    "android.widget.Switch",
    "android.widget.ImageView",
    "android.widget.AutoCompleteTextView",
}


def find_adb() -> str:
    """Найти исполняемый файл adb. Бросает исключение, если его нет."""
    for candidate in ADB_CANDIDATES:
        resolved = shutil.which(candidate) or (candidate if os.path.exists(candidate) else None)
        if resolved:
            return resolved
    raise RuntimeError(
        "adb не найден. Установи: brew install android-platform-tools "
        "или укажи путь к platform-tools из Android SDK"
    )


# Путь к adb ищется лениво, а не при импорте модуля. Так сервис (`server.py`) поднимается и
# без установленного adb, и на вопрос «почему агент не работает» отвечает причиной, а не
# отказом запуститься: иначе CloudlyRu видел бы «агент недоступен» там, где дело в одной
# ненайденной программе.
_ADB: str | None = None


def adb_path() -> str:
    """Путь к adb: первый найденный вариант, запоминается до конца работы процесса."""
    global _ADB
    if _ADB is None:
        _ADB = find_adb()
    return _ADB


def run(*args: str, serial: str | None = None) -> str:
    """Выполнить команду adb и вернуть её вывод текстом.

    serial нужен, когда подключено несколько устройств — без него adb работать откажется.
    Ненулевой код возврата превращается в RuntimeError с причиной от adb: она попадает и в лог
    сервиса, и в ответ чату, поэтому в ней должен быть текст самой утилиты, а не «что-то пошло
    не так».
    """
    command = [adb_path()]
    if serial:
        command += ["-s", serial]
    command += list(args)
    result = subprocess.run(command, capture_output=True, timeout=ADB_TIMEOUT)
    if result.returncode != 0:
        error = result.stderr.decode(errors="replace").strip()
        raise RuntimeError(f"adb {' '.join(args)} -> ошибка: {error}")
    return result.stdout.decode(errors="replace")


def devices() -> list[str]:
    """Список подключённых устройств в состоянии device."""
    output = run("devices")
    found = []
    for line in output.splitlines()[1:]:
        line = line.strip()
        if line and "\t" in line:
            serial, state = line.split("\t", 1)
            if state.strip() == "device":
                found.append(serial.strip())
    return found


def pick_device(serial: str | None = None) -> str:
    """Выбрать устройство: указанное или единственное подключённое."""
    if serial:
        return serial
    found = devices()
    if not found:
        raise RuntimeError(
            "нет подключённых устройств. Включи на телефоне «Отладку по USB» "
            "и подтверди доступ на экране"
        )
    if len(found) > 1:
        raise RuntimeError(f"подключено несколько устройств: {found}. Укажи serial явно")
    return found[0]


@dataclass
class Element:
    """Один элемент интерфейса, найденный в разметке экрана."""

    index: int
    label: str
    x: int
    y: int
    w: int
    h: int
    clickable: bool
    class_name: str
    # Полный текст узла — нужен, чтобы вытащить содержимое экрана.
    full_text: str = field(default="", repr=False)

    @property
    def center(self) -> tuple[int, int]:
        """Центр элемента — по нему безопаснее попадать, чем по краю."""
        return self.x + self.w // 2, self.y + self.h // 2

    def short_role(self) -> str:
        """Короткое имя класса для промпта."""
        return self.class_name.rsplit(".", 1)[-1].lower()


@dataclass
class PageView:
    """Экран целиком: чем кликать и что прочитать."""

    elements: list[Element]
    texts: list[str]
    package: str = ""

    @property
    def signature(self) -> int:
        """Отпечаток экрана — по нему определяем, что он сменился."""
        return hash((self.package, tuple(e.label for e in self.elements[:40])))


# Пакет Chrome на Android. Агент должен работать в браузере, а не бродить
# по приложениям: там другой интерфейс, другой контекст и больше шума.
CHROME_PACKAGE = "com.android.chrome"
CHROME_ACTIVITY = "com.google.android.apps.chrome.Main"


def current_package(serial: str | None = None) -> str:
    """Пакет приложения, которое сейчас на переднем плане.

    Без этого агент не знает, где он находится: стартовав с чужого экрана,
    он спокойно начинает работать в приложении Google вместо браузера —
    это уже случилось на живом прогоне.
    """
    try:
        output = run("shell", "dumpsys", "window", serial=serial)
    except RuntimeError:
        return ""
    for line in output.splitlines():
        if "mCurrentFocus" in line or "mFocusedApp" in line:
            match = re.search(r"([a-zA-Z][a-zA-Z0-9_.]+)/", line)
            if match:
                return match.group(1)
    return ""


def open_chrome(serial: str | None = None) -> None:
    """Открыть сам Chrome, без конкретной ссылки.

    Нужен для возврата в браузер, когда агент ушёл в другое приложение: страница, на которой он
    работал, остаётся той же — открывать её заново здесь нельзя.
    """
    serial = pick_device(serial)
    run("shell", "am", "start", "-n", f"{CHROME_PACKAGE}/{CHROME_ACTIVITY}", serial=serial)
    time.sleep(2.5)


def open_page(url: str, serial: str | None = None) -> None:
    """Открыть адрес именно в Chrome, даже если браузер уже на переднем плане.

    Отдельно от [ensure_chrome] и намеренно без проверки текущего пакета: Chrome, открытый на
    произвольной странице, — это тоже Chrome, и «мы уже там» пропустило бы открытие стартовой
    страницы. На живом прогоне это и случилось: на телефоне оставалась открыта вкладка Google
    Flights, агент получил её как первый экран и принялся искать «что такое ллм» в форме поиска
    авиабилетов.

    Намерение адресуется Chrome по имени компонента, а не отдаётся браузеру по умолчанию: если
    на телефоне по умолчанию открывается другое приложение, агент работал бы в нём, а проверка
    привязки вытаскивала бы его обратно в Chrome — уже на пустую страницу.
    """
    serial = pick_device(serial)
    run(
        "shell",
        "am",
        "start",
        "-a",
        "android.intent.action.VIEW",
        "-n",
        f"{CHROME_PACKAGE}/{CHROME_ACTIVITY}",
        "-d",
        url,
        serial=serial,
    )
    # Запас на запуск холодного Chrome и загрузку страницы: без него первый же шаг прочитает
    # пустой экран и модель начнёт действовать вслепую.
    time.sleep(4.0)


def ensure_chrome(serial: str | None = None) -> str:
    """Гарантировать, что агент работает в Chrome.

    Возвращает описание того, что сделано: пустая строка, если уже в Chrome, иначе — что именно
    открыли. Агент обязан сообщать об этом в лог, иначе непонятно, почему экран вдруг сменился.
    """
    serial = pick_device(serial)
    package = current_package(serial)
    if package == CHROME_PACKAGE:
        return ""
    open_chrome(serial)
    return f"открыл Chrome (был в {package or 'неизвестном приложении'})"


def wake(serial: str | None = None) -> None:
    """Разбудить экран и не дать ему погаснуть во время работы.

    Без включённого экрана команды ввода игнорируются молча — агент будет
    слать клики в никуда и не поймёт, почему ничего не происходит.
    """
    serial = pick_device(serial)
    run("shell", "svc", "power", "stayon", "true", serial=serial)
    run("shell", "input", "keyevent", "KEYCODE_WAKEUP", serial=serial)


def dump_ui(serial: str | None = None) -> str:
    """Снять разметку текущего экрана в XML.

    uiautomator пишет дамп в файл на устройстве, оттуда его и забираем:
    вернуть XML в stdout он не умеет.
    """
    remote = "/sdcard/window_dump.xml"
    run("shell", "uiautomator", "dump", remote, serial=serial)
    return run("exec-out", "cat", remote, serial=serial)


def _bounds(node: ET.Element) -> tuple[int, int, int, int]:
    """Разобрать атрибут bounds вида «[x1,y1][x2,y2]» в координаты и размер."""
    match = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
    if not match:
        return 0, 0, 0, 0
    x1, y1, x2, y2 = (int(value) for value in match.groups())
    return x1, y1, x2 - x1, y2 - y1


def read_page(serial: str | None = None) -> PageView:
    """Прочитать текущий экран: элементы для действий и текст для чтения."""
    serial = pick_device(serial)
    root = ET.fromstring(dump_ui(serial))

    elements: list[Element] = []
    texts: list[str] = []
    # Пакет из разметки приходит пустым, поэтому спрашиваем систему.
    package = root.get("package") or current_package(serial)

    for node in root.iter("node"):
        x, y, w, h = _bounds(node)
        if w <= 0 or h <= 0:
            continue

        text = (node.get("text") or "").strip()
        description = (node.get("content-desc") or "").strip()
        label = text or description

        # Текст экрана собираем отдельно и целиком: именно в нём лежит ответ,
        # а кликать по нему не обязательно.
        if text and len(text) >= 2 and text not in texts:
            texts.append(text)

        if node.get("clickable") != "true" and node.get("class", "") not in CLICKABLE_CLASSES:
            continue
        if node.get("enabled") == "false":
            continue

        elements.append(
            Element(
                index=len(elements) + 1,
                label=label[:120],
                x=x,
                y=y,
                w=w,
                h=h,
                clickable=node.get("clickable") == "true",
                class_name=node.get("class", ""),
                full_text=text,
            )
        )

    return PageView(elements=elements, texts=texts, package=package)


def format_for_model(page: PageView, element_limit: int = 60, text_limit: int = 1200) -> str:
    """Собрать то, что увидит модель.

    Лимиты здесь ниже, чем на десктопе: экран телефона показывает меньше,
    а элементы крупнее, поэтому длинный список только запутает модель.
    """
    lines = ["КЛИКАБЕЛЬНЫЕ ЭЛЕМЕНТЫ:"]
    for element in page.elements[:element_limit]:
        kind = "кликабельно" if element.clickable else "текст"
        lines.append(f'{element.index}. {element.short_role()} ({kind}) "{element.label}"')
    if len(page.elements) > element_limit:
        lines.append(f"... ещё {len(page.elements) - element_limit}")

    if page.texts:
        lines.append("")
        lines.append("ТЕКСТ НА ЭКРАНЕ:")
        used = 0
        for chunk in page.texts:
            if used + len(chunk) > text_limit:
                lines.append("... (обрезано)")
                break
            lines.append(chunk)
            used += len(chunk)

    return "\n".join(lines)


def tap(x: int, y: int, serial: str | None = None) -> None:
    """Коснуться экрана в точке — настоящее событие подсистемы ввода."""
    run("shell", "input", "tap", str(x), str(y), serial=serial)
    time.sleep(0.4)


def swipe(x1: int, y1: int, x2: int, y2: int, ms: int = 300, serial: str | None = None) -> None:
    """Смахнуть — используется для прокрутки и перелистывания."""
    run("shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), str(ms), serial=serial)
    time.sleep(0.5)


def scroll_down(serial: str | None = None) -> None:
    """Прокрутить экран вниз смахиванием снизу вверх."""
    width, height = screen_size(serial)
    swipe(width // 2, int(height * 0.75), width // 2, int(height * 0.3), serial=serial)


def screen_size(serial: str | None = None) -> tuple[int, int]:
    """Размер экрана в пикселях — нужен для расчёта точек смахивания."""
    output = run("shell", "wm", "size", serial=serial)
    match = re.search(r"(\d+)x(\d+)", output)
    if not match:
        return 1080, 1920
    return int(match.group(1)), int(match.group(2))


def type_text(text: str, serial: str | None = None) -> str:
    """Ввести текст. Возвращает пометку о том, удалось ли это полностью.

    `input text` понимает только ASCII: юникод он молча теряет. Поэтому
    не-ASCII текст отправляем как есть и сообщаем вызывающему, что часть
    символов может не дойти — это честнее, чем тихо получить пустое поле.
    """
    ascii_only = text.isascii()
    safe = text.replace(" ", "%s") if ascii_only else re.sub(r"[^\x20-\x7e]", "", text)
    if safe:
        run("shell", "input", "text", safe, serial=serial)
        time.sleep(0.5)
    if not ascii_only:
        return f"введено частично (ASCII-часть), юникод требует отдельной IME: «{text}»"
    return ""


def press_key(key: str, serial: str | None = None) -> None:
    """Нажать системную клавишу: enter, back, home, tab."""
    mapping = {
        "enter": "KEYCODE_ENTER",
        "return": "KEYCODE_ENTER",
        "back": "KEYCODE_BACK",
        "home": "KEYCODE_HOME",
        "tab": "KEYCODE_TAB",
        "delete": "KEYCODE_DEL",
        "search": "KEYCODE_SEARCH",
    }
    code = mapping.get(key.lower())
    if code is None:
        raise ValueError(f"неизвестная клавиша: {key}")
    run("shell", "input", "keyevent", code, serial=serial)
    time.sleep(0.5)


def clear_field(element: Element, serial: str | None = None) -> bool:
    """Очистить поле ввода: фокус, затем выделить всё и удалить.

    На Android нет прямого доступа к значению поля, как через AXValue на macOS,
    поэтому действуем клавишами — сочетание Cmd+A тут не зависит от раскладки,
    потому что системные клавиши идут кодами, а не символами.
    """
    tap(*element.center, serial=serial)
    # Перемещаем курсор в конец и стираем посимвольно — универсально
    # работает и там, где «выделить всё» не поддерживается.
    run("shell", "input", "keyevent", "KEYCODE_MOVE_END", serial=serial)
    for _ in range(min(len(element.full_text), 60)):
        run("shell", "input", "keyevent", "KEYCODE_DEL", serial=serial)
    time.sleep(0.3)
    return True


def device_state() -> tuple[str | None, str]:
    """Состояние подключения — для ручки `/health` и для внятной ошибки в чате.

    Возвращает пару «serial или None» и «что именно не так» человеческим текстом. Отдельной
    функцией, потому что это единственный вопрос, который задают в двух местах: перед прогоном
    (чтобы не начинать работу на отключённом телефоне) и по запросу с сервера, когда человек
    спрашивает, почему агент недоступен.
    """
    try:
        found = devices()
    except RuntimeError as error:
        # Чаще всего это отсутствие самого adb (не установлен platform-tools) — причина
        # отличается от «телефон не подключён», и в чате её нужно назвать своей.
        return None, str(error)
    if not found:
        return None, "нет подключённых устройств: включи «Отладку по USB» и подтверди доступ"
    if len(found) > 1:
        # Выбирать за человека нельзя: прогон пойдёт не на том телефоне, которого он ждёт.
        return None, f"подключено несколько устройств ({', '.join(found)}): нужно одно"
    return found[0], ""
