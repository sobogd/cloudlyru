package ru.cloudly.cloudly_flutter

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.view.FlutterCallbackInformation
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Проход зеркала по требованию системы: периодически, но **не чаще** чем раз в пятнадцать
 * минут — это минимум `JobScheduler`, и система вправе задержать запуск (Doze, экономия
 * батареи), см. [SyncJobScheduler].
 *
 * Своя служба и свой движок, а не готовая библиотека фоновых задач. Причина одна: проходу
 * нужен тот же мост к Android, что и приложению, — номер файла в файловой системе (`inode`).
 * Без него переименование выглядит как «удалил и залил заново», и папка с видео уезжает
 * в облако второй раз. Готовые библиотеки поднимают движок сами и своих каналов в него
 * не пускают: добавить в чужой движок наш мост было бы нечем (у `FlutterEngine` в этом файле
 * это одна строка — `SyncBridge(...)` ниже).
 *
 * Работа идёт в отдельном изоляте, поэтому приложение это не задевает: свой движок, свои
 * соединения с базами. `jobFinished` вызывается всегда — иначе система держала бы задание
 * вечно. Если система останавливает задание, проход прерывается на ближайшей проверке:
 * недоделанное доедет следующим — сверка идемпотентна.
 *
 * ## Сколько времени отведено работе
 *
 * Три числа связаны по смыслу, поэтому живут в одном месте — здесь, и изолят спрашивает их
 * через канал ([BackgroundBridge] `budgets`), а не держит свою копию:
 *
 *  * `JOB_TIMEOUT_MS` — предохранитель службы: если изолят не ответил, движок закрывается;
 *  * `PASS_BUDGET_MS` — бюджет зеркала. Меньше предохранителя на [JOB_RESERVE_MS]: остаток
 *    нужен на очередь и на честный ответ системе, иначе проход оборвался бы на её таймауте;
 *  * `QUEUE_DEADLINE_MS` — до какого момента (от начала прохода) наполнять очередь: очередь
 *    подготовка, и запускать обход папок в последнюю минуту задания незачем.
 */
class SyncJobService : JobService() {

    private val main = Handler(Looper.getMainLooper())

    private var engine: FlutterEngine? = null
    private var bridge: BackgroundBridge? = null
    private var params: JobParameters? = null
    private var stopped = false

    /**
     * Система остановила задание — до того, как движок поднялся, или уже после.
     *
     * Флаг принадлежит заданию, а не мосту (`BackgroundBridge` создаётся позже, внутри
     * `startEngine`): иначе просьба об остановке, пришедшая в первые секунды, потерялась бы
     * совсем, и изолят начал бы семиминутный проход, который система уже прервала.
     */
    @Volatile
    private var stopRequested = false

    /**
     * Это задание уже ответило системе. Флаг принадлежит **экземпляру**, а не классу: служба
     * создаётся на каждый запуск, и `finish()` одного экземпляра не должен закрывать движок
     * другого. Раньше флаг был статическим, и `finish()` от прежнего экземпляра (его
     * предохранитель, его мост) сделал бы `finish()` нового задания пустым действием: движок
     * не закрылся бы, а `jobFinished` не вызвался — задание висело бы до таймаута системы.
     */
    private val ended = AtomicBoolean(false)

    override fun onStartJob(params: JobParameters?): Boolean {
        if (!running.compareAndSet(false, true)) {
            // проход уже идёт: второй не нужен, сверка всё равно увидит то же состояние
            return false
        }
        this.params = params
        this.stopped = false
        this.stopRequested = false
        ended.set(false)

        // Приложение на экране: там мгновенный режим, он замечает изменения за секунды.
        // Проход из фона не добавил бы ничего, зато полез бы в те же базы вторым соединением.
        if (AppPresence.foreground) {
            Log.i(TAG, "приложение на экране: проход делает мгновенный режим")
            running.set(false)
            return false
        }

        val handle = BackgroundSettings.callbackHandle(this)
        if (handle <= 0L) {
            // Задание не заведено (вышли из аккаунта) или настройки ещё не записаны.
            Log.i(TAG, "фоновая сверка не заведена: ничего не делаю")
            running.set(false)
            return false
        }

        startEngine(handle)
        // Предохранитель ставим сразу, а не после подъёма движка: если движок не встанет,
        // задание всё равно должно закончиться, а не висеть до таймаута системы
        armWatchdog()
        return true
    }

