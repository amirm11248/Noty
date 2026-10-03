import {
  useState,
  useEffect,
  useRef,
  useCallback,
  lazy,
  Suspense,
} from "react";
import * as Alert from "@radix-ui/react-alert-dialog";
import {
  ArrowLeft,
  Plus,
  Star,
  MoreHorizontal,
  Check,
  Cloud,
  Loader2,
  Bold,
  Italic,
  Strikethrough,
  List,
  ListOrdered,
  ListChecks,
  Quote,
  Undo2,
  Redo2,
  Heading1,
  Heading2,
  Bookmark,
  Download,
  Trash2,
  Copy,
  ChevronLeft,
  ChevronRight,
  Layers,
  FileText,
  Printer,
  RefreshCw,
  X,
  ImagePlus,
  PanelLeft,
  Upload,
} from "./icons";
import { Modal, DropMenu } from "./ui";
import { saveNotebook, assetURL, cloud, uploadAsset, hydrateNotebook, uploadedManifest } from "./cloud";
import type { Notebook, Folder, Page, Payload } from "./types";
import { newPage, pageText } from "./types";
import { escapeHTML, sanitizeHTML } from "./html";
import { zipSync, strToU8 } from "fflate";
import NativePage from "./NativePage";
import {movePage, draftKey,saveDraft,readDraft,attachmentAssetPath} from "./sync-model.mjs";
const PDFPanel = lazy(() => import("./PDFPanel"));
const htmlForPage = (page: Page) =>
  page.webHTML
    ? sanitizeHTML(page.webHTML)
    : page.textBoxes
        .map(
          (t) =>
            `<p>${t.isBold ? "<strong>" : ""}${t.isItalic ? "<em>" : ""}${escapeHTML(t.text).replace(/\n/g, "<br>")}${t.isItalic ? "</em>" : ""}${t.isBold ? "</strong>" : ""}</p>`,
        )
        .join("");
