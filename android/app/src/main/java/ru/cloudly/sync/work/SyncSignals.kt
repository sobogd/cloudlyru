package ru.cloudly.sync.work

/**
 * Сигналы внутри процесса: «состояние изменилось — отчитайся» и «на диске что-то появилось —
 * пройди папки». Нужны, чтобы веб видел правду сразу после окончания выгрузки, а не ждал
 * очередного тика расписания.
 */
object SyncSignals {

    @Volatile
    var reportNow: Boolean = false

    @Volatile
    var scanNow: Boolean = false

    fun requestReport() {
        reportNow = true
    }

    fun requestScan() {
        scanNow = true
        reportNow = true
    }
}
