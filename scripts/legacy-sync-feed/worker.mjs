const appcast = "https://thevamp.app/sync/appcast.xml";

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname !== "/appcast.xml" || !["GET", "HEAD"].includes(request.method)) {
      return fetch(request);
    }

    try {
      const response = await fetch(appcast, { method: request.method, redirect: "error" });
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
