// Theme, the scrollbar that hides at the top, code colouring and the header's shared markup.
const root = document.documentElement;

function stored() {
  try {
    return localStorage.getItem("theme");
  } catch {
    return null;
  }
}

function currentTheme() {
  return root.dataset.theme || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
}

document.getElementById("theme")?.addEventListener("click", () => {
  const next = currentTheme() === "dark" ? "light" : "dark";
  root.dataset.theme = next;
  try {
    localStorage.setItem("theme", next);
  } catch {
    // Private windows may refuse; the page still switches for this visit.
  }
});
if (stored()) root.dataset.theme = stored();

const mark = () => root.classList.toggle("at-top", scrollY === 0);
addEventListener("scroll", mark, { passive: true });
mark();

export function escapeHtml(text) {
  return text.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);
}

const KEYWORDS = /^(?:let|mut|fn|async|pub|priv|struct|enum|suberror|trait|impl|for|with|match|if|else|guard|is|try|catch|noraise|raise|return|while|in|import|test|defer)$/;

function highlightMoonBit(text) {
  const token = /(\/\/.*$|#\|.*$)|("(?:[^"\\]|\\.)*")|(@[a-z_]+)|\b([A-Za-z_][A-Za-z0-9_]*)\b|(-?\b\d[\d_.]*\b)/gm;
  let out = "";
  let at = 0;
  for (const m of text.matchAll(token)) {
    out += escapeHtml(text.slice(at, m.index));
    at = m.index + m[0].length;
    const shown = escapeHtml(m[0]);
    if (m[1]) out += `<span class="${m[1].startsWith("#|") ? "s" : "c"}">${shown}</span>`;
    else if (m[2]) out += `<span class="s">${shown}</span>`;
    else if (m[3]) out += `<span class="t">${shown}</span>`;
    else if (m[4]) out += KEYWORDS.test(m[4]) ? `<span class="w">${shown}</span>` : /^[A-Z]/.test(m[4]) ? `<span class="t">${shown}</span>` : shown;
    else out += `<span class="n">${shown}</span>`;
  }
  return out + escapeHtml(text.slice(at));
}

for (const code of document.querySelectorAll("pre code.mbt")) {
  code.innerHTML = highlightMoonBit(code.textContent);
}
