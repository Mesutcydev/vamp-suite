import appcast from "../../docs/sync/appcast.xml";

export default {
  fetch(request) {
    const url = new URL(request.url);
    if (url.pathname !== "/appcast.xml" || !["GET", "HEAD"].includes(request.method)) {
      return fetch(request);
    }

    return new Response(request.method === "HEAD" ? null : appcast, {
      headers: {
        "content-type": "application/xml; charset=utf-8",
        "cache-control": "public, max-age=60",
      },
    });
  },
};