    /**
     * Поднимаем движок так же, как это делает приложение: сначала загрузчик Flutter, потом
     * движок с зарегистрированными плагинами (`shared_preferences`, шифрованное хранилище,
     * `sqflite`, `path_provider`), потом наш мост и только потом точка входа в Dart.
     *
     * Изолята может уже не быть — задание вправе отобрать в любой момент, в том числе между
     * `onStartJob` и этим колбэком: тогда движок не поднимается вовсе (см. [stopRequested]),
     * а не работает впустую до предохранителя.
     */
    private fun startEngine(handle: Long) {
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) loader.startInitialization(applicationContext)
        loader.ensureInitializationCompleteAsync(applicationContext, null, main) {
            if (ended.get()) return@ensureInitializationCompleteAsync
            if (stopRequested) {
                // задание отобрали, пока поднимался движок: проход начинать незачем
                Log.i(TAG, "задание остановлено до старта движка: проход не начинаю")
                finish(false, "система остановила задание")
                return@ensureInitializationCompleteAsync
            }

            // Движок поднимаем до того, как спрашивать точку входа: таблицу handle → функция
            // ведёт сам движок, и после перезапуска процесса она наполняется при его создании
            val created = runCatching { FlutterEngine(applicationContext) }.getOrNull()
            if (created == null) {
                fail("движок не поднялся")
                return@ensureInitializationCompleteAsync
            }
            engine = created

            val info = runCatching { FlutterCallbackInformation.lookupCallbackInformation(handle) }
                .getOrNull()
            if (info == null) {
                fail("точка входа фонового прохода не нашлась")
                return@ensureInitializationCompleteAsync
            }

            // Тот же мост, что в приложении: без него `inode` в фоне падал бы, а зеркало
            // принимало бы переименование за удаление с повторной выгрузкой
            runCatching { SyncBridge(applicationContext, created.dartExecutor.binaryMessenger) }

            // Флаг остановки читается у службы: мост создаётся здесь, а просьба об остановке
            // могла прийти раньше (см. stopRequested)
            bridge = BackgroundBridge(
                applicationContext,
                created.dartExecutor.binaryMessenger,
                stopRequestedProvider = { stopRequested },
            ).also { it.onFinished = { ok, note -> finish(ok, note) } }

            // Просьба могла прийти между проверкой выше и созданием моста: повторяем её уже
            // через мост, чтобы событие `cancel` дошло до изолята
            if (stopRequested) bridge?.requestStop()

            val bundlePath = runCatching { loader.findAppBundlePath() }.getOrNull()
            if (bundlePath == null) {
                fail("сборка приложения не найдена")
                return@ensureInitializationCompleteAsync
            }

            val started = runCatching {
                created.dartExecutor.executeDartCallback(
                    DartExecutor.DartCallback(applicationContext.assets, bundlePath, info),
                )
            }
            if (started.isFailure) {
                fail("точка входа не запустилась: ${started.exceptionOrNull()?.message}")
                return@ensureInitializationCompleteAsync
            }
        }
    }

    /**
     * Предохранитель на случай, если изолят поднялся, но не ответил: без него задание
     * осталось бы в работе до таймаута системы, а движок — висеть в памяти.
     *
     * Срок чуть меньше, чем даёт система (около десяти минут), чтобы ответить первыми.
     */
    private fun armWatchdog() {
        main.postDelayed(
            {
                if (!ended.get()) {
                    Log.w(TAG, "фоновый проход не ответил за ${JOB_TIMEOUT_MS / 1000} с")
                    finish(false, "проход не ответил вовремя")
                }
            },
            JOB_TIMEOUT_MS,
        )
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        stopped = true
        // Флаг ставим до всего остального: изолят может подняться позже и спросить его сам
        stopRequested = true
        // Просим Dart закончить: движок спрашивает `isCancelled` между файлами и на границах
        // шагов, поэтому проход встанет на ближайшей проверке, а не на середине записи
        bridge?.requestStop()
        // Движок сразу не гасим: брошенная на середине транзакция хуже, чем несколько
        // лишних секунд. Если изолят не отзовётся и сам, его закроет предохранитель.
        main.postDelayed(
            { if (!ended.get()) finish(false, "система остановила задание") },
            STOP_GRACE_MS,
        )
        // true: систему просят повторить задание — проход не закончен
        return true
    }

    /** Итог: закрываем движок, отпускаем задание и разрешаем следующий проход. */
    private fun finish(ok: Boolean, note: String?) {
        // Считается по экземпляру: чужой (прежний) `finish` не должен закрывать наше задание
        if (!ended.compareAndSet(false, true)) return
        main.removeCallbacksAndMessages(null)

        val engineToDestroy = engine
        engine = null
        bridge = null
        val current = params
        running.set(false)

        if (note != null) Log.i(TAG, "фоновый проход: $note")

        if (engineToDestroy != null) {
            main.post { runCatching { engineToDestroy.destroy() } }
        }

        // После onStopJob задание уже закрыто системой: докладывать не о чем
        if (current != null && !stopped) {
            runCatching { jobFinished(current, !ok) }
        }
    }

    private fun fail(reason: String) {
        Log.w(TAG, reason)
        finish(false, reason)
    }

    /**
     * Числа и общее состояние задания.
     *
     * Сопутствующий объект не приватный намеренно: бюджеты читает мост канала
     * (`BackgroundBridge`, метод `budgets`) — изолят спрашивает их у службы, а не держит копию.
     * Всё остальное здесь закрыто: снаружи нужны только [PASS_BUDGET_MS] и [QUEUE_DEADLINE_MS].
     */
    companion object {
        /**
         * Сколько ждём ответа изолята, прежде чем закрыть движок: меньше системного таймаута
         * (около десяти минут на задание).
         */
        private const val JOB_TIMEOUT_MS = 9 * 60_000L

        /**
         * Запас между бюджетом прохода и предохранителем: время на наполнение очереди
         * и на честный ответ системе.
         */
        private const val JOB_RESERVE_MS = 2 * 60_000L

        /**
         * Бюджет зеркала за одно задание: его спрашивает фоновый изолят через канал
         * (`BackgroundBridge` `budgets`), а не держит свою копию.
         */
        const val PASS_BUDGET_MS = JOB_TIMEOUT_MS - JOB_RESERVE_MS

        /**
         * До какого момента (от начала прохода) наполнять очередь. Минута разницы с бюджетом
         * зеркала: очередь — подготовка, а обход папок в последнюю минуту задания всё равно
         * не успеет, и его оборвут на середине.
         */
        const val QUEUE_DEADLINE_MS = PASS_BUDGET_MS - 60_000L

        /** Сколько даём проходу после остановки задания, чтобы он завершился сам. */
        private const val STOP_GRACE_MS = 30_000L

        /** Проход уже идёт: статический, потому что службу система создаёт на каждый запуск. */
        private val running = AtomicBoolean(false)

        private const val TAG = "cloudly-sync"
    }
}
