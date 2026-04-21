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

// Tesla is the one-and-only card style for now. Kept as a data attribute
// hook point so future style variants can slot in without CSS churn.
document.documentElement.setAttribute("data-card-style", "tesla");

liveSocket.connect();

// liveSocket.enableDebug();
// liveSocket.enableLatencySim(1000);
// window.liveSocket = liveSocket;

import "./main";
