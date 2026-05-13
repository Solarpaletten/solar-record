# SolarTimeline — Apply Manifest
# Модуль: SolarTimeline.swift v1
# Дата: 2026-04-01
# Статус: C=>D — готов к ревью Kimi

## Файлы в архиве

| Файл | Тип | Действие |
|------|-----|----------|
| `SolarTimeline.swift` | НОВЫЙ | Добавить в Xcode-группу SolarRecorder |
| `SolarApp.swift` | ИЗМЕНЁН | Заменить полностью |
| `route.ts` | ИЗМЕНЁН | Заменить полностью |

## Пути назначения

```
SolarTimeline.swift  →  SolarRecorder/SolarRecorder/SolarRecorder/SolarTimeline.swift
SolarApp.swift       →  SolarRecorder/SolarRecorder/SolarRecorder/SolarApp.swift
route.ts             →  SolarRecorder/solarrecord-api/app/api/ai/route.ts
```

## Изменения в SolarApp.swift

Строка 471 — добавлена 1 строка:
```swift
@State private var showTimeline = false
```

Строки 698-706 — добавлен блок кнопки Timeline:
```swift
if recording.transcript != nil {
    HStack(spacing: 10) {
        Button(action: { showTimeline = true }) {
            Label("Timeline", systemImage: "clock")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.yellow.opacity(0.8))
        }
        Spacer()
    }
}
```

Строки 729-731 — добавлен sheet:
```swift
.sheet(isPresented: $showTimeline) {
    TimelineSheet(recording: recording)
}
```

Строка 200 — добавлен `"timeline"` в delete():
```swift
for ext in ["json", "sha256", "txt", "md", "translation.txt", "lang", "speakers", "timeline"] {
```

## Изменения в route.ts

Добавлен изолированный endpoint `type === "timeline"` (строки 229-284).
Старые ветки `transcribe / translate / summary / speakers` не тронуты.

Итого endpoints: transcribe · translate · summary · speakers · **timeline**

## Deploy backend

**ДА** — после применения `route.ts` нужен `vercel deploy` или push в main ветку.

## Sidecar формат

`.timeline` — JSON массив `[TimelineSegment]`:
```json
[
  {
    "id": "UUID",
    "timestamp": 12.0,
    "speaker": "Speaker 1",
    "text": "Текст сегмента",
    "translatedText": null
  }
]
```

Удаляется автоматически при `delete()` вместе с записью.

## Checklist для Kimi

- [ ] `SolarTimeline.swift` — новый изолированный файл
- [ ] Патч SolarApp.swift — только 4 точечных добавления
- [ ] `route.ts` — только новый endpoint, старые не тронуты
- [ ] Sidecar `.timeline` зарегистрирован в `delete()`
- [ ] Старые flows не затронуты: record / transcribe / translate / summary / TTS / speakers
- [ ] Проект собирается без structural regressions
- [ ] Backend deploy требуется
