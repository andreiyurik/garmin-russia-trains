// Cloudflare Workers entry point. Secret: YANDEX_API_KEY (wrangler secret put).
import index from "./index.js";

export default {
  async fetch(request, env) {
    const params = Object.fromEntries(new URL(request.url).searchParams);
    const res = await index.handleRequest(params, { apiKey: env.YANDEX_API_KEY });
    return new Response(res.body, { status: res.statusCode, headers: res.headers });
  },
};
