"use strict";
(function () {
  const app = document.getElementById("app");

  // ------------------------------------------------------------ utilidades
  function h(tag, attrs, ...children) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === null || v === undefined || v === false) continue;
      if (k === "class") el.className = v;
      else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
      else if (k === "value") el.value = v;
      else el.setAttribute(k, v === true ? "" : v);
    }
    for (const c of children.flat()) {
      if (c === null || c === undefined || c === false) continue;
      el.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return el;
  }

  async function api(method, url, body, raw) {
    const opts = { method, headers: { "X-Requested-With": "mc" } };
    if (raw) { opts.body = raw; }
    else if (body !== undefined) { opts.body = JSON.stringify(body); opts.headers["Content-Type"] = "application/json"; }
    let res;
    try { res = await fetch(url, opts); }
    catch (e) { throw new Error("No se pudo conectar con el servidor. Comprueba la red e inténtalo de nuevo."); }
    let data = null;
    try { data = await res.json(); } catch (e) { /* sin cuerpo */ }
    if (!res.ok) throw new Error((data && data.error) || ("Error " + res.status));
    return data;
  }

  function toast(msg, error) {
    const t = h("div", { class: "toast" + (error ? " error" : "") }, msg);
    document.getElementById("toasts").append(t);
    setTimeout(() => t.remove(), error ? 6000 : 3000);
  }

  const fmtDate = (d) => {
    if (!d) return "—";
    const [y, m, day] = d.split("-");
    return day + "/" + m + "/" + y;
  };
  const fmtNum = (n) => (n === null || n === undefined || n === "" ? "—" : Number(n).toLocaleString("es-ES"));
  const fmtMoney = (n) => (n === null || n === undefined || n === "" ? "—" :
    Number(n).toLocaleString("es-ES", { style: "currency", currency: "EUR" }));
  const today = () => new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  const carName = (c) => c.alias || (c.marca + " " + c.modelo);

  function daysFrom(d) {
    const a = new Date(d + "T00:00:00"), b = new Date(today() + "T00:00:00");
    return Math.round((a - b) / 86400000);
  }
  function relDate(d) {
    const n = daysFrom(d);
    if (n === 0) return "hoy";
    if (n === 1) return "mañana";
    if (n === -1) return "ayer";
    return n > 0 ? "en " + n + " días" : "hace " + (-n) + " días";
  }

  function hue(str) {
    let x = 0;
    for (const ch of str) x = (x * 31 + ch.codePointAt(0)) % 360;
    return x;
  }
  function thumb(car, withBadge) {
    const box = h("div", { class: "thumb" });
    if (car.has_photo) {
      box.append(h("img", { src: "/api/cars/" + car.id + "/photo?v=" + encodeURIComponent(car.photo_v || ""),
        alt: carName(car), loading: "lazy" }));
    } else {
      const hh = hue(carName(car));
      const ph = h("div", { class: "placeholder", "aria-hidden": "true" }, (car.marca[0] || "?").toUpperCase() + (car.modelo[0] || "").toUpperCase());
      ph.style.setProperty("--ph1", "hsl(" + hh + " 70% 52%)");
      ph.style.setProperty("--ph2", "hsl(" + ((hh + 50) % 360) + " 70% 40%)");
      box.append(ph);
    }
    if (withBadge && car.mant_pendientes > 0)
      box.append(h("span", { class: "badge" }, car.mant_pendientes + " pendiente" + (car.mant_pendientes > 1 ? "s" : "")));
    return box;
  }

  // ------------------------------------------------------------ definición de formularios
  const OPT = {
    combustible: ["Gasolina", "Diésel", "Híbrido", "Híbrido enchufable", "Eléctrico", "GLP", "GNC", "Hidrógeno"],
    transmision: ["Manual", "Automático", "Semiautomático", "CVT"],
    carroceria: ["Berlina", "Compacto", "Familiar", "SUV", "Monovolumen", "Coupé", "Descapotable", "Pick-up", "Furgoneta"],
  };
  const MAINT_TYPES = ["Cambio de aceite y filtro", "Filtro de aire", "Filtro de habitáculo", "Filtro de combustible",
    "Pastillas de freno", "Discos de freno", "Líquido de frenos", "Neumáticos", "Rotación de neumáticos", "Alineado y equilibrado",
    "Correa de distribución", "Correa de accesorios", "Bujías", "Batería", "Refrigerante", "Amortiguadores",
    "Revisión general", "ITV", "Aire acondicionado", "Escobillas limpiaparabrisas", "Reparación", "Otro"];

  const SECTIONS = [
    ["Identificación", [
      ["alias", "Alias (cómo lo llamas)", "text"], ["marca", "Marca *", "text", { required: true }],
      ["modelo", "Modelo *", "text", { required: true }], ["version", "Versión / acabado", "text"],
      ["anio", "Año", "number", { min: 1886, max: 2100 }], ["matricula", "Matrícula", "text"],
      ["vin", "Nº de bastidor (VIN)", "text"], ["color", "Color", "text"], ["carroceria", "Carrocería", "select"]]],
    ["Mecánica", [
      ["combustible", "Combustible", "select"], ["transmision", "Transmisión", "select"],
      ["cilindrada_cc", "Cilindrada (cc)", "number", { min: 0 }], ["potencia_cv", "Potencia (CV)", "number", { min: 0 }],
      ["puertas", "Puertas", "number", { min: 0 }], ["plazas", "Plazas", "number", { min: 0 }],
      ["km_actuales", "Kilómetros actuales", "number", { min: 0 }], ["neumaticos", "Medida de neumáticos", "text"],
      ["tipo_aceite", "Tipo de aceite", "text"], ["capacidad_aceite", "Capacidad de aceite", "text"]]],
    ["Compra", [
      ["fecha_compra", "Fecha de compra", "date"], ["precio_compra", "Precio de compra (€)", "number", { min: 0, step: "0.01" }]]],
    ["Documentación", [
      ["itv_vencimiento", "Próxima ITV", "date"], ["seguro_compania", "Compañía de seguro", "text"],
      ["seguro_poliza", "Nº de póliza", "text"], ["seguro_vencimiento", "Vencimiento del seguro", "date"],
      ["impuesto_vencimiento", "Vencimiento del impuesto", "date"]]],
    ["Notas", [["notas", "Notas", "textarea"]]],
  ];
  const SPEC_LABELS = {};
  SECTIONS.forEach(([, fs]) => fs.forEach(([k, l]) => (SPEC_LABELS[k] = l.replace(" *", ""))));

  function inputFor(def, value) {
    const [key, label, type, extra] = def;
    const id = "f_" + key;
    let control;
    if (type === "select") {
      control = h("select", { id, name: key }, h("option", { value: "" }, "—"),
        OPT[key].map((o) => h("option", { value: o }, o)));
      if (value && !OPT[key].includes(value)) control.append(h("option", { value }, value));
      control.value = value || "";
    } else if (type === "textarea") {
      control = h("textarea", { id, name: key, maxlength: 4000 });
      control.value = value || "";
    } else {
      control = h("input", Object.assign({ id, name: key, type, autocomplete: "off" }, extra || {}));
      if (type === "text") control.maxLength = 80;
      control.value = value === null || value === undefined ? "" : value;
    }
    return h("div", { class: "field" + (type === "textarea" ? " wide" : "") }, h("label", { for: id }, label), control);
  }

  // ------------------------------------------------------------ diálogos
  function openDialog(title, bodyBuilder, onSubmit, submitLabel) {
    const err = h("p", { class: "form-error", hidden: true });
    const body = h("div", { class: "dlg-body" });
    const submit = h("button", { class: "btn primary", type: "submit" }, submitLabel || "Guardar");
    const dlg = h("dialog", {});
    const form = h("form", { method: "dialog", novalidate: false },
      h("div", { class: "dlg-head" }, h("h2", {}, title),
        h("button", { class: "btn ghost small", type: "button", "aria-label": "Cerrar", onclick: () => dlg.close() }, "✕")),
      body, err,
      h("div", { class: "dlg-foot" },
        h("button", { class: "btn", type: "button", onclick: () => dlg.close() }, "Cancelar"), submit));
    dlg.append(form);
    bodyBuilder(body);
    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      if (!form.reportValidity()) return;
      err.hidden = true;
      submit.disabled = true;
      try {
        await onSubmit(form, dlg);
      } catch (e) {
        err.textContent = e.message;
        err.hidden = false;
        submit.disabled = false;
      }
    });
    dlg.addEventListener("close", () => dlg.remove());
    document.body.append(dlg);
    dlg.showModal();
    return dlg;
  }

  function confirmDialog(title, text, okLabel) {
    return new Promise((resolve) => {
      let result = false;
      const dlg = openDialog(title, (b) => b.append(h("p", {}, text)), async (f, d) => { result = true; d.close(); }, okLabel || "Eliminar");
      dlg.addEventListener("close", () => resolve(result));
    });
  }

  // ------------------------------------------------------------ foto: reducir en el navegador
  function resizeImage(file) {
    return new Promise((resolve, reject) => {
      if (!file.type.startsWith("image/")) return reject(new Error("El archivo no es una imagen."));
      const url = URL.createObjectURL(file);
      const img = new Image();
      img.onload = () => {
        const max = 900, scale = Math.min(1, max / Math.max(img.width, img.height));
        const c = document.createElement("canvas");
        c.width = Math.max(1, Math.round(img.width * scale));
        c.height = Math.max(1, Math.round(img.height * scale));
        c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
        URL.revokeObjectURL(url);
        c.toBlob((b) => (b ? resolve(b) : reject(new Error("No se pudo procesar la imagen."))), "image/jpeg", 0.85);
      };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error("Formato de imagen no compatible con el navegador (usa JPG, PNG o WebP).")); };
      img.src = url;
    });
  }

  // ------------------------------------------------------------ formulario de coche
  function carForm(car) {
    const editing = !!car;
    let newPhoto = null, removePhoto = false;
    openDialog(editing ? "Editar coche" : "Añadir coche", (body) => {
      const preview = h("div", { class: "thumb" });
      const renderPreview = (url) => {
        preview.replaceChildren(url ? h("img", { src: url, alt: "Vista previa" }) :
          h("div", { class: "placeholder", "aria-hidden": "true" }, "📷"));
      };
      renderPreview(editing && car.has_photo ? "/api/cars/" + car.id + "/photo?v=" + encodeURIComponent(car.photo_v || "") : null);
      const file = h("input", { type: "file", accept: "image/*", id: "f_photo" });
      const rm = h("button", { class: "btn small danger", type: "button", onclick: () => {
        newPhoto = null; removePhoto = true; file.value = ""; renderPreview(null); } }, "Quitar foto");
      file.addEventListener("change", async () => {
        if (!file.files[0]) return;
        try {
          newPhoto = await resizeImage(file.files[0]);
          removePhoto = false;
          renderPreview(URL.createObjectURL(newPhoto));
        } catch (e) { file.value = ""; toast(e.message, true); }
      });
      body.append(h("fieldset", {}, h("legend", {}, "Foto (miniatura)"),
        h("div", { class: "photo-pick" }, preview, h("div", { class: "col" }, file, rm))));
      for (const [title, defs] of SECTIONS)
        body.append(h("fieldset", {}, h("legend", {}, title), h("div", { class: "fields" }, defs.map((d) => inputFor(d, car && car[d[0]])))));
    }, async (form, dlg) => {
      const data = {};
      for (const [, defs] of SECTIONS) for (const d of defs) data[d[0]] = form.elements[d[0]].value;
      const saved = editing ? await api("PUT", "/api/cars/" + car.id, data) : await api("POST", "/api/cars", data);
      try {
        if (newPhoto) await api("PUT", "/api/cars/" + saved.id + "/photo", undefined, newPhoto);
        else if (removePhoto && editing && car.has_photo) await api("DELETE", "/api/cars/" + saved.id + "/photo");
      } catch (e) {
        toast("El coche se guardó, pero la foto falló: " + e.message, true);
      }
      dlg.close();
      toast("Coche guardado");
      if (editing) route(); else location.hash = "#/coche/" + saved.id;
    });
  }

  // ------------------------------------------------------------ formulario de mantenimiento
  function maintForm(car, m) {
    const editing = !!(m && m.id);
    const m0 = m || {};
    openDialog(editing ? "Editar mantenimiento" : "Nuevo mantenimiento", (body) => {
      const listId = "maint-types";
      const state = h("select", { id: "m_estado", name: "estado" },
        h("option", { value: "realizado" }, "Realizado"), h("option", { value: "programado" }, "Programado (futuro)"));
      state.value = m0.estado || "realizado";
      const repeat = h("fieldset", {}, h("legend", {}, "Programar el siguiente automáticamente"),
        h("div", { class: "fields" },
          h("div", { class: "field" }, h("label", { for: "m_rep_m" }, "Repetir cada (meses)"),
            h("input", { id: "m_rep_m", name: "rep_meses", type: "number", min: 1, max: 240 })),
          h("div", { class: "field" }, h("label", { for: "m_rep_k" }, "Repetir cada (km)"),
            h("input", { id: "m_rep_k", name: "rep_km", type: "number", min: 1, max: 1000000 }))));
      const sync = () => { repeat.hidden = editing || state.value !== "realizado"; };
      state.addEventListener("change", sync);
      body.append(
        h("datalist", { id: listId }, MAINT_TYPES.map((t) => h("option", { value: t }))),
        h("fieldset", {}, h("div", { class: "fields" },
          h("div", { class: "field wide" }, h("label", { for: "m_tipo" }, "Tipo de trabajo *"),
            h("input", { id: "m_tipo", name: "tipo", list: listId, required: true, maxlength: 80, value: m0.tipo || "" })),
          h("div", { class: "field" }, h("label", { for: "m_estado" }, "Estado"), state),
          h("div", { class: "field" }, h("label", { for: "m_fecha" }, "Fecha (realizada o prevista)"),
            h("input", { id: "m_fecha", name: "fecha", type: "date", value: m0.fecha || (m0.estado ? "" : today()) })),
          h("div", { class: "field" }, h("label", { for: "m_km" }, "Kilómetros (realizados o previstos)"),
            h("input", { id: "m_km", name: "km", type: "number", min: 0, value: m0.km === undefined || m0.km === null ? (editing ? "" : (car.km_actuales || "")) : m0.km })),
          h("div", { class: "field" }, h("label", { for: "m_coste" }, "Coste (€)"),
            h("input", { id: "m_coste", name: "coste", type: "number", min: 0, step: "0.01", value: m0.coste === null || m0.coste === undefined ? "" : m0.coste })),
          h("div", { class: "field wide" }, h("label", { for: "m_taller" }, "Taller / lugar"),
            h("input", { id: "m_taller", name: "taller", type: "text", maxlength: 80, value: m0.taller || "" })),
          h("div", { class: "field wide" }, h("label", { for: "m_notas" }, "Notas (piezas, referencias, etc.)"),
            h("textarea", { id: "m_notas", name: "notas", maxlength: 4000 }, m0.notas || "")))),
        repeat);
      sync();
    }, async (form, dlg) => {
      const f = form.elements;
      const data = { car_id: car.id, tipo: f.tipo.value, estado: f.estado.value, fecha: f.fecha.value, km: f.km.value,
        coste: f.coste.value, taller: f.taller.value, notas: f.notas.value };
      if (data.estado === "programado" && !data.fecha && !data.km)
        throw new Error("Un mantenimiento programado necesita una fecha o unos kilómetros previstos.");
      if (editing) await api("PUT", "/api/maintenance/" + m.id, data); else await api("POST", "/api/maintenance", data);
      const repM = parseInt(f.rep_meses.value, 10), repK = parseInt(f.rep_km.value, 10);
      if (!editing && data.estado === "realizado" && (repM || repK)) {
        const next = { car_id: car.id, tipo: data.tipo, estado: "programado", fecha: "", km: "" };
        if (repM && data.fecha) {
          const d = new Date(data.fecha + "T00:00:00");
          const day = d.getDate();
          d.setMonth(d.getMonth() + repM);
          if (d.getDate() !== day) d.setDate(0);
          next.fecha = d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
        }
        if (repK && data.km) next.km = parseInt(data.km, 10) + repK;
        if (next.fecha || next.km) await api("POST", "/api/maintenance", next);
      }
      dlg.close();
      toast("Mantenimiento guardado");
      route();
    });
  }

  // ------------------------------------------------------------ vistas
  async function viewHome() {
    app.replaceChildren(h("p", { class: "loading" }, "Cargando…"));
    const [cars, alerts] = await Promise.all([api("GET", "/api/cars"), api("GET", "/api/alerts")]);
    const search = h("input", { class: "search", type: "search", placeholder: "Buscar coche…", "aria-label": "Buscar coche" });
    const grid = h("div", { class: "grid" });
    const render = () => {
      const q = search.value.trim().toLowerCase();
      const list = cars.filter((c) => !q || [c.alias, c.marca, c.modelo, c.matricula, c.version].join(" ").toLowerCase().includes(q));
      grid.replaceChildren(...list.map((c) => h("a", { class: "car-card", href: "#/coche/" + c.id },
        thumb(c, true),
        h("div", { class: "body" }, h("h3", {}, carName(c)),
          c.alias ? h("div", { class: "muted" }, c.marca + " " + c.modelo + (c.version ? " " + c.version : "")) : (c.version ? h("div", { class: "muted" }, c.version) : null),
          c.matricula ? h("span", { class: "plate" }, c.matricula) : null,
          h("div", { class: "chips" }, c.anio ? h("span", { class: "chip" }, c.anio) : null,
            c.combustible ? h("span", { class: "chip" }, c.combustible) : null,
            h("span", { class: "chip" }, fmtNum(c.km_actuales || 0) + " km"))))));
      if (!list.length && cars.length) grid.append(h("p", { class: "muted" }, "Ningún coche coincide con la búsqueda."));
    };
    search.addEventListener("input", render);
    render();

    app.replaceChildren(
      h("div", { class: "page-head" }, h("div", {}, h("h1", {}, "Mis coches"),
        h("p", { class: "muted" }, cars.length + (cars.length === 1 ? " vehículo registrado" : " vehículos registrados"))), cars.length ? search : null),
      alerts.length ? h("section", { class: "alerts", "aria-label": "Avisos" }, alerts.map((a) =>
        h("a", { class: "alert" + (a.vencido ? " overdue" : ""), href: "#/coche/" + a.car_id },
          h("span", {}, a.vencido ? "⚠️" : "🔔"), h("strong", {}, a.car), h("span", {}, a.titulo),
          h("span", { class: "when" }, [a.fecha ? fmtDate(a.fecha) + " (" + relDate(a.fecha) + ")" : null,
            a.km ? a.km.toLocaleString("es-ES") + " km" : null].filter(Boolean).join(" · "))))) : null,
      cars.length ? grid : h("div", { class: "empty" }, h("h2", {}, "Aún no hay coches"),
        h("p", { class: "muted" }, "Añade tu primer coche para empezar a registrar su mantenimiento."),
        h("button", { class: "btn primary", type: "button", onclick: () => carForm() }, "+ Añadir coche")));
  }

  async function viewCar(id) {
    app.replaceChildren(h("p", { class: "loading" }, "Cargando…"));
    const car = await api("GET", "/api/cars/" + id);
    const ms = car.mantenimientos;
    const done = ms.filter((m) => m.estado === "realizado");
    const pending = ms.filter((m) => m.estado === "programado");
    const spent = done.reduce((s, m) => s + (m.coste || 0), 0);
    const isOver = (m) => (m.fecha && daysFrom(m.fecha) < 0) || (m.km !== null && car.km_actuales >= m.km);

    const dateFields = new Set(["fecha_compra", "itv_vencimiento", "seguro_vencimiento", "impuesto_vencimiento"]);
    const specs = [];
    for (const [title, defs] of SECTIONS) {
      if (title === "Notas") continue;
      const items = defs.map(([k]) => k).filter((k) => car[k] !== null && car[k] !== "" && k !== "alias");
      if (!items.length) continue;
      specs.push(h("section", { class: "panel" }, h("h2", {}, title),
        h("dl", { class: "specs" }, items.map((k) => {
          let v = car[k];
          if (dateFields.has(k)) v = fmtDate(v) + (k !== "fecha_compra" ? " (" + relDate(car[k]) + ")" : "");
          else if (k === "precio_compra") v = fmtMoney(v);
          else if (k === "km_actuales") v = fmtNum(v) + " km";
          else if (k === "cilindrada_cc") v = fmtNum(v) + " cc";
          else if (k === "potencia_cv") v = v + " CV";
          return h("div", {}, h("dt", {}, SPEC_LABELS[k]), h("dd", {}, v));
        }))));
    }

    const item = (m) => {
      const over = m.estado === "programado" && isOver(m);
      return h("li", { class: "mitem " + m.estado + (over ? " overdue" : "") },
        h("div", { class: "date" }, m.fecha ? fmtDate(m.fecha) : "Sin fecha",
          h("div", {}, h("span", { class: "tag " + (over ? "overdue" : m.estado) }, over ? "Vencido" : m.estado))),
        h("div", {}, h("div", { class: "title" }, m.tipo),
          h("div", { class: "meta" }, [m.km !== null ? fmtNum(m.km) + " km" : null, m.coste !== null ? fmtMoney(m.coste) : null,
            m.taller].filter(Boolean).join(" · ")),
          m.notas ? h("div", { class: "meta notes" }, m.notas) : null),
        h("div", { class: "btns" },
          m.estado === "programado" ? h("button", { class: "btn small primary", type: "button", onclick: () =>
            maintForm(car, Object.assign({}, m, { estado: "realizado", fecha: today(), km: car.km_actuales || m.km })) }, "Marcar hecho") : null,
          h("button", { class: "btn small", type: "button", onclick: () => maintForm(car, m) }, "Editar"),
          h("button", { class: "btn small danger", type: "button", onclick: async () => {
            if (!(await confirmDialog("Eliminar mantenimiento", "¿Eliminar «" + m.tipo + "»? No se puede deshacer."))) return;
            try { await api("DELETE", "/api/maintenance/" + m.id); toast("Eliminado"); route(); } catch (e) { toast(e.message, true); }
          } }, "Eliminar")));
    };
    const sorted = (arr, dir) => arr.slice().sort((a, b) => dir * ((a.fecha || "9999").localeCompare(b.fecha || "9999")));

    app.replaceChildren(
      h("p", {}, h("a", { href: "#/" }, "← Todos los coches")),
      h("div", { class: "detail-hero" }, thumb(car, false),
        h("div", {}, h("h1", {}, carName(car)),
          h("p", { class: "muted" }, [car.marca, car.modelo, car.version, car.anio].filter(Boolean).join(" · ")),
          car.matricula ? h("span", { class: "plate" }, car.matricula) : null,
          h("div", { class: "stats" },
            h("div", { class: "stat" }, h("b", {}, fmtNum(car.km_actuales || 0)), h("span", {}, "kilómetros")),
            h("div", { class: "stat" }, h("b", {}, pending.length), h("span", {}, "pendientes")),
            h("div", { class: "stat" }, h("b", {}, done.length), h("span", {}, "realizados")),
            h("div", { class: "stat" }, h("b", {}, fmtMoney(spent)), h("span", {}, "gasto en mantenimiento"))),
          h("div", { class: "actions" },
            h("button", { class: "btn primary", type: "button", onclick: () => maintForm(car) }, "+ Mantenimiento"),
            h("button", { class: "btn", type: "button", onclick: () => carForm(car) }, "Editar"),
            h("button", { class: "btn danger", type: "button", onclick: async () => {
              if (!(await confirmDialog("Eliminar coche", "¿Eliminar «" + carName(car) + "» con todo su historial? No se puede deshacer."))) return;
              try { await api("DELETE", "/api/cars/" + car.id); toast("Coche eliminado"); location.hash = "#/"; } catch (e) { toast(e.message, true); }
            } }, "Eliminar")))),
      h("section", { class: "panel" }, h("h2", {}, "Próximos mantenimientos"),
        pending.length ? h("ul", { class: "timeline" }, sorted(pending, 1).map(item)) : h("p", { class: "muted" }, "No hay mantenimientos programados.")),
      h("section", { class: "panel" }, h("h2", {}, "Historial"),
        done.length ? h("ul", { class: "timeline" }, sorted(done, -1).map(item)) : h("p", { class: "muted" }, "Todavía no hay mantenimientos registrados.")),
      ...specs,
      car.notas ? h("section", { class: "panel" }, h("h2", {}, "Notas"), h("p", { class: "notes" }, car.notas)) : null);
    document.title = carName(car) + " · Mantenimiento coches";
  }

  // ------------------------------------------------------------ enrutado
  let seq = 0;
  async function route() {
    const mine = ++seq;
    document.title = "Mantenimiento coches";
    const m = location.hash.match(/^#\/coche\/(\d+)$/);
    try {
      if (m) await viewCar(m[1]); else await viewHome();
    } catch (e) {
      if (mine !== seq) return;
      app.replaceChildren(h("div", { class: "empty" }, h("h2", {}, "Algo ha fallado"), h("p", { class: "muted" }, e.message),
        h("a", { class: "btn", href: "#/" }, "Volver al inicio")));
    }
  }
  window.addEventListener("hashchange", route);
  document.getElementById("btn-new-car").addEventListener("click", () => carForm());
  route();
})();
