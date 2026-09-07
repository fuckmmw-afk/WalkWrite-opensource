# dicta-brain

Cloudflare Worker. Модель вызывается **нативным Workers AI** (`env.AI.run`), это endpoint Cloudflare, не свой домен.

```
POST /
Content-Type: application/json

{ "raw_transcript": "гравитация", "locale": "ru" }
```

Ответ:

```json
{
  "cards": [
    {
      "term": "гравитация",
      "definition": "...",
      "notes": ["...", "..."],
      "source": "https://ru.wikipedia.org/wiki/..."
    }
  ],
  "model": "@cf/meta/llama-3.1-8b-instruct-fp8",
  "searched": true,
  "locale": "ru"
}
```

Деплой (нужен API token со скоупом **Account / Workers Scripts / Edit**; Workers AI уже есть):

```bash
export CLOUDFLARE_API_TOKEN=...
export CLOUDFLARE_ACCOUNT_ID=78100f9ab63f3d4a04b296f5b8192430
npx wrangler deploy
```

URL будет вида `https://dicta-brain.<subdomain>.workers.dev`. Его вставляют в приложении (Настройки). Ключ Cloudflare в iOS не кладётся.
