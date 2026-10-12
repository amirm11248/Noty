const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function validID(value) {
  return typeof value === "string" && uuid.test(value);
}
export function nativeDate(value) {
  if (typeof value === "string") {
    const date = new Date(value);
    if (!Number.isNaN(date.valueOf())) return date.toISOString();
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    const ms =
      value > 1e12
        ? value
        : value > 1e9
          ? value * 1000
          : (value + 978307200) * 1000;
    return new Date(ms).toISOString();
  }
  return new Date().toISOString();
}
export function safePath(path) {
  return (
    typeof path === "string" &&
    !path.startsWith("/") &&
    !path.split("/").some((p) => p === ".." || p === ".") &&
    !path.includes("\\") &&
    !path.includes("\0")
  );
}
export async function resolveLibrary(entries) {
  const paths = [...entries.keys()].filter(safePath);
  const pointerPath = paths.find(
    (p) =>
      p.toLowerCase().endsWith("/current.json") ||
      p.toLowerCase() === "current.json",
  );
  let selectedPath;
  if (pointerPath) {
    const pointer = JSON.parse(await entries.get(pointerPath).text());
    if (!validID(pointer.generationID))
      throw new Error("The library pointer is damaged.");
    const root = pointerPath.slice(0, -"current.json".length);
    selectedPath = paths.find(
      (p) =>
        p.toLowerCase() ===
        `${root}snapshots/${pointer.generationID}/manifest.json`.toLowerCase(),
    );
    if (!selectedPath)
      throw new Error(
        "The current library snapshot is missing. Download the complete Noty Sync folder and try again.",
      );
  } else {
    const candidates = paths.filter(
      (p) =>
        p.toLowerCase().endsWith("manifest.json") ||
        p.toLowerCase().endsWith("library.json") ||
        p.toLowerCase().endsWith("noty-backup.json"),
    );
    if (candidates.length > 1) {
      const nonSnapshots = candidates.filter(
        (p) => !p.toLowerCase().includes("/snapshots/"),
      );
      if (nonSnapshots.length === 1) selectedPath = nonSnapshots[0];
      else
        throw new Error(
          "Multiple library snapshots found. Select the complete Noty Sync folder with its current.json file.",
        );
    } else selectedPath = candidates[0];
  }
  if (!selectedPath)
    throw new Error(
      "No Noty library found. Choose a Noty Sync folder, a ZIP of it, or a Noty backup JSON.",
    );
  const raw = JSON.parse(await entries.get(selectedPath).text());
  const manifest = raw.manifest || raw;
  if (!Array.isArray(manifest.documents) || !Array.isArray(manifest.folders))
    throw new Error("This file is not a Noty library.");
  if (manifest.documents.length > 5000)
    throw new Error("Import at most 5,000 notebooks at a time.");
  const ids = new Set();
  for (const doc of manifest.documents) {
    if (
      !validID(doc.id) ||
      ids.has(doc.id.toLowerCase()) ||
      typeof doc.title !== "string" ||
      !doc.title.trim() ||
      doc.title.length > 300
    )
      throw new Error("The library contains an invalid notebook.");
    ids.add(doc.id.toLowerCase());
    const pages = doc.pages || doc.payload?.pages;
    if (
      !Array.isArray(pages) ||
      pages.some(
        (p) =>
          !validID(p.id) ||
          !Array.isArray(p.textBoxes) ||
          !Array.isArray(p.images),
      )
    )
      throw new Error(`The pages in “${doc.title}” are damaged.`);
  }
  for (const folder of manifest.folders) {
    if (
      !validID(folder.id) ||
      typeof folder.name !== "string" ||
      !folder.name.trim() ||
      folder.name.length > 200
    )
      throw new Error("The library contains an invalid folder.");
  }
  return {
    manifest,
    packages: raw.packages || [],
    entries,
    paths,
    manifestPath: selectedPath,
  };
}
export function findAssets(library, docID) {
  const id = docID.toLowerCase();
  const reference = library.packages.find(
    (p) => p.documentID?.toLowerCase() === id,
  );
  let packageMarker;
  if (reference) {
    if (!validID(reference.revisionID))
      throw new Error("A notebook package reference is damaged.");
    packageMarker = `packages/${id}/${reference.revisionID.toLowerCase()}/`;
  }
  return library.paths.flatMap((path) => {
    const lower = path.toLowerCase();
    let start = -1;
    if (packageMarker) {
      const i = lower.indexOf(packageMarker);
      if (i >= 0) start = i + packageMarker.length;
    } else {
      for (const marker of [`assets/${id}/`, `documents/${id}/`]) {
        const i = lower.indexOf(marker);
        if (i >= 0) {
          start = i + marker.length;
          break;
        }
      }
    }
    if (start < 0) return [];
    const name = path.slice(start);
    return name && safePath(name)
      ? [{ name, file: library.entries.get(path) }]
      : [];
  });
}
