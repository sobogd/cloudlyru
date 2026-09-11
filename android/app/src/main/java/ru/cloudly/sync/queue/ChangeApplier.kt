package ru.cloudly.sync.queue

import android.content.Context
import android.util.Log
import ru.cloudly.sync.App
import ru.cloudly.sync.data.QueueStore
import ru.cloudly.sync.docs.CloudDownloader
import ru.cloudly.sync.net.Api
import java.io.File

/**
 * Правки из веба доезжают до телефона: телефон идёт по журналу изменений сервера и приводит
 * локальные файлы в порядок.
 *
 * Что применяется:
 *   • переименование — файл на телефоне получает новое имя (в той же папке);
 *   • новая версия содержимого — скачивается и заменяет локальный файл;
 *   • перемещение между папками телефона не поддерживается: локальная структура задаётся
 *     выбранными папками, и «переехать» в облаке ей некуда — такое изменение пропускается.
 *
 * Что не применяется принципиально: удаление. Удаление в облаке отправляет запись в корзину
 * сервера, файл на телефоне остаётся: приложение не удаляет ничего по своей инициативе.
 *
 * Свои же выгрузки телефон узнаёт по хэшу: если содержимое в облаке совпадает с тем, что он
 * сам туда положил, делать на телефоне нечего.
 */
class ChangeApplier(
    private val context: Context,
    private val api: Api,
    private val store: QueueStore,
) {

    data class Result(val applied: Int, val renamed: Int, val updated: Int, val problem: String? = null) {
        fun text(): String = buildString {
            append("применено изменений: $applied")
            if (renamed > 0) append(", переименовано: $renamed")
            if (updated > 0) append(", обновлено: $updated")
            problem?.let { append(" · $it") }
        }
    }

    /** Пройти журнал с последнего применённого места. Возвращает, что удалось сделать. */
    fun apply(): Result {
        val app = App.of(context)
        var cursor = app.prefs.changesSeq
        var applied = 0
        var renamed = 0
        var updated = 0

        var guard = 0
        while (guard++ < MAX_PAGES) {
            val page = runCatching { api.changes(cursor) }.getOrElse { e ->
                // сеть отвалилась: курсор не двигаем, попробуем в следующий раз
                return Result(applied, renamed, updated, "журнал недоступен: ${e.message?.take(80)}")
            }
            if (page.resetRequired) {
                // журнал подрезали: догонять нечего, дальше состояние соберёт обычный проход
                Log.w(TAG, "журнал изменений подрезан — пропускаю до ${page.nextSeq}")
                cursor = page.nextSeq
                app.prefs.changesSeq = cursor
                if (!page.hasMore) break
                continue
            }

            for (change in page.changes) {
                if (change.target != "entry") continue
                val locals = store.uploadedByEntry(change.targetId)
                for ((key, uploaded) in locals) {
                    val file = File(key.path)
                    if (!file.isFile) continue

                    // своё же изменение: содержимое в облаке то же, что телефон туда положил
                    val ownSha = store.shaOfUploaded(key.path, key.target)
                    val sameContent = change.sha256 != null && change.sha256 == ownSha

                    if (!sameContent && change.sha256 != null && change.size != null) {
                        val changedOnServer = uploaded.size != change.size
                        if (changedOnServer) {
                            if (download(change.targetId, file, change.sha256, change.size, change.mime)) {
                                store.refreshUploaded(
                                    path = key.path,
                                    target = key.target,
                                    size = file.length(),
                                    mtime = file.lastModified(),
                                    sha256 = change.sha256,
                                )
                                updated += 1
                            }
                        }
                    }

                    if (change.name.isNotBlank() && change.name != file.name) {
                        val target = File(file.parentFile, change.name)
                        if (!target.exists() && file.renameTo(target)) {
                            store.moveUploaded(key.path, key.target, target.absolutePath)
                            renamed += 1
                            Log.i(TAG, "переименовано на телефоне: ${file.name} → ${change.name}")
                        }
                    }
                }
                applied += 1
            }

            cursor = page.nextSeq
            app.prefs.changesSeq = cursor
            if (!page.hasMore) break
        }
        return Result(applied, renamed, updated)
    }

    /** Скачать новую версию поверх локального файла с проверкой размера и хэша. */
    private fun download(entryId: String, file: File, sha: String, size: Long, mime: String?): Boolean = try {
        CloudDownloader.download(
            api = api,
            entryId = entryId,
            target = file,
            clientMtime = null,
            expectSha256 = sha.takeIf { it.isNotBlank() },
            expectSize = size,
        )
        Log.i(TAG, "обновлён на телефоне: ${file.name} (${mime ?: "файл"})")
        true
    } catch (e: Exception) {
        Log.w(TAG, "не удалось обновить ${file.name}: ${e.message}")
        false
    }

    private companion object {
        const val TAG = "cloudly-sync"

        /** Предел на один заход: журнал может быть длинным, но цикл должен заканчиваться. */
        const val MAX_PAGES = 50
    }
}
