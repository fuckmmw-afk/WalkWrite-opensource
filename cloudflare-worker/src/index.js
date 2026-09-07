/**
 * Dicta brain: Workers AI via env.AI (Cloudflare-hosted models).
 * POST { raw_transcript, locale } → JSON definition cards.
 * No OpenAI / Gemini / Anthropic keys.
 */

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

const SYSTEM = `Ты словарный редактор. По стенограмме и поисковой выдаче составь 1–2 карточки на русском.
Правила:
- Не выдумывай факты вне выдачи. Если выдача пустая — definition кратко по смыслу стенограммы, source=null, в notes напиши что источника нет.
- Ответ ТОЛЬКО JSON без markdown:
{"cards":[{"term":"...","definition":"...","notes":["уточнение1","уточнение2"],"source":"https://... или null"}]}
- notes: 1–2 коротких уточнения.
- source: URL из выдачи, иначе null.`;

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS });
    }
    const url = new URL(request.url);
    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      return json({ ok: true, model: env.MODEL, service: "dicta-brain" });
    }
    if (request.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: "invalid_json" }, 400);
    }
    const raw = String(body?.raw_transcript || "").trim();
    const locale = String(body?.locale || "ru");
    if (!raw) return json({ error: "raw_transcript_required" }, 400);

    const hits = await searchSources(raw);
    const model = env.MODEL || "@cf/meta/llama-3.1-8b-instruct-fp8";
    const fallback = env.FALLBACK_MODEL || "@cf/meta/llama-3.3-70b-instruct-fp8-fast";

    let cards = await define(env, model, raw, locale, hits);
    let used = model;
    if (!cards.length) {
      cards = await define(env, fallback, raw, locale, hits);
      used = fallback;
    }
    if (!cards.length) {
      cards = [
        {
          term: raw.slice(0, 80),
          definition: "Не удалось собрать карточку. Сырой текст сохранён.",
          notes: ["модель не вернула JSON"],
          source: hits[0]?.url || null,
        },
      ];
    }

    return json({
      cards,
      model: used,
      searched: hits.length > 0,
      locale,
    });
  },
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...CORS },
  });
}

async function define(env, model, raw, locale, hits) {
  const snippets = hits.length
    ? hits
        .map((h, i) => `${i + 1}. ${h.title}\n${h.extract}\n${h.url}`)
        .join("\n\n")
    : "(пусто)";
  const user = `locale: ${locale}\nстенограмма:\n${raw}\n\nвыдача поиска:\n${snippets}`;
  try {
    const result = await env.AI.run(model, {
      messages: [
        { role: "system", content: SYSTEM },
        { role: "user", content: user },
      ],
      max_tokens: 700,
      temperature: 0.2,
    });
    const text = extractText(result);
    return parseCards(text);
  } catch (err) {
    console.log("AI.run failed", model, String(err));
    return [];
  }
}

function extractText(result) {
  if (!result) return "";
  if (typeof result === "string") return result;
  if (typeof result.response === "string") return result.response;
  if (typeof result.response === "object" && result.response) {
    const r = result.response;
    if (typeof r === "string") return r;
    if (Array.isArray(r.cards)) return JSON.stringify(r);
  }
  const choice = result.choices?.[0]?.message?.content;
  if (typeof choice === "string") return choice;
  if (Array.isArray(result.cards)) return JSON.stringify(result);
  try {
    return JSON.stringify(result);
  } catch {
    return "";
  }
}

function parseCards(text) {
  if (!text) return [];
  let s = text.trim();
  s = s.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "");
  const start = s.indexOf("{");
  const end = s.lastIndexOf("}");
  if (start >= 0 && end > start) s = s.slice(start, end + 1);
  try {
    const obj = JSON.parse(s);
    const list = Array.isArray(obj.cards) ? obj.cards : [obj];
    return list
      .map(normalizeCard)
      .filter((c) => c.term && c.definition)
      .slice(0, 2);
  } catch {
    return [];
  }
}

function normalizeCard(c) {
  const notes = Array.isArray(c?.notes)
    ? c.notes.map(String).map((x) => x.trim()).filter(Boolean).slice(0, 2)
    : [];
  let source = c?.source;
  if (source === "null" || source === "" || source == null) source = null;
  else source = String(source);
  return {
    term: String(c?.term || "").trim(),
    definition: String(c?.definition || "").trim(),
    notes,
    source,
  };
}

async function searchSources(query) {
  const q = query.replace(/\s+/g, " ").slice(0, 180);
  const hits = [];
  try {
    const open = await fetch(
      "https://ru.wikipedia.org/w/api.php?" +
        new URLSearchParams({
          action: "opensearch",
          search: q,
          limit: "2",
          namespace: "0",
          format: "json",
          origin: "*",
        }),
      { headers: { "User-Agent": "dicta-brain/1.0" } }
    );
    const data = await open.json();
    const titles = data?.[1] || [];
    const urls = data?.[3] || [];
    for (let i = 0; i < titles.length && i < 2; i++) {
      const title = titles[i];
      const extract = await wikiExtract(title);
      hits.push({
        title,
        extract: extract || "",
        url: urls[i] || `https://ru.wikipedia.org/wiki/${encodeURIComponent(title)}`,
      });
    }
  } catch (err) {
    console.log("wiki search failed", String(err));
  }
  return hits;
}

async function wikiExtract(title) {
  try {
    const res = await fetch(
      "https://ru.wikipedia.org/w/api.php?" +
        new URLSearchParams({
          action: "query",
          prop: "extracts",
          exintro: "1",
          explaintext: "1",
          redirects: "1",
          titles: title,
          format: "json",
          origin: "*",
        }),
      { headers: { "User-Agent": "dicta-brain/1.0" } }
    );
    const data = await res.json();
    const pages = data?.query?.pages || {};
    const page = Object.values(pages)[0];
    return String(page?.extract || "").slice(0, 1200);
  } catch {
    return "";
  }
}