function downloadBlob(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 15000);
}
function PageImage({ doc, name }: { doc: Notebook; name: string }) {
  const [url, setURL] = useState("");
  const [error, setError] = useState("");
  useEffect(() => {
    let active = true;
    let url = "";
    void assetURL(doc, name)
      .then((value) => {
        url = value;
        if (active) setURL(value);
        else URL.revokeObjectURL(value);
      })
      .catch((e) => {
        if (active) setError(e.message);
      });
    return () => {
      active = false;
      if (url) URL.revokeObjectURL(url);
    };
  }, [doc.id, name]);
  return error ? (
    <p className="native-ink-warning">An image could not be loaded. {error}</p>
  ) : url ? (
    <img className="page-image" src={url} alt="Notebook page attachment" />
  ) : (
    <div className="pdf-loading">
      <Loader2 size={17} className="spin" />
      Loading image…
    </div>
  );
}
export default function Editor({
  initialDoc,
  folders,
  onUpdate,
  onClose,
  notify,
}: {
  initialDoc: Notebook;
  folders: Folder[];
  onUpdate: (doc: Notebook) => void;
  onClose: () => void;
  notify: (text: string) => void;
}) {
  const [doc, setDoc] = useState(initialDoc);
  const saved = useRef(initialDoc);
  const conflicted = useRef(!!initialDoc.trashed_at);
  const draft = useRef(initialDoc);
  const [activeId, setActiveId] = useState(
    initialDoc.payload.pages.find((p) => !p.isCover)?.id ||
      initialDoc.payload.pages[0]?.id ||
      "",
  );
  const activeRef = useRef(activeId);
  const [status, setStatus] = useState("saved");
  const [error, setError] = useState("");
  const [toast, setToast] = useState("");
  const [showPages, setShowPages] = useState(() => window.matchMedia("(min-width: 761px)").matches);
  const [source, setSource] = useState(false);
  const [study, setStudy] = useState(false);
  const [studyIndex, setStudyIndex] = useState(0);
  const [flipped, setFlipped] = useState(false);
  const [question, setQuestion] = useState("");
  const [answer, setAnswer] = useState("");
  const [pageDelete, setPageDelete] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [uploading, setUploading] = useState(false);
  const imageInput = useRef<HTMLInputElement>(null);
  const attachmentInput = useRef<HTMLInputElement>(null);
  const [paperSettings, setPaperSettings] = useState(false);
  const [conflictReload, setConflictReload] = useState(false);
  const editVersion = useRef(0);
  const persistedVersion = useRef(0);
  const inFlight = useRef<Promise<void> | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const alive = useRef(true);
  const lastExportVersion = useRef(-1);
  const flash = (text: string) => {
    setToast(text);
  };
  const flush = useCallback(() => {
    if (timer.current) {
      clearTimeout(timer.current);
      timer.current = null;
    }
    if (inFlight.current) return inFlight.current;
    const run = async () => {
      while (persistedVersion.current < editVersion.current) {
        if(conflicted.current)throw new Error("Resolve the remote change before saving. Your draft is retained.");
        const version = editVersion.current;
        const snapshot = draft.current;
        if (alive.current) setStatus("saving");
        const updated = await saveNotebook(saved.current, {
          title: snapshot.title,
          payload: snapshot.payload,
          starred: snapshot.starred,
          folder_id: snapshot.folder_id,
        });
        saved.current = updated;
        persistedVersion.current = version;
        draft.current = {
          ...draft.current,
          revision: updated.revision,
          updated_at: updated.updated_at,
        };
        try { if(version < editVersion.current) saveDraft(localStorage,draft.current,updated.revision); } catch {}
        onUpdate(updated);
        if (alive.current) {
          setDoc(draft.current);
          setError("");
        }
      }
      localStorage.removeItem(draftKey(draft.current));
      if (alive.current) setStatus("saved");
    };
    const promise = run()
      .catch((e) => {
        if (alive.current) {
          setStatus("error");
          setError((e as Error).message);
        }
        throw e;
      })
      .finally(() => {
        inFlight.current = null;
      });
    inFlight.current = promise;
    return promise;
  }, [onUpdate]);
  const flushRef = useRef(flush);
  flushRef.current = flush;
  const patch = useCallback((changes: Partial<Notebook>) => {
    draft.current = { ...draft.current, ...changes };
    setDoc(draft.current);
    editVersion.current++;
    setStatus("editing");
    try { saveDraft(localStorage, draft.current, saved.current.revision); }
    catch {setError("This browser cannot retain an offline draft. Keep this tab open until saving succeeds.");}
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(
      () => void flushRef.current().catch(() => {}),
      900,
    );
  }, []);
  const patchPage = useCallback(
    (changes: Partial<Page>) => {
      patch({
        payload: {
          ...draft.current.payload,
          pages: draft.current.payload.pages.map((p) =>
            p.id === activeRef.current ? { ...p, ...changes } : p,
          ),
        },
      });
    },
    [patch],
  );
  useEffect(() => {
    const recovery=readDraft(localStorage,initialDoc);
    if(recovery){
      draft.current=recovery.document; setDoc(recovery.document);editVersion.current=1;
      if(recovery.baseRevision!==initialDoc.revision){conflicted.current=true;setStatus("error");setError("A recovered draft and the cloud version both changed. Save a conflict copy to retain both.");}
      else{setStatus("editing");void flushRef.current().catch(()=>{});}
    }
    const pull=async()=>{
      if(document.hidden||inFlight.current)return;
      const {data,error}=await cloud.from("noty_web_documents").select("*").eq("user_id",initialDoc.user_id).eq("id",initialDoc.id).maybeSingle();
      if(!alive.current||error)return;
      if(!data){conflicted.current=true;setStatus("error");setError("This notebook was permanently deleted on another device. Your draft is preserved.");return;}
      if(data.revision===saved.current.revision){
        if(editVersion.current>persistedVersion.current&&!conflicted.current)void flushRef.current().catch(()=>{});
        return;
      }
      if(editVersion.current>persistedVersion.current){conflicted.current=true;setStatus("error");setError("Another device changed this notebook. Save a conflict copy or reload after downloading your draft.");return;}
      const fresh=await hydrateNotebook(data);if(!alive.current||editVersion.current>persistedVersion.current||inFlight.current)return;
      saved.current=fresh;draft.current=fresh;setDoc(fresh);onUpdate(fresh);
      const active=fresh.payload.pages.find(p=>p.id===activeRef.current)||fresh.payload.pages.find(p=>!p.isCover)||fresh.payload.pages[0];
      if(active){activeRef.current=active.id;setActiveId(active.id);}
      if(fresh.trashed_at){conflicted.current=true;setStatus("error");setError("This notebook is in Trash on another device. Return to the library to restore it.");}
    };
    const interval=setInterval(()=>void pull(),10000);window.addEventListener("focus",pull);window.addEventListener("online",pull);
    return()=>{clearInterval(interval);window.removeEventListener("focus",pull);window.removeEventListener("online",pull);};
  }, []);
  useEffect(() => {
    alive.current = true;
    const handler = (e: BeforeUnloadEvent) => {
      if (editVersion.current > persistedVersion.current || inFlight.current) {
        e.preventDefault();
        e.returnValue = "";
      }
    };
    const key = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key === "s") {
        e.preventDefault();
        void flushRef.current().catch(() => {});
      }
    };
    window.addEventListener("beforeunload", handler);
    window.addEventListener("keydown", key);
    return () => {
      alive.current = false;
      if (timer.current) clearTimeout(timer.current);
      window.removeEventListener("beforeunload", handler);
      window.removeEventListener("keydown", key);
    };
  }, []);
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(""), 5000);
    return () => clearTimeout(t);
  }, [toast]);
  const pages = doc.payload.pages.filter((p) => !p.isCover);
  const page = doc.payload.pages.find((p) => p.id === activeId);
  const paperHex = /^[0-9a-f]{6}$/i.test(page?.paperColorHex || "") ? page!.paperColorHex! : "FFFFFF";
  const paperRGB = [0, 2, 4].map(offset => parseInt(paperHex.slice(offset, offset + 2), 16));
  const darkPaper = .2126 * paperRGB[0] + .7152 * paperRGB[1] + .0722 * paperRGB[2] < 128;
  const pageIndex = pages.findIndex((p) => p.id === activeId);
  const folder = folders.find((f) => f.id === doc.folder_id);
  const wordCount = (page ? pageText(page) : "")
    .trim()
    .split(/\s+/)
    .filter(Boolean).length;

  async function attachImage(file: File) {
    if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) {
      flash("Choose a PNG, JPG or WebP image.");
      return;
    }
    const targetID = activeRef.current;
    setUploading(true);
    try {
      const image = await createImageBitmap(file);
      const width = Math.min(image.width, 564);
      const height = (width * image.height) / image.width;
      image.close();
      const ext =
        file.type === "image/jpeg"
          ? "jpg"
          : file.type === "image/webp"
            ? "webp"
            : "png";
      const name = `${crypto.randomUUID()}.${ext}`;
      const path = `Images/${targetID.toUpperCase()}/${name}`;
      await uploadAsset(draft.current.user_id, draft.current.id, path, file);
      patch({
        payload: {
          ...draft.current.payload,
          assets: [...(draft.current.payload.assets || []), path],
          pages: draft.current.payload.pages.map((p) =>
            p.id === targetID
              ? {
                  ...p,
                  images: [
                    ...p.images,
                    {
                      id: crypto.randomUUID(),
                      fileName: name,
                      x: 24,
                      y: 120,
                      width,
                      height,
                      rotationDegrees: 0,
                    },
                  ],
                }
              : p,
          ),
        },
      });
      flash("Image added");
    } catch (e) {
      flash((e as Error).message);
    } finally {
      setUploading(false);
    }
  }
  function changePage(id: string) {
    if (window.matchMedia("(max-width: 760px)").matches) setShowPages(false);
    activeRef.current = id;
    setActiveId(id);
    const next = draft.current.payload.pages.find((p) => p.id === id);

  }
  function addPage() {
    const next = {...newPage(),template:page?.template||"blank",sizePreset:page?.sizePreset||"letter",orientation:page?.orientation||"portrait",paperColorHex:page?.paperColorHex||"FFFFFF"};
    patch({
      payload: {
        ...draft.current.payload,
        pages: [...draft.current.payload.pages, next],
      },
    });
    changePage(next.id);
    setSource(false);
  }
  async function duplicatePage() {
    if (!page) return;
    const copy = {
      ...page,
      id: crypto.randomUUID(),
      textBoxes: page.textBoxes.map((t) => ({ ...t, id: crypto.randomUUID() })),
      images: page.images.map((i) => ({ ...i, id: crypto.randomUUID() })),
    };
    setUploading(true);
    try {
      const additions:string[]=[];
      for(const name of draft.current.payload.assets||[]) {
        const lower=name.toLowerCase();
        if(!lower.includes(page.id.toLowerCase()) || lower.endsWith(".drawing"))continue;
        const next=name.replace(new RegExp(page.id,"ig"),copy.id.toUpperCase());
        const url=await assetURL(doc,name);const response=await fetch(url);
        if(!response.ok)throw new Error("Could not copy page assets.");
        await uploadAsset(doc.user_id,doc.id,next,await response.blob());additions.push(next);URL.revokeObjectURL(url);
      }
      if((draft.current.payload.assets||[]).some(n=>n.toLowerCase().endsWith(`${page.id.toLowerCase()}.drawing`))) {
        const name=draft.current.payload.assets!.find(n=>n.toLowerCase().endsWith(`${page.id.toLowerCase()}.drawing`))!;
        const url=await assetURL(doc,name);const response=await fetch(url);if(!response.ok)throw new Error("Could not copy drawing.");
        const next=`Drawings/${copy.id.toUpperCase()}.drawing`;await uploadAsset(doc.user_id,doc.id,next,await response.blob());additions.push(next);URL.revokeObjectURL(url);
      }
      draft.current={...draft.current,payload:{...draft.current.payload,assets:[...(draft.current.payload.assets||[]),...additions]}};
    }catch(e){flash((e as Error).message);return;}finally{setUploading(false);}
    const index = draft.current.payload.pages.findIndex(p=>p.id===page.id);
    const list = [...draft.current.payload.pages];
    list.splice(index + 1, 0, copy);
    patch({ payload: { ...draft.current.payload, pages: list } });
    changePage(copy.id);
  }
  function deletePage() {
    if (pages.length <= 1) return;
    const remaining = draft.current.payload.pages.filter(
      (p) => p.id !== activeId,
    );
    const next = pages[Math.max(0, pageIndex - 1)];
    patch({ payload: { ...draft.current.payload, pages: remaining } });
    changePage(next.id);
    setPageDelete(false);
  }
  async function leave() {
    setLeaving(true);
    try {
      if (uploading) {
        flash("Wait for the image upload to finish.");
        return;
      }
      await flushRef.current();
      onClose();
    } catch {
    } finally {
      setLeaving(false);
    }
  }
  async function exportBackup() {
    setExporting(true);
    try {
      const current = draft.current;
      const native = {
        ...current.payload,
        id: current.id,
        title: current.title,
        kind: current.kind,
        folderID: current.folder_id,
        pages: current.payload.pages,
        createdAt: current.created_at,
        updatedAt: current.updated_at,
      };
      const files: Record<string, Uint8Array> = {
        "manifest.json": strToU8(
          JSON.stringify(
            {
              version: 1,
              folders: folders.map((f) => ({
                id: f.id,
                name: f.name,
                parentID: f.parent_id,
              })),
              documents: [native],
            },
            null,
            2,
          ),
        ),
      };
      for (const name of current.payload.assets || []) {
        const url = await assetURL(current, name);
        try {
          files[`Assets/${current.id}/${name}`] = new Uint8Array(
            await (await fetch(url)).arrayBuffer(),
          );
        } finally {
          URL.revokeObjectURL(url);
        }
      }
      const zip = zipSync(files);
      downloadBlob(
        new Blob([zip as Uint8Array<ArrayBuffer>], { type: "application/zip" }),
        `${current.title}.noty.zip`,
      );
      lastExportVersion.current = editVersion.current;
      flash("Notebook backup downloaded");
    } catch (e) {
      flash((e as Error).message);
    } finally {
      setExporting(false);
    }
  }
  function exportText() {
    const text = `# ${draft.current.title}\n\n${draft.current.payload.pages
      .filter((p) => !p.isCover)
      .map((p) => pageText(p))
      .join("\n\n---\n\n")}`;
    downloadBlob(
      new Blob([text], { type: "text/markdown" }),
      `${doc.title}.md`,
    );
    flash("Notes downloaded");
  }
  function printNotes() {
    const iframe = document.createElement("iframe");
    iframe.style.cssText = "position:fixed;width:0;height:0;border:0;";
    document.body.appendChild(iframe);
    const documentToPrint = iframe.contentDocument;
    if (!documentToPrint) return;
    documentToPrint.open();
    documentToPrint.write(
      `<!doctype html><html><head><title>${escapeHTML(doc.title)}</title><style>@page{size:A4;margin:20mm}body{font-family:Arial,sans-serif;color:#252936;font-size:12pt;line-height:1.7}section{break-after:page}section:last-child{break-after:auto}h1{font-size:26pt;margin-bottom:24pt}h2{font-size:20pt}blockquote{border-left:2pt solid #789;padding-left:15pt}pre{white-space:pre-wrap}img{max-width:100%}</style></head><body>${draft.current.payload.pages
        .filter((p) => !p.isCover)
        .map(
          (p, i) =>
            `<section>${i === 0 ? `<h1>${escapeHTML(doc.title)}</h1>` : ""}${htmlForPage(p)}</section>`,
        )
        .join("")}</body></html>`,
    );
    documentToPrint.close();
    const target = iframe.contentWindow;
    target?.addEventListener("afterprint", () => iframe.remove(), {
      once: true,
    });
    setTimeout(() => {
      target?.focus();
      target?.print();
    }, 150);
    setTimeout(() => iframe.remove(), 60000);
  }
  async function saveConflictCopy(){
    setExporting(true);
    try {
      const id=crypto.randomUUID(), current=draft.current;
      for(const name of current.payload.assets||[]){const url=await assetURL(current,name);const response=await fetch(url);if(!response.ok)throw new Error("Could not copy asset.");await uploadAsset(current.user_id,id,name,await response.blob());URL.revokeObjectURL(url);}
      const {error}=await cloud.from("noty_web_documents").insert({id,user_id:current.user_id,title:current.title.slice(0,275)+" (conflict copy)",kind:current.kind,folder_id:current.folder_id,payload:{...current.payload,assetManifest:uploadedManifest(current.user_id,id)},starred:current.starred});
      if(error)throw error;localStorage.removeItem(draftKey(current));persistedVersion.current=editVersion.current;notify("Your draft was saved as a separate notebook.");onClose();
    }catch(e){flash((e as Error).message);}finally{setExporting(false);}
  }
  async function reloadAfterConflict() {
    if (lastExportVersion.current !== editVersion.current) {
      setConflictReload(true);
      return;
    }
    const { data, error } = await cloud
      .from("noty_web_documents")
      .select("*")
      .eq("id", doc.id)
      .eq("user_id", doc.user_id)
      .single();
    if (error) {
      flash(error.message);
      return;
    }
    const fresh=await hydrateNotebook(data);
    conflicted.current=!!fresh.trashed_at;
    saved.current = fresh;
    draft.current = fresh;
    setDoc(fresh);
    localStorage.removeItem(draftKey(fresh));
    persistedVersion.current = editVersion.current;
    setError("");
    setStatus("saved");
    changePage(
      data.payload.pages.find((p: Page) => !p.isCover)?.id ||
        data.payload.pages[0]?.id,
    );
    onUpdate(data);
  }
  async function attachFile(file:File){
    setUploading(true);
    try{
      const name=attachmentAssetPath(file.name,file.type.startsWith("audio/"),crypto.randomUUID());
      await uploadAsset(doc.user_id,doc.id,name,file);
      const payload:Payload={...draft.current.payload,assets:[...(draft.current.payload.assets||[]),name]};
      if(file.type.startsWith("audio/"))payload.audioClips=[...((payload.audioClips as any[])||[]),{id:crypto.randomUUID(),title:file.name,fileName:name,duration:0,createdAt:Date.now(),pageID:activeRef.current}];
      patch({payload});flash("File attached");
    }catch(e){flash((e as Error).message);}finally{setUploading(false);}
  }
  const menu = [
    {label:"Attach a file or audio",icon:<Upload size={16}/>,action:()=>attachmentInput.current?.click()},
    {
      label: "Download notes (.md)",
      icon: <Download size={16} />,
      action: exportText,
    },
    {
      label: "Print / save notes as PDF",
      icon: <Printer size={16} />,
      action: printNotes,
    },
    {
      label: "Download notebook backup",
      icon: <Download size={16} />,
      action: () => void exportBackup(),
    },
    {
      label: "Paper style",
      icon: <FileText size={16} />,
      action: () => setPaperSettings(true),
    },
    {
      label: "Study cards",
      icon: <Layers size={16} />,
      action: () => setStudy(true),
    },
  ];
  return (
    <div className={`editor-workspace ${showPages ? "pages-open" : ""}`}>
      <input type="file" hidden ref={attachmentInput} onChange={e=>{if(e.target.files?.[0])void attachFile(e.target.files[0]);e.target.value="";}}/>
      <header className="editor-header">
        <button
          className="editor-back"
          onClick={() => void leave()}
          disabled={leaving}
        >
          <ArrowLeft size={17} />
          <span className="editor-back-label">{leaving ? "Saving…" : "Back"}</span>
        </button>
        <span className="editor-header-divider" />
        <button className="icon-button page-sidebar-toggle" aria-label={showPages ? "Hide pages" : "Show pages"} aria-pressed={showPages} onClick={() => setShowPages(!showPages)}><PanelLeft size={18} /></button>
        <div className="editor-title">
          <span>{doc.title}</span>
          <button
            className="icon-button"
            aria-label={doc.starred ? "Remove favorite" : "Add favorite"}
            onClick={() => patch({ starred: !doc.starred })}
          >
            <Star
              size={16}
              fill={doc.starred ? "currentColor" : "none"}
              color="currentColor"
            />
          </button>
        </div>
        <div className={`save-status ${error ? "error" : ""}`} role="status">
          {status === "saving" ? (
            <Loader2 size={14} className="spin" />
          ) : status === "saved" ? (
            <Cloud size={15} />
          ) : error ? (
            <X size={14} />
          ) : (
            <span>•</span>
          )}
          <span>
            {status === "saved"
              ? "Saved to cloud"
              : status === "saving"
                ? "Saving…"
                : error
                  ? "Not saved"
                  : "Editing…"}
          </span>
        </div>
        <div className="editor-actions">
          <DropMenu items={menu}>
            <button
              className="icon-button"
              disabled={exporting}
              aria-label="Notebook options"
            >
              {exporting ? (
                <Loader2 size={18} className="spin" />
              ) : (
                <MoreHorizontal size={21} />
              )}
            </button>
          </DropMenu>
        </div>
      </header>
      <div className="editor-body">
        {showPages && <button className="page-drawer-backdrop" aria-label="Close pages" onClick={() => setShowPages(false)} />}
        {showPages && <aside className="pages-sidebar">
          <div className="pages-header">
            <span>PAGES / {pages.length.toString().padStart(2, "0")}</span>
            <button
              className="icon-button"
              aria-label="Add page"
              onClick={addPage}
            >
              <Plus size={17} />
            </button>
          </div>
          {pages.map((p, i) => (
            <button
              className={`page-thumb ${activeId === p.id ? "active" : ""}`}
              key={p.id}
              onClick={() => changePage(p.id)}
            >
              <div className="page-mini-paper">
                <strong>{i === 0 ? doc.title : `Page ${i + 1}`}</strong>
                {pageText(p).slice(0, 260) || "A fresh page"}
              </div>
              <div className="page-thumb-label">
                <span>Page {i + 1}</span>
                {p.isBookmarked && <Bookmark size={11} fill="currentColor" />}
              </div>
            </button>
          ))}
          <button className="button text-button full small" onClick={addPage}>
            <Plus size={14} />
            Add page
          </button>
        </aside>}
        <main className="editor-main">
          {error && (
            <div className="editor-error" role="alert">
              <strong>Your draft is still here.</strong>
              <button className="button secondary small" onClick={()=>void saveConflictCopy()}>Save a conflict copy</button>
              <p>{error}</p>
              <button
                className="button secondary small"
                onClick={() => void flushRef.current().catch(() => {})}
              >
                <RefreshCw size={14} />
                Retry saving
              </button>
              <button className="button secondary small" onClick={exportText}>
                <Download size={14} />
                Download draft
              </button>
              <button
                className="button secondary small"
                onClick={() => void reloadAfterConflict()}
              >
                Reload saved notebook
              </button>
            </div>
          )}
          {doc.payload.sourcePDF && (
            <div
              className="document-tabs"
              role="tablist"
              aria-label="Document view"
            >
              <button
                role="tab"
                aria-selected={source}
                className={source ? "active" : ""}
                onClick={() => setSource(true)}
              >
                Original PDF
              </button>
              <button
                role="tab"
                aria-selected={!source}
                className={!source ? "active" : ""}
                onClick={() => setSource(false)}
              >
                Typed notes
              </button>
            </div>
          )}
          {source && doc.payload.sourcePDF ? (
            <Suspense
              fallback={
                <div className="pdf-loading">
                  <Loader2 className="spin" size={22} />
                  Opening document…
                </div>
              }
            >
              <PDFPanel doc={doc} />
            </Suspense>
          ) : (
            <>
              <div className="editor-mobile-pages">
                <button
                  className="icon-button"
                  aria-label="Previous page"
                  disabled={pageIndex <= 0}
                  onClick={() => changePage(pages[pageIndex - 1].id)}
                >
                  <ChevronLeft size={17} />
                </button>
                <select
                  aria-label="Select page"
                  value={activeId}
                  onChange={(e) => changePage(e.target.value)}
                >
                  {pages.map((p, i) => (
                    <option key={p.id} value={p.id}>
                      Page {i + 1} of {pages.length}
                    </option>
                  ))}
                </select>
                <button
                  className="icon-button"
                  aria-label="Next page"
                  disabled={pageIndex >= pages.length - 1}
                  onClick={() => changePage(pages[pageIndex + 1].id)}
                >
                  <ChevronRight size={17} />
                </button>
                <button
                  className="icon-button"
                  aria-label="Add page"
                  onClick={addPage}
                >
                  <Plus size={17} />
                </button>
              </div>
              <article
                className={`paper ${darkPaper ? "dark-paper" : ""} ${["ruled", "narrowRuled"].includes(page?.template || "") ? "ruled" : ["grid", "smallGrid"].includes(page?.template || "") ? "grid" : page?.template === "dots" ? "dots" : ""}`}
                style={{
                  backgroundColor: `#${paperHex}`,
                }}
              >
                <div className="paper-meta">
                  <span>{folder?.name || "Personal notebook"}</span>
                  <div
                    style={{ display: "flex", gap: 8, alignItems: "center" }}
                  >
                    <span>
                      {(pageIndex + 1).toString().padStart(2, "0")} /{" "}
                      {pages.length.toString().padStart(2, "0")}
                    </span>
                    <button
                      className="icon-button"
                      aria-label={
                        page?.isBookmarked
                          ? "Remove page bookmark"
                          : "Bookmark page"
                      }
                      onClick={() =>
                        patchPage({ isBookmarked: !page?.isBookmarked })
                      }
                    >
                      <Bookmark
                        size={15}
                        fill={page?.isBookmarked ? "currentColor" : "none"}
                        color="currentColor"
                      />
                    </button>
                    <DropMenu
                      items={[
                        {
                          label: "Move page earlier",
                          icon: <ChevronLeft size={15}/>,
                          action: () => patch({payload:{...draft.current.payload,pages:movePage(draft.current.payload.pages,activeId,-1)}}),
                        },
                        {
                          label: "Move page later",
                          icon: <ChevronRight size={15}/>,
                          action: () => patch({payload:{...draft.current.payload,pages:movePage(draft.current.payload.pages,activeId,1)}}),
                        },
                        {
                          label: "Duplicate page",
                          icon: <Copy size={15} />,
                          action: () => void duplicatePage(),
                        },
                        ...(pages.length > 1
                          ? [
                              {
                                label: "Delete page",
                                icon: <Trash2 size={15} />,
                                danger: true,
                                action: () => setPageDelete(true),
                              },
                            ]
                          : []),
                      ]}
                    >
                      <button className="icon-button" aria-label="Page options">
                        <MoreHorizontal size={16} />
                      </button>
                    </DropMenu>
                  </div>
                </div>
                <input className="paper-title" aria-label="Notebook title" maxLength={300} value={doc.title} onChange={e=>patch({title:e.target.value||"Untitled"})}/>
                {page&&<NativePage doc={doc} page={page} onChange={patchPage} onUpload={()=>imageInput.current?.click()}/>}
                <input type="file" hidden ref={imageInput} accept="image/png,image/jpeg,image/webp" onChange={e=>{if(e.target.files?.[0])void attachImage(e.target.files[0]);e.target.value="";}}/>
                {(doc.payload.assets||[]).filter(name=>!name.toLowerCase().startsWith("images/")&&!name.toLowerCase().startsWith("drawings/")&&!name.toLowerCase().startsWith("inkpreviews/")&&name!==doc.payload.sourcePDF).map(name=><button key={name} className="button secondary small" onClick={()=>void assetURL(doc,name).then(async url=>{const response=await fetch(url);if(!response.ok)throw new Error("Download failed.");downloadBlob(await response.blob(),name.split("/").pop()||"attachment");URL.revokeObjectURL(url);}).catch(e=>flash(e.message))}>Download {name.split("/").pop()}</button>)}
                {Array.isArray(doc.payload.audioClips)&&doc.payload.audioClips.map((clip:any)=><AudioAsset key={clip.id} doc={doc} clip={clip}/>)}
              </article>
              <div className="editor-footer">
                <span>
                  {wordCount} word{wordCount === 1 ? "" : "s"} · Page{" "}
                  {pageIndex + 1}
                </span>
                <span>{status === "saved" ? "Saved" : status === "saving" ? "Saving…" : "Unsaved changes"}</span>
              </div>
            </>
          )}
        </main>
      </div>
      <Modal
        open={paperSettings}
        onOpenChange={setPaperSettings}
        title="Paper design"
        description="Choose a background for this page."
      >
        <div className="form">
          <label>
            Paper style
            <select
              value={page?.template || "blank"}
              onChange={(e) => patchPage({ template: e.target.value })}
            >
              <option value="blank">Blank</option>
              <option value="ruled">Ruled</option>
              <option value="grid">Grid</option>
              <option value="dots">Dots</option>
            </select>
          </label>
          <label>Paper color<select value={page?.paperColorHex || "FFFFFF"} onChange={e => patchPage({ paperColorHex: e.target.value })}><option value="FFFFFF">White</option><option value="FFFDF5">Cream</option><option value="FFF3B0">Yellow</option><option value="EAF4FF">Blue</option><option value="ECF7EE">Green</option><option value="FCECEF">Pink</option><option value="292927">Dark</option></select></label>
          <button
            className="button primary full"
            onClick={() => setPaperSettings(false)}
          >
            Done
          </button>
        </div>
      </Modal>
      <Modal
        open={study}
        onOpenChange={setStudy}
        title="A little practice goes a long way."
        description="Review your cards or add a new one."
        wide
      >
        {doc.payload.studyCards?.length ? (
          <>
            <button
              className="study-card full"
              onClick={() => setFlipped(!flipped)}
            >
              <small>{flipped ? "Answer" : "Question"} · tap to flip</small>
              <p>
                {flipped
                  ? doc.payload.studyCards[
                      studyIndex % doc.payload.studyCards.length
                    ].answer
                  : doc.payload.studyCards[
                      studyIndex % doc.payload.studyCards.length
                    ].question}
              </p>
            </button>
            <div className="study-buttons">
              <button
                className="icon-button"
                aria-label="Previous study card"
                onClick={() => {
                  setStudyIndex(
                    (i) =>
                      (i - 1 + doc.payload.studyCards!.length) %
                      doc.payload.studyCards!.length,
                  );
                  setFlipped(false);
                }}
              >
                <ChevronLeft size={20} />
              </button>
              <span style={{ fontSize: 12, color: "#909bb0" }}>
                {(studyIndex % doc.payload.studyCards.length) + 1} /{" "}
                {doc.payload.studyCards.length}
              </span>
              <button
                className="icon-button"
                aria-label="Delete current study card"
                onClick={() => {
                  patch({
                    payload: {
                      ...draft.current.payload,
                      studyCards: draft.current.payload.studyCards?.filter(
                        (_, i) =>
                          i !== studyIndex % doc.payload.studyCards!.length,
                      ),
                    },
                  });
                  setStudyIndex(0);
                  setFlipped(false);
                }}
              >
                <Trash2 size={16} />
              </button>
              <button
                className="icon-button"
                aria-label="Next study card"
                onClick={() => {
                  setStudyIndex(
                    (i) => (i + 1) % doc.payload.studyCards!.length,
                  );
                  setFlipped(false);
                }}
              >
                <ChevronRight size={20} />
              </button>
            </div>
          </>
        ) : (
          <p className="import-copy">
            No study cards yet. Add a question and answer below.
          </p>
        )}
        <form
          className="form study-form"
          onSubmit={(e) => {
            e.preventDefault();
            patch({
              payload: {
                ...draft.current.payload,
                studyCards: [
                  ...(draft.current.payload.studyCards || []),
                  {
                    id: crypto.randomUUID(),
                    question: question.trim(),
                    answer: answer.trim(),
                  },
                ],
              },
            });
            setQuestion("");
            setAnswer("");
          }}
        >
          <label>
            Question
            <textarea
              required
              value={question}
              onChange={(e) => setQuestion(e.target.value)}
              placeholder="What do you want to remember?"
            />
          </label>
          <label>
            Answer
            <textarea
              required
              value={answer}
              onChange={(e) => setAnswer(e.target.value)}
              placeholder="The answer, in your words."
            />
          </label>
          <button
            className="button primary full"
            disabled={!question.trim() || !answer.trim()}
          >
            <Plus size={17} />
            Add card
          </button>
        </form>
      </Modal>
      <Alert.Root open={pageDelete} onOpenChange={setPageDelete}>
        <Alert.Portal>
          <Alert.Overlay className="modal-overlay" />
          <Alert.Content className="modal">
            <Alert.Title className="modal-title">Delete this page?</Alert.Title>
            <Alert.Description className="modal-description">
              The text and images on this page will be removed from your
              notebook.
            </Alert.Description>
            <div className="dialog-actions">
              <Alert.Cancel className="button secondary">
                Keep page
              </Alert.Cancel>
              <Alert.Action
                className="button danger-button"
                onClick={deletePage}
              >
                Delete page
              </Alert.Action>
            </div>
          </Alert.Content>
        </Alert.Portal>
      </Alert.Root>
      <Modal
        open={conflictReload}
        onOpenChange={setConflictReload}
        title="Keep your draft first."
        description="Download your current draft before reloading the cloud version."
      >
        <button
          className="button primary full"
          onClick={() => {
            void exportBackup().then(() => setConflictReload(false));
          }}
        >
          Download draft
        </button>
      </Modal>
      {toast && (
        <div className="editor-note-toast" role="status">
          {toast}
        </div>
      )}
    </div>
  );
}

function AudioAsset({doc,clip}:{doc:Notebook;clip:any}){const[url,setURL]=useState("");useEffect(()=>{let active=true;let value="";void assetURL(doc,clip.fileName).then(u=>{value=u;if(active)setURL(u);}).catch(()=>{});return()=>{active=false;URL.revokeObjectURL(value);};},[doc.id,doc.revision,clip.fileName]);return <div className="audio-asset"><span>{clip.title}</span>{url?<audio controls src={url}/>:<span>Audio not uploaded yet</span>}</div>;}
