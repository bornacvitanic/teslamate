const LANG = navigator.languages
  ? navigator.languages[0]
  : navigator.language || navigator.userLanguage;

function toLocalTime(dateStr, opts) {
  const date = new Date(dateStr);

  return date instanceof Date && !isNaN(date.valueOf())
    ? date.toLocaleTimeString(LANG, opts)
    : "–";
}

function toLocalDate(dateStr, opts) {
  const date = new Date(dateStr);

  return date instanceof Date && !isNaN(date.valueOf())
    ? date.toLocaleDateString(LANG, opts)
    : "–";
}

export const Dropdown = {
  mounted() {
    const $el = this.el;

    $el.querySelector("button").addEventListener("click", (e) => {
      e.stopPropagation();
      $el.classList.toggle("is-active");
    });

    document.addEventListener("click", () => {
      $el.classList.remove("is-active");
    });
  },
};

export const LocalTime = {
  mounted() {
    this.el.innerText = toLocalTime(this.el.dataset.date);
  },

  updated() {
    this.el.innerText = toLocalTime(this.el.dataset.date);
  },
};

export const LocalTimeRange = {
  exec() {
    const date = toLocalDate(this.el.dataset.startDate, {
      year: "numeric",
      month: "short",
      day: "numeric",
    });

    const time = [this.el.dataset.startDate, this.el.dataset.endDate]
      .map((date) =>
        toLocalTime(date, {
          hour: "2-digit",
          minute: "2-digit",
          hour12: false,
        }),
      )
      .join(" – ");

    this.el.innerText = `${date}, ${time}`;
  },

  mounted() {
    this.exec();
  },
  updated() {
    this.exec();
  },
};

export const ConfirmGeoFenceDeletion = {
  mounted() {
    const { id, msg } = this.el.dataset;

    this.el.addEventListener("click", () => {
      if (window.confirm(msg)) {
        this.pushEvent("delete", { id });
      }
    });
  },
};

import {
  Map as M,
  TileLayer,
  LatLng,
  Control,
  Marker,
  Icon,
  Circle,
  CircleMarker,
  DomEvent,
} from "leaflet";

import markerIcon from "leaflet/dist/images/marker-icon.png";
import markerShadow from "leaflet/dist/images/marker-shadow.png";

const icon = new Icon({
  iconUrl: markerIcon,
  shadowUrl: markerShadow,
  iconAnchor: [12, 40],
  popupAnchor: [0, -25],
});

const DirectionArrow = CircleMarker.extend({
  initialize(latLng, heading, options) {
    this._heading = heading;
    CircleMarker.prototype.initialize.call(this, latLng, {
      fillOpacity: 1,
      radius: 5,
      ...options,
    });
  },

  setHeading(heading) {
    this._heading = heading;
    this.redraw();
  },

  _updatePath() {
    const { x, y } = this._point;

    if (this._heading === "")
      return CircleMarker.prototype._updatePath.call(this);

    this.getElement().setAttributeNS(
      null,
      "transform",
      `translate(${x},${y}) rotate(${this._heading})`,
    );

    const path = this._empty() ? "" : `M0,${3} L-4,${5} L0,${-5} L4,${5} z}`;

    this._renderer._setPath(this, path);
  },
});

function createMap(opts) {
  const targetId =
    opts.elementId != null
      ? opts.elementId
      : opts.elId != null
        ? `map_${opts.elId}`
        : "map";
  const map = new M(targetId, opts);

  // CartoDB basemaps — free, no API key. Positron (light) / DarkMatter (dark)
  // follow the app theme via <html data-theme="...">.
  const isDarkMode =
    document.documentElement.getAttribute("data-theme") === "dark";

  const baseUrl = isDarkMode
    ? "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png"
    : "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png";

  const base = new TileLayer(baseUrl, {
    maxZoom: 20,
    subdomains: "abcd",
    attribution: "\u00a9 OpenStreetMap, \u00a9 CARTO",
    updateWhenIdle: true,
    updateWhenZooming: false,
    keepBuffer: 4,
  });

  if (opts.enableHybridLayer) {
    const hybrid = new TileLayer(
      "https://{s}.google.com/vt/lyrs=s,h&x={x}&y={y}&z={z}",
      { maxZoom: 20, subdomains: ["mt0", "mt1", "mt2", "mt3"] },
    );

    new Control.Layers({ Base: base, Hybrid: hybrid }).addTo(map);
  }

  map.addLayer(base);

  return map;
}

