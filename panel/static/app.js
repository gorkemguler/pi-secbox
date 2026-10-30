"use strict";

const STATUS = {
  running: ["çalışıyor", "run"],
  done: ["bitti", "ok"],
  failed: ["hata", "bad"],
  stopped: ["durduruldu", "warn"],
  unknown: ["bilinmiyor", "warn"],
};

document.addEventListener("DOMContentLoaded", () => {
  loadTor();

  // Onay isteyen formlar (sil, durdur, kapat).
  document.querySelectorAll("form[data-confirm]").forEach((form) => {
    form.addEventListener("submit", (e) => {
      if (!window.confirm(form.dataset.confirm)) e.preventDefault();
    });
  });

  // Tarama formu: seçilen komuta göre ilgili alanları göster.
  const cmd = document.getElementById("cmd");
  if (cmd) {
    const sync = () => document.querySelectorAll("[data-for]").forEach((el) => {
      el.hidden = !el.dataset.for.split(" ").includes(cmd.value);
    });
    cmd.addEventListener("change", sync);
    sync();
  }

  // Zamanlama formu: "Özel" seçilince OnCalendar alanını aç.
  const when = document.getElementById("when");
  const custom = document.getElementById("when-custom-row");
  if (when && custom) {
    const sync = () => { custom.hidden = when.value !== "custom"; };
    when.addEventListener("change", sync);
    sync();
  }

  const log = document.getElementById("joblog");
  if (log) followJob(log);
});

async function loadTor() {
  const badges = document.querySelectorAll("[data-tor]");
  const ip = document.querySelector("[data-tor-ip]");
  if (!badges.length && !ip) return;
  try {
    const r = await fetch("/api/tor");
    if (!r.ok) return;
    const d = await r.json();
    badges.forEach((b) => {
      b.querySelector("span").textContent = d.ok ? `Tor: ${d.ip}` : "Tor: bağlantı yok";
      b.classList.add(d.ok ? "ok" : "bad");
    });
    if (ip) ip.textContent = d.ok ? d.ip : "bağlantı yok";
  } catch (e) {
    /* Tor durumu gösterilemezse sayfa yine çalışır. */
  }
}

// İş günlüğünü sunucudan parça parça çeker; iş bitince durur.
function followJob(el) {
  const id = el.dataset.job;
  const status = document.getElementById("job-status");
  const result = document.getElementById("job-result");
  const stop = document.getElementById("job-stop");
  let offset = 0;

  const tick = async () => {
    let d;
    try {
      const r = await fetch(`/api/jobs/${encodeURIComponent(id)}?offset=${offset}`);
      if (!r.ok) throw new Error(String(r.status));
      d = await r.json();
    } catch (e) {
      setTimeout(tick, 5000);
      return;
    }
    if (d.text) {
      const atBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 24;
      el.textContent += d.text;
      if (atBottom) el.scrollTop = el.scrollHeight;
    }
    offset = d.offset;
    const [label, cls] = STATUS[d.status] || [d.status, "warn"];
    status.textContent = label;
    status.className = `badge ${cls}`;
    if (d.run_url) {
      result.hidden = false;
      result.querySelector("a").href = d.run_url;
    }
    if (d.status === "running") setTimeout(tick, 1500);
    else if (d.text) setTimeout(tick, 100);
    else if (stop) stop.hidden = true;
  };
  tick();
}
