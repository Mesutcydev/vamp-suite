const appcast = "https://thevamp.app/sync/appcast.xml";

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname !== "/appcast.xml" || !["GET", "HEAD"].includes(request.method)) {
      return fetch(request);
    }

    try {
      // A per-minute query gives each minute its own cache key, so any edge copy of the feed
      // is at most about a minute old.
      const upstream = `${appcast}?minute=${Math.floor(Date.now() / 60000)}`;
      // Workers reject redirect: "error" with a TypeError, which silently sent every request to
      // the stale fallback. "manual" returns a redirect as a 3xx, which fails response.ok below.
      const response = await fetch(upstream, { method: request.method, redirect: "manual" });
      const contentType = response.headers.get("content-type") ?? "";
      if (response.ok && contentType.includes("xml")) {
        return new Response(response.body, {
          headers: {
            "content-type": contentType,
            "cache-control": "public, max-age=60",
          },
        });
      }
    } catch {
      // Keep the origin feed available if the primary feed is temporarily unreachable.
    }

    return fetch(request);
  },
};
