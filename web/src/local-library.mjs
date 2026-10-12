import { safePath } from "./native-library.mjs";

const databaseName = "noty-local-library";
let database;
export class ConflictError extends Error {
  constructor() {
    super("This notebook changed in another browser tab. Your draft is retained. Save a copy or reload it.");
  }
}
function openDatabase() {
  if (!database) database = new Promise((resolve, reject) => {
    const request = indexedDB.open(databaseName, 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      db.createObjectStore("notebooks", { keyPath: "id" });
      db.createObjectStore("folders", { keyPath: "id" });
      const assets = db.createObjectStore("assets", { keyPath: ["documentID", "name"] });
      assets.createIndex("documentID", "documentID");
    };
    request.onerror = () => { database = undefined; reject(request.error); };
    request.onsuccess = () => {
      const db = request.result;
      db.onversionchange = () => { db.close(); database = undefined; };
      resolve(db);
    };
  });
  return database;
}
async function transaction(stores, mode, run) {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(stores, mode);
    let result;
    tx.oncomplete = () => resolve(result);
    tx.onabort = () => reject(tx.error || new Error("Local save failed. Check browser storage space."));
    tx.onerror = () => reject(tx.error);
    const fail = error => { reject(error); tx.abort(); };
    try { run(tx, value => { result = value; }, fail); }
    catch (error) { fail(error); }
  });
}
function cleanPayload(payload) {
  const { audioClips, assetManifest, ...local } = payload;
  return local;
}
export async function loadLibrary() {
  return transaction(["notebooks", "folders"], "readonly", (tx, result) => {
    const library = { docs: [], folders: [] };
    tx.objectStore("notebooks").getAll().onsuccess = e => { library.docs = e.target.result; };
    tx.objectStore("folders").getAll().onsuccess = e => { library.folders = e.target.result; };
    result(library);
  });
}
export async function getNotebook(id) {
  return transaction(["notebooks"], "readonly", (tx, result) => {
    tx.objectStore("notebooks").get(id).onsuccess = e => result(e.target.result);
  });
}
export async function createNotebook(title, folderId, color, kind = "note", payload) {
  const now = new Date().toISOString();
  const doc = {
    id: crypto.randomUUID(), title: title.trim(), folder_id: folderId, kind,
    payload: cleanPayload(payload || {
      pages: [{ id: crypto.randomUUID(), template: "blank", textBoxes: [], images: [],
        sizePreset: "letter", orientation: "portrait", paperColorHex: "FFFFFF", webHTML: "" }],
      cover: { colorHex: color.replace("#", ""), style: "gradient" },
    }),
    starred: false, trashed_at: null, created_at: now, updated_at: now, revision: 1,
  };
  return transaction(["notebooks"], "readwrite", (tx, result) => {
    tx.objectStore("notebooks").add(doc); result(doc);
  });
}
export async function saveNotebook(doc, changes) {
  return transaction(["notebooks"], "readwrite", (tx, result, fail) => {
    const store = tx.objectStore("notebooks");
    store.get(doc.id).onsuccess = e => {
      const current = e.target.result;
      if (!current || current.revision !== doc.revision) { fail(new ConflictError()); return; }
      const allowed = Object.fromEntries(Object.entries(changes).filter(([key]) =>
        ["title", "kind", "folder_id", "payload", "starred", "trashed_at"].includes(key)));
      const saved = { ...current, ...allowed,
        payload: cleanPayload(allowed.payload || current.payload),
        revision: current.revision + 1, updated_at: new Date().toISOString() };
      store.put(saved); result(saved);
    };
  });
}
export async function createFolder(name, parentId, color) {
  const folder = { id: crypto.randomUUID(), name: name.trim(), parent_id: parentId, color,
    updated_at: new Date().toISOString(), payload: { design: { style: "minimal", colorHex: color.replace("#", "") } } };
  return importFolder(folder);
}
export async function importFolder(folder) {
  return transaction(["folders"], "readwrite", (tx, result) => {
    tx.objectStore("folders").add(folder); result(folder);
  });
}
export async function importNotebook(doc, assets = []) {
  const now = new Date().toISOString();
  const { user_id, ...fields } = doc;
  const local = { ...fields, payload: cleanPayload(doc.payload), starred: !!doc.starred,
    trashed_at: doc.trashed_at || null, created_at: doc.created_at || now,
    updated_at: doc.updated_at || now, revision: 1 };
  return transaction(["notebooks", "assets"], "readwrite", (tx, result) => {
    tx.objectStore("notebooks").add(local);
    for (const { name, file } of assets) {
      validateAsset(name, file);
      tx.objectStore("assets").put({ documentID: local.id, name, file });
    }
    result(local);
  });
}
function validateAsset(name, file) {
  if (!safePath(name) || !name) throw new Error("Invalid local file path.");
  if (!(file instanceof Blob) || file.size > 250 * 1024 * 1024) throw new Error("Choose a file under 250 MB.");
}
export async function saveAsset(documentID, name, file) {
  validateAsset(name, file);
  return transaction(["assets"], "readwrite", (tx, result) => {
    tx.objectStore("assets").put({ documentID, name, file }); result(name);
  });
}
export async function assetBlob(doc, name) {
  if (!safePath(name)) throw new Error("Invalid local file path.");
  const assets = await transaction(["assets"], "readonly", (tx, result) => {
    tx.objectStore("assets").index("documentID").getAll(doc.id).onsuccess = e => result(e.target.result);
  });
  const asset = assets.find(a => a.name.toLowerCase() === name.toLowerCase());
  if (!asset) throw new Error(`Local file is missing: ${name}. Import the complete notebook backup.`);
  return asset.file;
}
export async function assetURL(doc, name) { return URL.createObjectURL(await assetBlob(doc, name)); }
export async function deleteNotebook(doc) {
  return transaction(["notebooks", "assets"], "readwrite", (tx, result, fail) => {
    const notebooks = tx.objectStore("notebooks");
    notebooks.get(doc.id).onsuccess = e => {
      if (!e.target.result || e.target.result.revision !== doc.revision) { fail(new ConflictError()); return; }
      notebooks.delete(doc.id);
      const assets = tx.objectStore("assets");
      assets.index("documentID").openCursor(IDBKeyRange.only(doc.id)).onsuccess = e => {
        const cursor = e.target.result;
        if (cursor) { cursor.delete(); cursor.continue(); }
      };
      result(undefined);
    };
  });
}