export const SimpleMap = {
  mounted() {
    const $position = document.querySelector(`#position_${this.el.dataset.id}`);

    const map = createMap({
      elId: this.el.dataset.id,
      // Summary map is a fixed preview — no pan, zoom, or controls.
      zoomControl: false,
      boxZoom: false,
      doubleClickZoom: false,
      keyboard: false,
      scrollWheelZoom: false,
      tap: false,
      dragging: false,
      touchZoom: false,
    });

    const isArrow = this.el.dataset.marker === "arrow";
    const [lat, lng, heading] = $position.value.split(",");

    const marker = isArrow
      ? new DirectionArrow([lat, lng], heading)
      : new Marker([lat, lng], { icon });

    map.setView([lat, lng], 17);
    marker.addTo(map);

    // Render all geofence circles. Home (most-used) gets a stronger stroke/fill.
    try {
      const geofences = JSON.parse(this.el.dataset.geofences || "[]");
      const homeId = parseInt(this.el.dataset.homeGeofenceId || "0", 10);
      geofences.forEach((gf) => {
        const isHome = gf.id === homeId;
        new Circle([gf.lat, gf.lng], {
          radius: gf.radius,
          color: isHome ? "#00b894" : "#8a94a6",
          weight: isHome ? 2 : 1,
          fillColor: isHome ? "#00b894" : "#8a94a6",
          fillOpacity: isHome ? 0.15 : 0.05,
        })
          .bindTooltip(gf.name, { direction: "top", sticky: true })
          .addTo(map);
      });
    } catch (_) {
      /* no geofences */
    }

    // Keep Leaflet in sync with container size. LiveView mounts the
    // panels on the right slightly after initial render, which expands
    // the card height — and Leaflet reads dimensions only once, so the
    // bottom ~fifth was being left uncovered with white. We observe
    // both the figure and the inner .map div, and also fire several
    // nudges spaced out in time to cover async content arrivals.
    const mapEl = document.getElementById(`map_${this.el.dataset.id}`);
    const nudge = () => map.invalidateSize();
    const ro = new ResizeObserver(nudge);
    ro.observe(this.el);
    if (mapEl) ro.observe(mapEl);
    requestAnimationFrame(nudge);
    [100, 300, 700, 1500].forEach((ms) => setTimeout(nudge, ms));

    // Map is not interactive on the summary — always follow the car.
    if (isArrow) {
      const setView = () => {
        const [lat, lng, heading] = $position.value.split(",");
        marker.setHeading(heading);
        marker.setLatLng([lat, lng]);
        map.setView([lat, lng], map.getZoom());
      };
      $position.addEventListener("change", setView);
    }
  },
};

export const TriggerChange = {
  updated() {
    this.el.dispatchEvent(new CustomEvent("change"));
  },
};

// Persist <details> open state across LiveView DOM patches by saving
// each element's open flag in localStorage under its data-key.
export const DetailsPersist = {
  mounted() {
    this._restore();
    this.el.addEventListener("toggle", () => {
      try {
        localStorage.setItem(
          "details-open:" + this.el.dataset.key,
          this.el.open ? "1" : "0",
        );
      } catch (_) {
        /* localStorage disabled */
      }
    });
  },
  updated() {
    this._restore();
  },
  _restore() {
    try {
      const k = "details-open:" + this.el.dataset.key;
      const v = localStorage.getItem(k);
      if (v === "1") this.el.open = true;
      else if (v === "0") this.el.open = false;
    } catch (_) {
      /* no-op */
    }
  },
};

// Confirm-before-delete for the bulk action button.
export const ConfirmBulkDelete = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      const n = this.el.dataset.count || "?";
      if (!window.confirm(`Delete ${n} geofence${n === "1" ? "" : "s"}?`)) {
        e.preventDefault();
        return;
      }
      this.pushEvent("delete_selected", {});
    });
  },
};

// Interactive map for the geofences index page — renders all geofences as
// circles, fly-to's the selected one when the LiveView updates
// data-selected-id, and emits map_click on empty-area clicks so the
// LiveView can navigate to the Create form pre-filled with those coords.
export const GeofencesMap = {
  mounted() {
    const map = createMap({
      elementId: this.el.id,
      zoomControl: true,
      boxZoom: false,
      doubleClickZoom: true,
      keyboard: false,
      scrollWheelZoom: true,
      dragging: true,
      touchZoom: true,
    });
    this._map = map;
    this._circles = {};

    map.on("click", (e) => {
      this.pushEvent("map_click", {
        lat: e.latlng.lat,
        lng: e.latlng.lng,
      });
    });

    // Browser-side file download for Export — triggered by the LiveView
    // push_event('download_file', ...). Attached here because this hook is
    // guaranteed to mount on the geofences page.
    this.handleEvent("download_file", ({ filename, content, mime }) => {
      const blob = new Blob([content], {
        type: mime || "application/octet-stream",
      });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = filename || "download";
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    });

    const geofences = JSON.parse(this.el.dataset.geofences || "[]");
    geofences.forEach((gf) => {
      const c = new Circle([gf.lat, gf.lng], {
        radius: gf.radius,
        color: "#8a94a6",
        weight: 1,
        fillColor: "#8a94a6",
        fillOpacity: 0.08,
      })
        .bindTooltip(gf.name, { sticky: true, direction: "top" })
        .addTo(map);
      c.on("click", (e) => {
        // Stop Leaflet from bubbling the click up to the map, which
        // would otherwise trigger 'map_click' (create-at-this-point).
        DomEvent.stopPropagation(e);
        this.pushEvent("select", { id: gf.id });
      });
      this._circles[gf.id] = c;
    });

    if (geofences.length > 0) {
      const lats = geofences.map((g) => g.lat);
      const lngs = geofences.map((g) => g.lng);
      map.fitBounds(
        [
          [Math.min(...lats), Math.min(...lngs)],
          [Math.max(...lats), Math.max(...lngs)],
        ],
        { padding: [30, 30], animate: false },
      );
    } else {
      map.setView([0, 0], 2);
    }

    this._applySelection(parseInt(this.el.dataset.selectedId || "0", 10));

    const nudge = () => map.invalidateSize();
    const ro = new ResizeObserver(nudge);
    ro.observe(this.el);
    requestAnimationFrame(nudge);
    [100, 400, 1000].forEach((ms) => setTimeout(nudge, ms));
  },

  updated() {
    this._applySelection(parseInt(this.el.dataset.selectedId || "0", 10));
  },

  _applySelection(selectedId) {
    Object.entries(this._circles).forEach(([id, circle]) => {
      const isSel = parseInt(id, 10) === selectedId;
      circle.setStyle({
        color: isSel ? "#00b894" : "#8a94a6",
        weight: isSel ? 3 : 1,
        fillColor: isSel ? "#00b894" : "#8a94a6",
        fillOpacity: isSel ? 0.25 : 0.08,
      });
      if (isSel) circle.bringToFront();
    });
    if (selectedId) {
      const sel = this._circles[selectedId];
      if (sel) {
        this._map.flyToBounds(sel.getBounds().pad(0.6), { duration: 0.5 });
      }
    }
  },
};

