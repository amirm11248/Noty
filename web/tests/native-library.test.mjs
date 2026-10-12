import { test } from "node:test";
import assert from "node:assert/strict";
import {
  resolveLibrary,
  findAssets,
  nativeDate,
  safePath,
} from "../src/native-library.mjs";
const id = "aabbeedd-1111-2222-3333-aabbccddeeff",
  pageID = "aabbeedd-1111-2222-3333-112233445566",
  generation = "aabbeedd-1111-2222-3333-222222222222",
  revision = "aabbeedd-1111-2222-3333-333333333333";
const doc = {
  id,
  title: "Test notebook",
  kind: "note",
  pages: [{ id: pageID, textBoxes: [], images: [] }],
};
const blob = (value) => new Blob([JSON.stringify(value)]);
test("imports only the generation selected by Current.json and its asset revision", async () => {
  const entries = new Map([
    [
      "Noty Sync/Current.json",
      blob({ generationID: generation.toUpperCase() }),
    ],
    [
      `Noty Sync/Snapshots/${generation}/manifest.json`,
      blob({
        manifest: { documents: [doc], folders: [] },
        packages: [{ documentID: id, revisionID: revision }],
      }),
    ],
    [
      `Noty Sync/Snapshots/old/manifest.json`,
      blob({ manifest: { documents: [], folders: [] } }),
    ],
    [
      `Noty Sync/Packages/${id.toUpperCase()}/${revision}/source.pdf`,
      new Blob(["pdf"]),
    ],
    [`Noty Sync/Packages/${id}/old/source.pdf`, new Blob(["stale"])],
  ]);
  const library = await resolveLibrary(entries);
  assert.equal(library.manifest.documents.length, 1);
  assert.equal(findAssets(library, id).length, 1);
  assert.equal(await findAssets(library, id)[0].file.text(), "pdf");
});
test("refuses partial sync downloads rather than importing a stale snapshot", async () => {
  await assert.rejects(
    resolveLibrary(
      new Map([
        ["Current.json", blob({ generationID: generation })],
        ["Snapshots/old/manifest.json", blob({ documents: [], folders: [] })],
      ]),
    ),
    /current library snapshot is missing/,
  );
});
test("rejects malformed notebook IDs, duplicate IDs and damaged pages", async () => {
  for (const documents of [
    [{ ...doc, id: "bad" }],
    [doc, doc],
    [{ ...doc, pages: [{ id: pageID }] }],
  ])
    await assert.rejects(
      resolveLibrary(
        new Map([["manifest.json", blob({ documents, folders: [] })]]),
      ),
    );
});
test("accepts single manifest backups and keeps nested asset paths", async () => {
  const library = await resolveLibrary(
    new Map([
      ["manifest.json", blob({ documents: [doc], folders: [] })],
      [`Assets/${id}/Drawings/${pageID}.drawing`, new Blob(["ink"])],
    ]),
  );
  assert.equal(findAssets(library, id)[0].name, `Drawings/${pageID}.drawing`);
});
test("handles native reference dates and sync millisecond timestamps", () => {
  assert.equal(nativeDate(0), "2001-01-01T00:00:00.000Z");
  assert.equal(nativeDate(1750000000000), "2025-06-15T15:06:40.000Z");
  assert.equal(nativeDate("2026-10-02T12:00:00Z"), "2026-10-02T12:00:00.000Z");
});
test("refuses unsafe archive paths", () => {
  assert.equal(safePath("../x"), false);
  assert.equal(safePath("/x"), false);
  assert.equal(safePath("Assets/../../x"), false);
  assert.equal(safePath("Assets/x.pdf"), true);
});
