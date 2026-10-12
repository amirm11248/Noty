import "fake-indexeddb/auto";
import test from "node:test";
import assert from "node:assert/strict";
import { createNotebook, createFolder, loadLibrary, getNotebook, saveNotebook, saveAsset, assetBlob, importNotebook, deleteNotebook, ConflictError } from "../src/local-library.mjs";
import { draftKey, saveDraft, readDraft, movePage } from "../src/local-editor.mjs";

globalThis.fetch = () => { throw new Error("A local library must never contact a backend."); };

test("notebooks, folders and binary files persist locally across reopening", async () => {
  const folder = await createFolder("Classes", null, "#5267A9");
  const doc = await createNotebook("Offline notes", folder.id, "#5267A9");
  const bytes = new Blob(["local PDF bytes"], { type: "application/pdf" });
  await saveAsset(doc.id, "source.pdf", bytes);
  const saved = await saveNotebook(doc, { title: "Saved notes", payload: { ...doc.payload, assets: ["source.pdf"] } });
  const reopened = await import("../src/local-library.mjs?reopened");
  const library = await reopened.loadLibrary();
  assert.equal(library.folders.find(f => f.id === folder.id).name, "Classes");
  assert.equal(library.docs.find(d => d.id === doc.id).title, "Saved notes");
  assert.equal(await (await reopened.assetBlob(saved, "SOURCE.PDF")).text(), "local PDF bytes");
  assert.equal("user_id" in saved, false);
});

test("concurrent browser edits cannot overwrite a newer local revision", async () => {
  const doc = await createNotebook("Two tabs", null, "#5267A9");
  const outcomes = await Promise.allSettled([
    saveNotebook(doc, { title: "First tab" }), saveNotebook(doc, { title: "Second tab" }),
  ]);
  assert.equal(outcomes.filter(r => r.status === "fulfilled").length, 1);
  assert.equal(outcomes.filter(r => r.status === "rejected" && r.reason instanceof ConflictError).length, 1);
  assert.equal((await getNotebook(doc.id)).revision, 2);
  await assert.rejects(deleteNotebook(doc), ConflictError);
});

test("a failed import leaves neither a partial notebook nor its assets", async () => {
  const id = crypto.randomUUID();
  const sample = await createNotebook("Import template", null, "#5267A9");
  await assert.rejects(importNotebook({ ...sample, id }, [
    { name: "source.pdf", file: new Blob(["PDF"]) },
    { name: "../outside", file: new Blob(["invalid"]) },
  ]), /Invalid local file path/);
  assert.equal(await getNotebook(id), undefined);
  await assert.rejects(assetBlob({ ...sample, id }, "source.pdf"), /Local file is missing/);
});

test("permanent local deletion removes the notebook and its files", async () => {
  const doc = await createNotebook("Disposable", null, "#5267A9");
  await saveAsset(doc.id, "original.docx", new Blob(["Word bytes"]));
  await deleteNotebook(doc);
  assert.equal(await getNotebook(doc.id), undefined);
  await assert.rejects(assetBlob(doc, "original.docx"), /Local file is missing/);
});

test("old account and recording metadata does not enter local saves", async () => {
  const sample = await createNotebook("Legacy template", null, "#5267A9");
  const imported = await importNotebook({ ...sample, id: crypto.randomUUID(), user_id: "old-account",
    payload: { ...sample.payload, audioClips: [{ fileName: "old.m4a" }], assetManifest: { "old.pdf": { object_key: "old-cloud-key" } } } });
  assert.equal("user_id" in imported, false);
  assert.equal("audioClips" in imported.payload, false);
  assert.equal("assetManifest" in imported.payload, false);
  assert.equal(imported.payload.pages.length, sample.payload.pages.length);
});

test("local drafts survive a failed save and page movement preserves covers", () => {
  const values = new Map();
  const storage = { getItem: key => values.get(key), setItem: (key, value) => values.set(key, value) };
  const doc = { id: crypto.randomUUID(), title: "Unsaved local notes" };
  saveDraft(storage, doc, 7);
  assert.equal(readDraft(storage, doc).document.title, doc.title);
  assert.equal(readDraft(storage, doc).baseRevision, 7);
  assert.equal(draftKey(doc).includes("account"), false);
  assert.equal(readDraft(storage, { id: crypto.randomUUID() }), null);
  const pages = [{ id: "cover", isCover: true }, { id: "first" }, { id: "second" }];
  assert.deepEqual(movePage(pages, "first", -1), pages);
  assert.deepEqual(movePage(pages, "first", 1).map(p => p.id), ["cover", "second", "first"]);
});