import("leaflet-control-geocoder");
import("@geoman-io/leaflet-geoman-free");

export const Map = {
  mounted() {
    const geoFence = (name) =>
      document.querySelector(`input[name='geo_fence[${name}]']`);

    const $radius = geoFence("radius");
    const $latitude = geoFence("latitude");
    const $longitude = geoFence("longitude");

    const location = new LatLng($latitude.value, $longitude.value);

    const controlOpts = {
      position: "topleft",
      cutPolygon: false,
      drawCircle: false,
      drawCircleMarker: false,
      drawMarker: false,
      drawPolygon: false,
      drawPolyline: false,
      drawRectangle: false,
      removalMode: false,
    };

    const editOpts = {
      allowSelfIntersection: false,
      preventMarkerRemoval: true,
    };

    const map = createMap({ enableHybridLayer: true });
    map.setView(location, 17, { animate: false });
    map.pm.setLang(LANG);
    map.pm.addControls(controlOpts);
    map.pm.enableGlobalEditMode(editOpts);

    const circle = new Circle(location, { radius: $radius.value })
      .addTo(map)
      .on("pm:edit", (e) => {
        const { lat, lng } = e.target.getLatLng();
        const radius = Math.round(e.target.getRadius());

        $radius.value = radius;
        $latitude.value = lat;
        $longitude.value = lng;

        const mBox = map.getBounds();
        const cBox = circle.getBounds();
        const bounds = mBox.contains(cBox) ? mBox : cBox;
        map.fitBounds(bounds);
      });

    new Control.geocoder({ defaultMarkGeocode: false })
      .on("markgeocode", (e) => {
        const { bbox, center } = e.geocode;

        const poly = L.polygon([
          bbox.getSouthEast(),
          bbox.getNorthEast(),
          bbox.getNorthWest(),
          bbox.getSouthWest(),
        ]);

        circle.setLatLng(center);

        const lBox = poly.getBounds();
        const cBox = circle.getBounds();
        const bounds = cBox.contains(lBox) ? cBox : lBox;

        map.fitBounds(bounds);
        map.pm.enableGlobalEditMode();

        const { lat, lng } = center;
        $latitude.value = lat;
        $longitude.value = lng;
      })
      .addTo(map);

    map.fitBounds(circle.getBounds(), { animate: false });
  },
};

export const Modal = {
  _freeze() {
    document.documentElement.classList.add("is-clipped");
  },

  _unfreeze() {
    document.documentElement.classList.remove("is-clipped");
  },

  mounted() {
    // assumption: 'is-active' is always added after the initial mount
  },

  updated() {
    this.el.classList.contains("is-active") ? this._freeze() : this._unfreeze();
  },

  destroyed() {
    this._unfreeze();
  },
};

export const NumericInput = {
  mounted() {
    this.el.onkeypress = (evt) => {
      const charCode = evt.which ? evt.which : evt.keyCode;
      return !(charCode > 31 && (charCode < 48 || charCode > 57));
    };
  },
};

export const ThemeSelector = {
  mounted() {
    const select = this.el.querySelector("select");
    if (select) {
      select.addEventListener("change", (e) => {
        const themeMode = e.target.value;
        document.documentElement.setAttribute("data-theme-mode", themeMode);

        // Apply theme immediately
        let actualTheme = themeMode;
        if (themeMode === "system") {
          actualTheme = window.matchMedia("(prefers-color-scheme: dark)")
            .matches
            ? "dark"
            : "light";
        }
        document.documentElement.setAttribute("data-theme", actualTheme);
      });
    }
  },
};
