export function escapeHTML(text: string) {
  return text.replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
}
export function sanitizeHTML(html: string) {
  const doc = new DOMParser().parseFromString(html, "text/html");
  const allowed = new Set([
    "P",
    "BR",
    "STRONG",
    "B",
    "EM",
    "I",
    "U",
    "S",
    "H1",
    "H2",
    "H3",
    "UL",
    "OL",
    "LI",
    "BLOCKQUOTE",
    "PRE",
    "CODE",
    "HR",
  ]);
  doc
    .querySelectorAll(
      "script,style,iframe,object,embed,form,input,svg,math,link,meta",
    )
    .forEach((n) => n.remove());
  for (const node of [...doc.body.querySelectorAll("*")].reverse()) {
    for (const attr of [...node.attributes]) {
      const keep =
        (attr.name === "data-type" &&
          ((node.tagName === "UL" && attr.value === "taskList") ||
            (node.tagName === "LI" && attr.value === "taskItem"))) ||
        (node.tagName === "LI" &&
          attr.name === "data-checked" &&
          ["true", "false"].includes(attr.value));
      if (!keep) node.removeAttribute(attr.name);
    }
    if (!allowed.has(node.tagName)) node.replaceWith(...node.childNodes);
  }
  return doc.body.innerHTML;
}
