package ru.cloudly.sync.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Варианты хранения файлов на телефоне: -1 — не удалять, 0 — сразу после выгрузки, N — дней. */
data class Retention(val days: Int, val label: String)

val RETENTION_PRESETS = listOf(
    Retention(-1, "Не удалять — зеркало папки"),
    Retention(0, "Удалять сразу после выгрузки"),
    Retention(3, "Хранить 3 дня"),
    Retention(7, "Хранить 7 дней"),
    Retention(14, "Хранить 14 дней"),
    Retention(30, "Хранить 30 дней"),
    Retention(90, "Хранить 90 дней"),
)

fun retentionLabel(days: Int): String =
    RETENTION_PRESETS.firstOrNull { it.days == days }?.label ?: "Хранить $days дней"

/** Селектор срока хранения вместо ряда кнопок: пресеты плюс свой срок. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RetentionPicker(
    days: Int,
    onChange: (Int) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    var custom by remember { mutableStateOf(false) }
    var customText by remember { mutableStateOf(if (days > 0 && RETENTION_PRESETS.none { it.days == days }) days.toString() else "") }

    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
        OutlinedTextField(
            value = retentionLabel(days),
            onValueChange = {},
            readOnly = true,
            label = { Text("Хранить на телефоне") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor(),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            RETENTION_PRESETS.forEach { preset ->
                DropdownMenuItem(
                    text = { Text(preset.label, fontSize = 14.sp) },
                    onClick = {
                        onChange(preset.days)
                        expanded = false
                    },
                )
            }
            DropdownMenuItem(
                text = { Text("Свой срок…", fontSize = 14.sp) },
                onClick = {
                    custom = true
                    expanded = false
                },
            )
        }
    }

    if (custom) {
        AlertDialog(
            onDismissRequest = { custom = false },
            title = { Text("Свой срок хранения") },
            text = {
                Column {
                    Text("Сколько дней держать выгруженное на телефоне?", fontSize = 13.sp)
                    OutlinedTextField(
                        value = customText,
                        onValueChange = { input -> customText = input.filter { it.isDigit() }.take(4) },
                        label = { Text("Дней") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("0 — удалять сразу после выгрузки", fontSize = 11.sp)
                    }
                }
            },
            confirmButton = {
                TextButton(
                    enabled = customText.isNotEmpty(),
                    onClick = {
                        onChange(customText.toIntOrNull() ?: 0)
                        custom = false
                    },
                ) { Text("Готово") }
            },
            dismissButton = { TextButton(onClick = { custom = false }) { Text("Отмена") } },
        )
    }
}
