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

// Debug view toggle: persists in localStorage; flipping it reveals all
// normally-hidden conditional UI (pills, panels, ...) so layout can be
// inspected even when nothing's actually happening.
(function setupDebugToggle() {
  const applyDebug = (on) => {
    document.documentElement.setAttribute(
      "data-debug-mode",
      on ? "all-on" : "off",
    );
  };
  const stored = localStorage.getItem("debugMode") === "on";
  applyDebug(stored);

  document.addEventListener("click", (e) => {
    if (e.target && e.target.id === "debug-toggle-btn") {
      const next = localStorage.getItem("debugMode") !== "on";
      localStorage.setItem("debugMode", next ? "on" : "off");
      applyDebug(next);
    }
  });
})();

liveSocket.connect();

// liveSocket.enableDebug();
// liveSocket.enableLatencySim(1000);
// window.liveSocket = liveSocket;

import "./main";
