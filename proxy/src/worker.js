// Cloudflare Workers entry point. Secret: YANDEX_API_KEY (wrangler secret put).
// KV namespace binding: CACHE (wrangler.toml), the schedule cache shared by all isolates.
import index from "./index.js";

export default {
  async fetch(request, env) {
    const params = Object.fromEntries(new URL(request.url).searchParams);
    const res = await index.handleRequest(params, { apiKey: env.YANDEX_API_KEY, kv: env.CACHE });
    return new Response(res.body, { status: res.statusCode, headers: res.headers });
  },
};
