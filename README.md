# Solar Record Audio Speach — Setup S

## Быстрый старт (5 минут)

### 1. Создай проект

```bash
npx create-next-app@latest solar-ai-backend \
  --typescript \
  --app \
  --no-tailwind \
  --no-src-dir \
  --import-alias "@/*"

cd solar-ai-backend
```

### 2. Скопируй route.ts

```
app/api/ai/route.ts  ← вставь файл route.ts
```

### 3. Создай .env.local

```bash
echo "OPENAI_API_KEY=sk-proj-твой-ключ" > .env.local
```

### 4. Запусти

```bash
npm run dev
```

Backend: http://localhost:3000/api/ai

---

## Тест через curl

### Тест summary:
```bash
curl -X POST http://localhost:3001/api/ai \
  -H "Content-Type: application/json" \
  -d '{
    "type": "summary",
    "payload": {
      "text": "Привет, как дела? Обсудили задачи на неделю. Нужно сделать отчёт до пятницы.",
      "mode": "standard"
    }
  }'
```

### Тест translate:
```bash
curl -X POST http://localhost:3001/api/ai \
  -H "Content-Type: application/json" \
  -d '{
    "type": "translate",
    "payload": {
      "text": "Привет, как дела?",
      "targetLang": "auto",
      "detectedLang": "ru"
    }
  }'
```

---

## Подключение iPhone (локально)

### Найди свой IP:
```bash
ifconfig | grep "inet 172"
# например: 192.168.1.42
```

### В Info.plist добавь:
```xml
<key>SOLAR_BACKEND_URL</key>
<string>http://172.20.10.5:3001/api/ai</string>
```

### В Info.plist добавь для HTTP (локальный IP):
```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key>
  <true/>
</dict>
```

---

## Deploy на Vercel

```bash
npx vercel
```

Добавь переменную окружения в Vercel Dashboard:
- `OPENAI_API_KEY` = твой ключ

После деплоя в Info.plist:
```xml
<key>SOLAR_BACKEND_URL</key>
<string>https://solar-ai-backend.vercel.app/api/ai</string>
```

---

## Структура запросов

### Transcribe (WAV → текст):
```json
{
  "type": "transcribe",
  "payload": {
    "file": "base64_encoded_wav_bytes"
  }
}
```

### Translate (текст → перевод):
```json
{
  "type": "translate",
  "payload": {
    "text": "Привет мир",
    "targetLang": "auto",
    "detectedLang": "ru"
  }
}
```
`targetLang: "auto"` → если ru → EN, если EN → RU

### Summary (текст → резюме):
```json
{
  "type": "summary",
  "payload": {
    "text": "транскрипция...",
    "mode": "standard" | "legal" | "erp" | "action"
  }
}
```

---

## iOS — что меняется

Замени в проекте:
- `WhisperService` → использует `SolarBackendService`
- `TranslationService` → использует `SolarBackendService`
- `SummaryService` → использует `SolarBackendService`
- API ключ убирается из `Secrets.plist` и `Info.plist`
- Добавляется `SOLAR_BACKEND_URL` в `Info.plist`

github solar-record
