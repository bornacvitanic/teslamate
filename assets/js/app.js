import "../css/app.scss";

import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

import * as hooks from "./hooks";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const liveSocket = new LiveSocket(window.LIVE_PATH, Socket, {
  hooks,
  params: {
    _csrf_token: csrfToken,
    baseUrl: window.location.origin,
    referrer: document.referrer,
    tz: Intl && Intl.DateTimeFormat().resolvedOptions().timeZone,
  },
});

// Card-style previewer: read ?style=... from the URL and apply
// data-card-style to <html>, so CSS rules like
// [data-card-style="tesla"] .car {...} can override the default look.
// Re-applied on navigation so LiveView links keep the chosen variant.
function applyCardStyleFromUrl() {
  const q = new URLSearchParams(window.location.search);
  const style = q.get("style") || "default";
  document.documentElement.setAttribute("data-card-style", style);
}
applyCardStyleFromUrl();
window.addEventListener("popstate", applyCardStyleFromUrl);
window.addEventListener("phx:page-loading-stop", applyCardStyleFromUrl);

liveSocket.connect();

// liveSocket.enableDebug();
// liveSocket.enableLatencySim(1000);
// window.liveSocket = liveSocket;

import "./main";
