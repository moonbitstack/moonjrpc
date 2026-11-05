// Draws what the library wrote. Nothing here decides anything about JSON-RPC beyond reading the fields.
import { escapeHtml } from "./site.js";

/** Syntax-coloured, indented JSON. Text that does not parse is shown as it is. */
export function prettyJson(text) {
  let shown;
  try {
    shown = JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return escapeHtml(text);
  }
  return shown.replace(/("(?:[^"\\]|\\.)*")(\s*:)?|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[&<>]/g, (m, str, colon) => {
    if (str) return colon ? `<span class="k">${escapeHtml(str)}</span>${colon}` : `<span class="s">${escapeHtml(str)}</span>`;
    if (m === "&" || m === "<" || m === ">") return escapeHtml(m);
    return /\d/.test(m) ? `<span class="n">${m}</span>` : `<span class="l">${m}</span>`;
  });
}

function describe(text) {
  const message = JSON.parse(text);
  const id = "id" in message ? ` #${message.id}` : "";
  if (message.method !== undefined && "id" in message) return { kind: "call", label: `<b>call</b> ${escapeHtml(String(message.method))}${id}` };
  if (message.method !== undefined) return { kind: "notice", label: `<b>notice</b> ${escapeHtml(String(message.method))}` };
  if (message.error) return { kind: "fail", label: `<b>error</b> ${message.error.code} ${escapeHtml(String(message.error.message))}${id}` };
  return { kind: "reply", label: `<b>reply</b>${id}` };
}

/** One row per thing written or done. Each message opens to show the JSON that went across. */
export function renderConversation(host, log, animate = true) {
  host.classList.remove("play");
  // Forcing a layout restarts the animation when the same element replays.
  void host.offsetWidth;
  const rows = log.map((entry, i) => {
    if (entry.note !== undefined) {
      return `<li class="note at-${entry.from}" style="--i:${i}"><span>${escapeHtml(entry.note)}</span></li>`;
    }
    const { kind, label } = describe(entry.text);
    const direction = entry.from === "editor" ? "to-right" : "to-left";
    return `<li class="msg ${kind} ${direction}" style="--i:${i}"><button type="button" aria-expanded="false"><span class="label">${label}</span><span class="arrow"></span></button><pre hidden><code>${prettyJson(entry.text)}</code></pre></li>`;
  });
  const list = host.querySelector(".rows");
  list.innerHTML = rows.join("");
  for (const button of list.querySelectorAll("button")) {
    button.addEventListener("click", () => {
      const open = button.getAttribute("aria-expanded") === "true";
      button.setAttribute("aria-expanded", String(!open));
      button.nextElementSibling.hidden = open;
    });
  }
  if (animate) host.classList.add("play");
}
