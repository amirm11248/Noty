import { useState, useRef } from "react";
import { Upload, FolderOpen, Loader2, Check } from "./icons";
import { unzipSync } from "fflate";
import { Modal } from "./ui";
import { cloud, createNotebook, uploadAsset, uploadedManifest } from "./cloud";
import { newPage, palette } from "./types";
import type { Notebook, Payload, Folder, Page } from "./types";
import {
  resolveLibrary,
  findAssets,
  nativeDate,
  safePath,
} from "./native-library.mjs";
import { escapeHTML, sanitizeHTML } from "./html";

export default function ImportLibrary({
  open,
  onClose,
  userId,
  folderId,
  existing,
  onComplete,
  notify,
}: {
  open: boolean;
  onClose: () => void;
  userId: string;
  folderId: string | null;
  existing: Notebook[];
  onComplete: () => void;
  notify: (text: string) => void;
}) {
  const [tab, setTab] = useState("documents");
  const [files, setFiles] = useState<File[]>([]);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState("");
  const [error, setError] = useState("");
  const [result, setResult] = useState("");
  const guard = useRef(false);
  async function entriesForFiles() {
    const entries = new Map<string, Blob>();
    if (files.length === 1 && files[0].name.toLowerCase().endsWith(".zip")) {
      if (files[0].size > 250 * 1024 * 1024)
        throw new Error("Choose a ZIP under 50 MB, or use Select folder.");
      let size = 0;
      let blocked = false;
      const extracted = unzipSync(
        new Uint8Array(await files[0].arrayBuffer()),
        {
          filter: (f) => {
            size += f.originalSize;
            if (size > 200 * 1024 * 1024 || f.originalSize > 250 * 1024 * 1024) {
              blocked = true;
              return false;
            }
            return safePath(f.name);
          },
        },
      );
      if (blocked)
        throw new Error(
          "This ZIP exceeds the 200 MB unpacked limit. Use Select folder instead.",
        );
      for (const [name, data] of Object.entries(extracted)) {
        if (!name.endsWith("/"))
          entries.set(name, new Blob([data as Uint8Array<ArrayBuffer>]));
      }
    } else
      for (const file of files)
        entries.set(file.webkitRelativePath || file.name, file);
    return entries;
  }
  async function importNative() {
    const library = await resolveLibrary(await entriesForFiles());
    const { data: existingFolders, error: folderError } = await cloud
      .from("noty_web_folders")
      .select("id")
      .eq("user_id", userId);
    if (folderError) throw folderError;
    const folderIds = new Set(existingFolders.map((f) => f.id));
    const incomingIds = new Set(
      library.manifest.folders.map((f) => f.id.toLowerCase()),
    );
    for (const f of library.manifest.folders) {
      const id = f.id.toLowerCase();
      if (folderIds.has(id)) continue;
      const folder: Omit<Folder, "updated_at"> = {
        id,
        user_id: userId,
        name: f.name,
        parent_id:
          f.parentID && incomingIds.has(f.parentID.toLowerCase())
            ? f.parentID.toLowerCase()
            : null,
        color: `#${f.design?.colorHex || "5267A9"}`,
        payload: {design:f.design,symbol:f.symbol,imageData:f.imageData},
      };
      const { error } = await cloud.from("noty_web_folders").insert(folder);
      if (error) throw error;
      folderIds.add(id);
    }
    let imported = 0,
      skipped = 0;
    for (const native of library.manifest.documents) {
      const id = native.id.toLowerCase();
      if (existing.some((d) => d.id === id)) {
        skipped++;
        continue;
      }
      setProgress(
        `Uploading “${native.title}” (${imported + skipped + 1}/${library.manifest.documents.length})`,
      );
      const assets = findAssets(library, native.id);
      for (const asset of assets)
        await uploadAsset(userId, id, asset.name, asset.file);
      const payload: Payload = native.payload || {
        ...native,
        pages: native.pages,
      };
      payload.assets = assets.map((a) => a.name);
      if (assets.some((a) => a.name === "source.pdf"))
        payload.sourcePDF = "source.pdf";
      payload.assetManifest=uploadedManifest(userId,id);
      const { error } = await cloud
        .from("noty_web_documents")
        .insert({
          id,
          user_id: userId,
          title: native.title,
          kind: ["note", "pdf", "book", "whiteboard"].includes(native.kind)
            ? native.kind
            : "note",
          folder_id: folderIds.has(
            (native.folderID || native.folder_id || "").toLowerCase(),
          )
            ? (native.folderID || native.folder_id).toLowerCase()
            : null,
          payload,
          starred: !!native.starred,
          created_at: nativeDate(native.createdAt || native.created_at),
        });
      if (error) throw error;
      imported++;
    }
    return `${imported} notebook${imported === 1 ? "" : "s"} imported.${skipped ? ` ${skipped} already in your library; kept unchanged.` : ""}`;
  }
  async function importDocuments() {
    let count = 0;
    for (const file of files) {
      if (file.size > 250 * 1024 * 1024)
        throw new Error(`${file.name} is larger than 250 MB.`);
      setProgress(`Importing “${file.name}” (${count + 1}/${files.length})`);
      const extension = file.name.split(".").pop()?.toLowerCase();
      const title =
        file.name.replace(/\.[^.]+$/, "").slice(0, 300) || "Untitled";
      let payload: Payload = {
        pages: [newPage()],
        cover: {
          colorHex: palette[count % palette.length].replace("#", ""),
          style: "gradient",
        },
      };
      let kind = "note";
      if (extension === "pdf") {
        const { getPDFInfo } = await import("./pdf");
        const info = await getPDFInfo(file);
        payload.pages = Array.from({ length: info.pages }, (_, i) => ({
          ...newPage(),
          sourcePageIndex: i,
        }));
        payload.sourcePDF = "source.pdf";
        payload.assets = ["source.pdf"];
        kind = "pdf";
      } else if (extension === "docx") {
        const mammoth = await import("mammoth");
        const { value } = await mammoth.extractRawText({
          arrayBuffer: await file.arrayBuffer(),
        });
        payload.pages[0].webHTML = value
          .split("\n")
          .map((p) => `<p>${escapeHTML(p)}</p>`)
          .join("");
        payload.pages[0].textBoxes = [
          {
            id: crypto.randomUUID(),
            text: value,
            x: 24,
            y: 24,
            width: 564,
            height: 720,
            fontSize: 16,
          },
        ];
        payload.assets = ["original.docx"];
      } else if (["txt", "md", "html"].includes(extension || "")) {
        const text = await file.text();
        payload.pages[0].webHTML =
          extension === "html"
            ? sanitizeHTML(text)
            : text
                .split("\n")
                .map((p) => `<p>${escapeHTML(p)}</p>`)
                .join("");
        const plain =
          extension === "html"
            ? new DOMParser().parseFromString(
                payload.pages[0].webHTML,
                "text/html",
              ).body.textContent || ""
            : text;
        payload.pages[0].textBoxes = [
          {
            id: crypto.randomUUID(),
            text: plain,
            x: 24,
            y: 24,
            width: 564,
            height: 720,
            fontSize: 16,
          },
        ];
      } else if (["png","jpg","jpeg","webp"].includes(extension||"")) {
        const image=await createImageBitmap(file);const name=file.name;const page=payload.pages[0];
        page.images=[{id:crypto.randomUUID(),fileName:name,x:24,y:60,width:Math.min(image.width,564),height:Math.min(image.width,564)*image.height/image.width,rotationDegrees:0}];image.close();
        payload.assets=[`Images/${page.id.toUpperCase()}/${name}`];
      } else throw new Error("Choose PDF, DOCX, TXT, Markdown, HTML or an image.");
      // Upload before inserting metadata so an incomplete upload never appears as an imported document.
      const id = crypto.randomUUID();
      if (extension === "pdf")
        await uploadAsset(userId, id, "source.pdf", file);
      if (extension === "docx")
        await uploadAsset(userId, id, "original.docx", file);
      if (["png","jpg","jpeg","webp"].includes(extension||""))await uploadAsset(userId,id,payload.assets![0],file);
      payload.assetManifest=uploadedManifest(userId,id);
      const { error } = await cloud
        .from("noty_web_documents")
        .insert({
          id,
          user_id: userId,
          title,
          kind,
          folder_id: folderId,
          payload,
        });
      if (error) throw error;
      count++;
    }
    return `${count} document${count === 1 ? "" : "s"} imported.`;
  }
  async function run() {
    if (guard.current || !files.length) return;
    guard.current = true;
    setBusy(true);
    setError("");
    setResult("");
    try {
      const message =
        tab === "library" ? await importNative() : await importDocuments();
      setResult(message);
      setFiles([]);
      notify(message);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      guard.current = false;
      setBusy(false);
      setProgress("");
      onComplete();
    }
  }
  return (
    <Modal
      open={open}
      onOpenChange={(v) => !v && !busy && onClose()}
      title="Bring your ideas along."
      description="Add documents or import your existing Noty library."
      wide
    >
      <div className="import-tabs" role="tablist" aria-label="Import type">
        <button
          role="tab"
          aria-selected={tab === "documents"}
          className={tab === "documents" ? "active" : ""}
          disabled={busy}
          onClick={() => {
            setTab("documents");
            setFiles([]);
            setError("");
            setResult("");
          }}
        >
          Documents
        </button>
        <button
          role="tab"
          aria-selected={tab === "library"}
          className={tab === "library" ? "active" : ""}
          disabled={busy}
          onClick={() => {
            setTab("library");
            setFiles([]);
            setError("");
            setResult("");
          }}
        >
          Noty library
        </button>
      </div>
      <div className="import-drop">
        <Upload size={26} />
        <strong>
          {files.length
            ? `${files.length} file${files.length === 1 ? "" : "s"} selected`
            : "Choose files to import"}
        </strong>
        <small>
          {tab === "library"
            ? "Noty Sync ZIP or backup JSON"
            : "PDF, DOCX, TXT, Markdown or HTML · up to 250 MB each"}
        </small>
        <input
          type="file"
          disabled={busy}
          aria-label="Choose files to import"
          accept={
            tab === "library" ? ".zip,.json" : ".pdf,.docx,.txt,.md,.html,.png,.jpg,.jpeg,.webp"
          }
          multiple={tab === "documents"}
          onChange={(e) => {
            setFiles([...(e.target.files || [])]);
            setError("");
            setResult("");
            e.target.value = "";
          }}
        />
      </div>
      {tab === "library" && (
        <>
          <label className="button secondary full import-folder-button">
            <FolderOpen size={17} />
            Select Noty Sync folder
            <input
              type="file"
              aria-label="Select Noty Sync folder"
              disabled={busy}
              multiple
              {...({ webkitdirectory: "", directory: "" } as any)}
              onChange={(e) => {
                setFiles([...(e.target.files || [])]);
                setError("");
                setResult("");
                e.target.value = "";
              }}
            />
          </label>
          <p className="import-copy">
            Download your <strong>Noty Sync</strong> folder from iCloud Drive to
            this computer, then select it here. Imported notebooks join your shared cloud library. Existing cloud notebooks are skipped.
          </p>
          <div className="import-warning">
            Typed notes, images, study cards and original PDFs are supported.
            Apple Pencil files are retained. Ink previews become available after syncing from the updated iPad app.
          </div>
        </>
      )}
      {tab === "documents" && (
        <p className="import-copy">
          PDFs keep their original layout. Word files become editable text; the
          original DOCX is kept with your notebook.
        </p>
      )}
      {files.length > 0 && (
        <div className="import-files">
          {files.slice(0, 5).map((f, i) => (
            <div key={i}>{f.name}</div>
          ))}
          {files.length > 5 && <div>and {files.length - 5} more files</div>}
        </div>
      )}
      {busy && (
        <div className="import-progress" role="status">
          <Loader2 size={17} className="spin" />
          {progress}
        </div>
      )}
      {error && (
        <p className="form-error" role="alert" style={{ marginTop: 15 }}>
          {error} Any completed imports are already saved.
        </p>
      )}
      {result && (
        <p className="import-results" role="status">
          <Check size={15} /> {result}
        </p>
      )}
      <button
        className="button primary full"
        style={{ marginTop: 20 }}
        disabled={busy || !files.length}
        onClick={() => void run()}
      >
        {busy ? <Loader2 size={17} className="spin" /> : <Upload size={17} />}{" "}
        {busy ? "Importing…" : "Import to your library"}
      </button>
    </Modal>
  );
}
