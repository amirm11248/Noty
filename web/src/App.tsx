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
  BookOpen,
  Home,
  Plus,
  Search,
  Clock,
  Star,
  Folder as FolderIcon,
  Trash2,
  Settings,
  ChevronDown,
  ChevronRight,
  MoreHorizontal,
  LayoutGrid,
  List,
  Upload,
  X,
  Menu as MenuIcon,
  FileText,
  ArrowLeft,
  Check,
  Loader2,
  Download,
  RefreshCw,
  NotebookPen,
  FolderPlus,
  Move,
  HelpCircle,
} from "./icons";
import {
  loadLibrary,
  createNotebook,
  createFolder,
  saveNotebook,
  getNotebook,
  deleteNotebook,
} from "./local-library.mjs";
import type { Notebook, Folder } from "./types";
import { palette, notebookText, newPage } from "./types";
import NotebookCover from "./NotebookCover";
import { useWorkspaceTheme } from "./theme";
const Editor = lazy(() => import("./Editor"));
import { Modal, DropMenu } from "./ui";
const ImportLibrary = lazy(() => import("./ImportLibrary"));

const relativeDate = (date: string) => {
  const days = Math.floor((Date.now() - new Date(date).getTime()) / 86400000);
  return days <= 0
    ? "Today"
    : days === 1
      ? "Yesterday"
      : days < 7
        ? `${days} days ago`
        : new Date(date).toLocaleDateString(undefined, {
            month: "short",
            day: "numeric",
          });
};

export default function App() {
  const [appearance, setAppearance] = useWorkspaceTheme();
  const [coverStyle, setCoverStyle] = useState("gradient");
  const [designTab, setDesignTab] = useState("cover");
  const [paperTemplate, setPaperTemplate] = useState("ruled");
  const [paperColor, setPaperColor] = useState("FFFFFF");
  const [expandedFolders, setExpandedFolders] = useState<Set<string>>(new Set());
  const [sortOrder, setSortOrder] = useState(() => localStorage.getItem("noty-sort") || "modified");
  const [docs, setDocs] = useState<Notebook[]>([]);
  const [folders, setFolders] = useState<Folder[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [view, setView] = useState("all");
  const [search, setSearch] = useState("");
  const [layout, setLayout] = useState<"grid" | "list">(() =>
    localStorage.getItem("noty-layout") === "list" ? "list" : "grid",
  );
  const [sidebar, setSidebar] = useState(false);
  const [newOpen, setNewOpen] = useState(false);
  const [folderOpen, setFolderOpen] = useState(false);
  const [importOpen, setImportOpen] = useState(false);
  const [settings, setSettings] = useState(false);
  const [help, setHelp] = useState(false);
  const [selected, setSelected] = useState<Notebook | null>(null);
  const [toast, setToast] = useState("");
  const [title, setTitle] = useState("");
  const [color, setColor] = useState(palette[0]);
  const [busy, setBusy] = useState(false);
  const [formError, setFormError] = useState("");
  const [rename, setRename] = useState<Notebook | null>(null);
  const [move, setMove] = useState<Notebook | null>(null);
  const [moveFolder, setMoveFolder] = useState("");
  const [deleteDoc, setDeleteDoc] = useState<Notebook | null>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const notify = useCallback((text: string) => setToast(text), []);
  const dataRef = useRef({ docs, folders, selected });
  dataRef.current = { docs, folders, selected };
  useEffect(() => {
    const context = (
      document as Document & {
        modelContext?: {
          registerTool: (
            tool: object,
            options: { signal: AbortSignal },
          ) => void | Promise<void>;
        };
      }
    ).modelContext;
    if (!context?.registerTool) return;
    const lifecycle = new AbortController();
    const register = (tool: object) => {
      try {
        void Promise.resolve(
          context.registerTool(tool, { signal: lifecycle.signal }),
        ).catch(() => {});
      } catch {}
    };
    register({
      name: "list_notebooks",
      title: "List notebooks",
      description: "Read notebooks saved in this browser.",
      inputSchema: {
        type: "object",
        properties: {},
        additionalProperties: false,
      },
      annotations: { readOnlyHint: true, untrustedContentHint: true },
      execute: () => {
        return {
          notebooks: dataRef.current.docs
            .filter((d) => !d.trashed_at)
            .map((d) => ({
              id: d.id,
              title: d.title,
              pages: d.payload.pages.filter((p) => !p.isCover).length,
              folderId: d.folder_id,
            }))
            .slice(0, 200),
        };
      },
    });
    register({
      name: "search_notebooks",
      title: "Search notebooks",
      description:
        "Search titles and typed notes and show the results in the library.",
      inputSchema: {
        type: "object",
        properties: { query: { type: "string", maxLength: 200 } },
        required: ["query"],
        additionalProperties: false,
      },
      annotations: { readOnlyHint: false, untrustedContentHint: true },
      execute: (input: { query: string }) => {
        if (typeof input?.query !== "string" || input.query.length > 200)
          throw new Error("Enter a search query under 200 characters.");
        if (dataRef.current.selected)
          throw new Error("Return to the library first.");
        setView("search");
        setSearch(input.query);
        const q = input.query.toLowerCase();
        return {
          matches: dataRef.current.docs
            .filter(
              (d) =>
                !d.trashed_at &&
                `${d.title}\n${notebookText(d)}`.toLowerCase().includes(q),
            )
            .map((d) => ({ id: d.id, title: d.title }))
            .slice(0, 200),
        };
      },
    });
    register({
      name: "create_notebook",
      title: "Create notebook",
      description:
        "Create and open a new notebook saved in this browser.",
      inputSchema: {
        type: "object",
        properties: { title: { type: "string", minLength: 1, maxLength: 300 } },
        required: ["title"],
        additionalProperties: false,
      },
      annotations: { readOnlyHint: false, untrustedContentHint: false },
      execute: async (input: { title: string }) => {
        if (dataRef.current.selected)
          throw new Error("Return to the library first.");
        if (
          typeof input?.title !== "string" ||
          !input.title.trim() ||
          input.title.length > 300
        )
          throw new Error("Enter a notebook title from 1 to 300 characters.");
        const doc = await createNotebook(
          input.title.trim(),
          null,
          palette[0],
        );
        setDocs((prev) => [doc, ...prev]);
        setSelected(doc);
        return { id: doc.id, title: doc.title, status: "created" };
      },
    });
    return () => lifecycle.abort();
  }, []);

  const refresh = useCallback(async (quiet = false) => {
    if (!quiet) setLoading(true);
    try {
      const library = await loadLibrary();
      setDocs(library.docs); setFolders(library.folders); setLoadError("");
    } catch (error) { setLoadError((error as Error).message); }
    finally { setLoading(false); }
  }, []);
  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => {
    if (selected) return;
    const focus = () => void refresh(true);
    window.addEventListener("focus", focus);
    return () => window.removeEventListener("focus", focus);
  }, [selected, refresh]);
  useEffect(() => {
    if (!toast) return;
    const id = setTimeout(() => setToast(""), 5000);
    return () => clearTimeout(id);
  }, [toast]);
  useEffect(() => {
    const listener = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault();
        if (!selected) {
          setView("search");
          setSidebar(false);
          setTimeout(() => searchRef.current?.focus(), 0);
        }
      }
      if ((e.metaKey || e.ctrlKey) && e.key === "n" && !selected) {
        e.preventDefault();
        setTitle(""); setFormError(""); setNewOpen(true);
      }
    };
    window.addEventListener("keydown", listener);
    return () => window.removeEventListener("keydown", listener);
  }, [selected]);
  useEffect(() => { if (view === "search") searchRef.current?.focus(); }, [view]);
  const updateDoc = useCallback((doc: Notebook) => {
    setDocs((prev) =>
      prev.some((d) => d.id === doc.id)
        ? prev.map((d) => (d.id === doc.id ? doc : d))
        : [doc, ...prev],
    );
  }, []);
  async function openNotebook(doc:Notebook){
    try{const fresh=await getNotebook(doc.id);if(fresh)setSelected(fresh);else notify("This notebook was removed from the local library.");}
    catch(e){notify((e as Error).message);}
  }
  async function mutate(doc: Notebook, changes: Partial<Notebook>) {
    try {
      const saved = await saveNotebook(doc, changes);
      updateDoc(saved);
      return saved;
    } catch (e) {
      notify((e as Error).message);
      return null;
    }
  }
  const currentFolder = folders.find((f) => f.id === view);
  const viewTitle =
    view === "all"
      ? "Home"
      : view === "search"
        ? "Search"
        : view === "recent"
        ? "Recents"
        : view === "starred"
          ? "Favorites"
          : view === "trash"
            ? "Trash"
            : currentFolder?.name || "Home";
  const activeDocs = docs.filter((d) => !d.trashed_at);
  const visible = docs
    .filter((d) => (view === "trash" ? !!d.trashed_at : !d.trashed_at))
    .filter((d) =>
      view === "starred"
        ? d.starred
        : currentFolder
          ? d.folder_id === view
          : view === "all" && !search ? !d.folder_id : true,
    )
    .filter(
      (d) =>
        !search ||
        `${d.title}\n${notebookText(d)}`
          .toLowerCase()
          .includes(search.toLowerCase()),
    )
    .sort(
      (a, b) => sortOrder === "title"
        ? a.title.localeCompare(b.title)
        : new Date(sortOrder === "created" ? b.created_at : b.updated_at).getTime()
          - new Date(sortOrder === "created" ? a.created_at : a.updated_at).getTime(),
    );
  const childFolders =
    view === "all"
      ? folders.filter((f) => !f.parent_id)
      : currentFolder
        ? folders.filter((f) => f.parent_id === view)
        : [];
  const openNew = () =>
    {
      setTitle("");
      setFormError("");
      setDesignTab("cover");
      setNewOpen(true);
    };
  async function create(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setFormError("");
    try {
      const doc = await createNotebook(
        title.trim(),
        currentFolder?.id || null,
        color,
        "note",
        {
          pages: [{ ...newPage(), template: paperTemplate, paperColorHex: paperColor, sizePreset: "a4" }],
          cover: { colorHex: color.replace("#", ""), style: coverStyle },
        },
      );
      updateDoc(doc);
      setNewOpen(false);
      setSelected(doc);
    } catch (e) {
      setFormError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  async function addFolder(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setFormError("");
    try {
      const folder = await createFolder(
        title.trim(),
        currentFolder?.id || null,
        color,
      );
      setFolders((prev) => [...prev, folder]);
      setFolderOpen(false);
      notify("Folder created");
    } catch (e) {
      setFormError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  async function permanentDelete(doc: Notebook) {
    setBusy(true);
    try {
      await deleteNotebook(doc);
      setDocs((prev) => prev.filter((d) => d.id !== doc.id));
      setDeleteDoc(null);
      notify("Notebook permanently deleted");
    } catch (e) {
      notify((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  const go = (v: string) => {
    setView(v);
    setSearch("");
    setSidebar(false);
  };
  const folderTrail: Folder[] = [];
  let ancestor = currentFolder;
  const seen = new Set<string>();
  while (ancestor && !seen.has(ancestor.id)) {
    seen.add(ancestor.id);
    folderTrail.unshift(ancestor);
    ancestor = folders.find((f) => f.id === ancestor?.parent_id);
  }
  function documentMenu(doc: Notebook) {
    return doc.trashed_at
      ? [
          {
            label: "Restore notebook",
            icon: <RefreshCw size={16} />,
            action: () => void mutate(doc, { trashed_at: null }),
          },
          {
            label: "Delete permanently",
            icon: <Trash2 size={16} />,
            danger: true,
            action: () => setDeleteDoc(doc),
          },
        ]
      : [
          {
            label: doc.starred ? "Remove from favorites" : "Add to favorites",
            icon: <Star size={16} />,
            action: () => void mutate(doc, { starred: !doc.starred }),
          },
          {
            label: "Rename",
            icon: <NotebookPen size={16} />,
            action: () => {
              setRename(doc);
              setTitle(doc.title);
              setFormError("");
            },
          },
          {
            label: "Move to folder",
            icon: <Move size={16} />,
            action: () => {
              setMove(doc);
              setMoveFolder(doc.folder_id || "");
              setFormError("");
            },
          },
          {
            label: "Move to trash",
            icon: <Trash2 size={16} />,
            danger: true,
            action: () =>
              void mutate(doc, { trashed_at: new Date().toISOString() }),
          },
        ];
  }
  function folderNavigation() {
    const visited = new Set<string>();
    const rows: React.ReactNode[] = [];
    const walk = (parentId: string | null, depth: number) => {
      folders.filter(f => f.parent_id === parentId || (!parentId && !folders.some(p => p.id === f.parent_id)))
        .sort((a, b) => a.name.localeCompare(b.name)).forEach(folder => {
          if (visited.has(folder.id)) return;
          visited.add(folder.id);
          const hasChildren = folders.some(f => f.parent_id === folder.id) || activeDocs.some(d => d.folder_id === folder.id);
          const expanded = expandedFolders.has(folder.id);
          rows.push(<div className="folder-nav-row" key={folder.id} style={{ paddingLeft: Math.min(depth, 5) * 12 }}>
            <button className={`folder-chevron ${hasChildren ? "" : "no-children"}`} aria-label={`${expanded ? "Collapse" : "Expand"} ${folder.name}`} aria-expanded={expanded} disabled={!hasChildren} onClick={() => setExpandedFolders(prev => { const next = new Set(prev); if (next.has(folder.id)) next.delete(folder.id); else next.add(folder.id); return next; })}>{expanded ? <ChevronDown size={13} /> : <ChevronRight size={13} />}</button>
            <button className={`nav-item ${view === folder.id ? "active" : ""}`} aria-current={view === folder.id ? "page" : undefined} onClick={() => go(folder.id)}><FolderIcon size={18} style={{ color: folder.color }} /><span className="ellipsis">{folder.name}</span></button>
          </div>);
          if (expanded) {
            walk(folder.id, depth + 1);
            activeDocs.filter(d => d.folder_id === folder.id).forEach(doc => rows.push(<button key={doc.id} className="nav-item sidebar-notebook" style={{ paddingLeft: Math.min(depth + 1, 6) * 12 + 30 }} onClick={() => { setSelected(doc); setSidebar(false); }}><FileText size={16} /><span className="ellipsis">{doc.title}</span></button>));
          }
        });
    };
    walk(null, 0);
    return rows;
  }
  if (selected)
    return (
      <Suspense
        fallback={
          <div className="loading-state">
            <Loader2 className="spin" size={22} />
            Opening notebook…
          </div>
        }
      >
        <Editor
          key={selected.id}
          initialDoc={selected}
          folders={folders}
          onUpdate={updateDoc}
          notify={notify}
          onClose={() => {
            setSelected(null);
            void refresh(true);
          }}
        />
      </Suspense>
    );
  return (
    <div className="workspace">
      {sidebar && (
        <button
          className="sidebar-backdrop"
          aria-label="Close navigation"
          onClick={() => setSidebar(false)}
        />
      )}
      <aside className={`sidebar ${sidebar ? "sidebar-open" : ""}`} aria-label="Workspace navigation">
        <div className="sidebar-brand-row">
          <a className="brand" href="/" onClick={(e) => { e.preventDefault(); go("all"); }}>noty</a>
          <button className="icon-button sidebar-close" aria-label="Close navigation" onClick={() => setSidebar(false)}><X size={20} /></button>
        </div>
        <nav aria-label="Library">
          <button className={`nav-item ${view === "all" ? "active" : ""}`} aria-current={view === "all" ? "page" : undefined} onClick={() => go("all")}><Home size={19} />Home</button>
          <button className={`nav-item ${view === "search" ? "active" : ""}`} aria-current={view === "search" ? "page" : undefined} onClick={() => go("search")}><Search size={19} /><span>Search library & notebooks</span></button>
          <button className={`nav-item ${view === "recent" ? "active" : ""}`} aria-current={view === "recent" ? "page" : undefined} onClick={() => go("recent")}><Clock size={19} />Recents<span className="nav-count">{activeDocs.length || ""}</span></button>
          <button className={`nav-item ${view === "starred" ? "active" : ""}`} aria-current={view === "starred" ? "page" : undefined} onClick={() => go("starred")}><Star size={19} />Favorites<span className="nav-count">{activeDocs.filter(d => d.starred).length || ""}</span></button>
        </nav>
        <div className="nav-section"><span>FOLDERS</span><button className="icon-button" aria-label="New folder" onClick={() => { setTitle(""); setFormError(""); setFolderOpen(true); }}><Plus size={17} /></button></div>
        <nav aria-label="Folders" className="folder-nav">
          {folders.length ? folderNavigation() : <button className="nav-item muted" onClick={() => { setTitle(""); setFormError(""); setFolderOpen(true); }}><FolderPlus size={18} />Create your first folder</button>}
        </nav>
        <div className="sidebar-bottom">
          <button className={`nav-item ${view === "trash" ? "active" : ""}`} aria-current={view === "trash" ? "page" : undefined} onClick={() => go("trash")}><Trash2 size={18} />Trash<span className="nav-count">{docs.filter(d => d.trashed_at).length || ""}</span></button>
          <button className="nav-item" onClick={() => setSettings(true)}><Settings size={18} />Settings</button>
          <button className="profile" onClick={() => setSettings(true)}>
            <span className="avatar">N</span><span><strong>Local library</strong><small>On this device</small></span>
            <ChevronDown size={15} />
          </button>
        </div>
      </aside>
      <div className="main-shell">
        <header className="topbar">
          <div className="topbar-left">
            <button className="icon-button mobile-menu" aria-label="Open navigation" onClick={() => setSidebar(true)}><MenuIcon size={22} /></button>
            <span className="breadcrumb"><Home size={15} /><button onClick={() => go("all")}>Home</button>{view !== "all" && <><ChevronRight size={13} /><strong>{viewTitle}</strong></>}</span>
          </div>
          <div className="topbar-right">
            <button className="icon-button" aria-label="Help" onClick={() => setHelp(true)}><HelpCircle size={18} /></button>
            {view !== "trash" && <DropMenu items={[
              { label: "New notebook", icon: <BookOpen size={16} />, action: openNew },
              { label: "New folder", icon: <FolderPlus size={16} />, action: () => { setTitle(""); setFormError(""); setFolderOpen(true); } },
              { label: "Import documents or Noty library", icon: <Upload size={16} />, action: () => setImportOpen(true) },
            ]}><button className="button new-button" aria-label="New item"><Plus size={15} />New<ChevronDown size={13} /></button></DropMenu>}
          </div>
        </header>
        <main className="library">
          {folderTrail.length > 0 && <div className="folder-trail"><button onClick={() => go("all")}>Home</button>{folderTrail.map(f => <span key={f.id}><ChevronRight size={13} /><button onClick={() => go(f.id)}>{f.name}</button></span>)}</div>}
          <div className="library-heading">
            <h1>{viewTitle}</h1>
            {view !== "search" && <div className="heading-actions">
              <div className="layout-switch" role="group" aria-label="Notebook layout">
                <button aria-label="Grid view" aria-pressed={layout === "grid"} className={layout === "grid" ? "selected" : ""} onClick={() => { setLayout("grid"); localStorage.setItem("noty-layout", "grid"); }}><LayoutGrid size={17} /></button>
                <button aria-label="List view" aria-pressed={layout === "list"} className={layout === "list" ? "selected" : ""} onClick={() => { setLayout("list"); localStorage.setItem("noty-layout", "list"); }}><List size={18} /></button>
              </div>
              <select className="sort-select" aria-label="Sort notebooks" value={sortOrder} onChange={e => { setSortOrder(e.target.value); localStorage.setItem("noty-sort", e.target.value); }}><option value="modified">Last modified</option><option value="title">Title</option><option value="created">Date created</option></select>
            </div>}
          </div>
          {view === "search" && <div className="search-field library-search"><Search size={19} /><input ref={searchRef} aria-label="Search notebooks" placeholder="Search library or notebooks" value={search} onChange={e => setSearch(e.target.value)} />{search ? <button className="icon-button" aria-label="Clear search" onClick={() => setSearch("")}><X size={16} /></button> : <kbd>⌘ K</kbd>}</div>}
          {view === "all" && <div className="sync-callout">
            <Download size={21} /><div><strong>Saved in this browser</strong><p>Download notebook backups before clearing browser data or changing devices.</p></div>
          </div>}
          {childFolders.length > 0 && !search && <section className="folder-section" aria-label="Folders">
            <div className="section-heading"><h2>Folders</h2><span>{childFolders.length}</span></div>
            <div className="folder-grid">{childFolders.map(f => <button className="folder-card" key={f.id} onClick={() => go(f.id)}>
              <FolderIcon className="folder-artwork" size={76} strokeWidth={1.1} style={{ color: f.color }} />
              <strong>{f.name}</strong><small>{activeDocs.filter(d => d.folder_id === f.id).length + folders.filter(child => child.parent_id === f.id).length} items</small>
            </button>)}</div>
          </section>}
          <div className="library-controls"><div className="section-heading"><h2>{search ? "Search results" : view === "search" ? "Notebooks" : view === "trash" ? "Deleted notebooks" : view === "all" && childFolders.length ? "Unfiled notebooks" : "Notebooks"}</h2><span>{visible.length}</span></div></div>
          {loadError && <div className="error-banner" role="alert"><span>Couldn’t load your library. {loadError}</span><button className="button secondary small" onClick={() => void refresh()}><RefreshCw size={15} />Retry</button></div>}
          {loading ? <div className="loading-state"><Loader2 size={23} className="spin" /><span>Opening your library…</span></div> : visible.length ?
            <div className={`notebook-grid ${layout === "list" ? "notebook-list" : ""}`}>
              {visible.map(doc => <article className="notebook-card" key={doc.id}>
                <button className="notebook-open" onClick={() => void openNotebook(doc)}>
                  <NotebookCover title={doc.title} cover={doc.payload.cover} doc={doc} />
                  <div className="notebook-info"><strong>{doc.title}</strong><span>{relativeDate(doc.updated_at)} · {doc.payload.pages.filter(p => !p.isCover).length} {doc.payload.pages.filter(p => !p.isCover).length === 1 ? "page" : "pages"}{doc.kind === "pdf" ? " · PDF" : ""}</span></div>
                </button>
                <DropMenu items={documentMenu(doc)}><button className="icon-button notebook-menu" aria-label={`Actions for ${doc.title}`}><MoreHorizontal size={19} /></button></DropMenu>
              </article>)}
            </div>
          : <div className="empty-library">
              <BookOpen size={38} strokeWidth={1.2} />
              <h2>{search ? "No results" : view === "search" ? "Search your notebooks" : view === "trash" ? "Trash is empty" : view === "starred" ? "No favorites yet" : "No notebooks here yet"}</h2>
              <p>{search ? "Try another title or a word from your typed notes." : view === "search" ? "Find titles and typed notes across your library." : view === "trash" ? "Deleted notebooks appear here until you restore or remove them." : view === "starred" ? "Add a notebook to Favorites to find it here." : "Create a notebook or import your existing notes."}</p>
              {!search && !["trash", "starred", "search"].includes(view) && <div className="empty-actions"><button className="button primary" onClick={openNew}><Plus size={17} />New notebook</button><button className="button secondary" onClick={() => setImportOpen(true)}><Upload size={16} />Import</button></div>}
            </div>}
        </main>
      </div>
      <Modal
        open={newOpen || folderOpen}
        onOpenChange={(v) => {
          if (!v) {
            setNewOpen(false);
            setFolderOpen(false);
          }
        }}
        title={folderOpen ? "New folder" : "New notebook"}
        description={folderOpen ? "Give your folder a name." : "Choose a cover and paper for your notebook."}
        wide={!folderOpen}
      >
        {!folderOpen && <div className="design-preview"><NotebookCover title={title} cover={{ colorHex: color.replace("#", ""), style: coverStyle }} /><div><h3>Make it yours.</h3><p>A cover you love. Paper that fits the way you think.</p></div></div>}
        <form className="form" onSubmit={folderOpen ? addFolder : create}>
          <label>{folderOpen ? "Folder name" : "Notebook title"}<input autoFocus required maxLength={folderOpen ? 200 : 300} placeholder={folderOpen ? "e.g. School" : "e.g. Biology"} value={title} onChange={e => setTitle(e.target.value)} /></label>
          {!folderOpen && <div className="design-tabs" role="tablist" aria-label="Notebook design"><button type="button" role="tab" id="cover-tab" aria-controls="cover-panel" aria-selected={designTab === "cover"} className={designTab === "cover" ? "active" : ""} onClick={() => setDesignTab("cover")}>Cover</button><button type="button" role="tab" id="paper-tab" aria-controls="paper-panel" aria-selected={designTab === "paper"} className={designTab === "paper" ? "active" : ""} onClick={() => setDesignTab("paper")}>Paper · {paperTemplate === "dots" ? "Dotted" : paperTemplate.charAt(0).toUpperCase() + paperTemplate.slice(1)}</button></div>}
          {(folderOpen || designTab === "cover") && <div id="cover-panel" role={folderOpen ? undefined : "tabpanel"} aria-labelledby={folderOpen ? undefined : "cover-tab"}>
            {!folderOpen && <fieldset className="cover-style-picker"><legend className="field-label">Cover style</legend><div>{["gradient", "linen", "geometric", "minimal"].map(style => <label key={style}><input type="radio" name="cover-style" value={style} checked={coverStyle === style} onChange={() => setCoverStyle(style)} /><span>{style.charAt(0).toUpperCase() + style.slice(1)}</span></label>)}</div></fieldset>}
            <span className="field-label">{folderOpen ? "Folder color" : "Cover color"}</span><div className="color-picker">{palette.map(c => <button key={c} type="button" aria-label={`Choose ${c}`} aria-pressed={color === c} className={color === c ? "color-selected" : ""} style={{ background: c }} onClick={() => setColor(c)}>{color === c && <Check size={18} />}</button>)}</div>
          </div>}
          {!folderOpen && designTab === "paper" && <div id="paper-panel" role="tabpanel" aria-labelledby="paper-tab"><span className="field-label">Paper</span><div className="paper-picker">{["blank", "ruled", "grid", "dots"].map(template => <button type="button" key={template} aria-pressed={paperTemplate === template} className={paperTemplate === template ? "selected" : ""} onClick={() => setPaperTemplate(template)}><span className={`paper-swatch template-${template}`} /><span>{template === "dots" ? "Dotted" : template.charAt(0).toUpperCase() + template.slice(1)}</span></button>)}</div><label>Paper color<select value={paperColor} onChange={e => setPaperColor(e.target.value)}><option value="FFFFFF">White</option><option value="FFFDF5">Cream</option><option value="FFF3B0">Yellow</option><option value="EAF4FF">Blue</option><option value="ECF7EE">Green</option><option value="FCECEF">Pink</option><option value="292927">Dark</option></select></label></div>}
          {formError && <p role="alert" className="form-error">{formError}</p>}
          <button className="button primary full" disabled={busy || !title.trim()}>{busy ? <Loader2 size={18} className="spin" /> : <Plus size={18} />}Create {folderOpen ? "folder" : "notebook"}</button>
        </form>
      </Modal>
      <Modal
        open={!!rename}
        onOpenChange={(v) => !v && setRename(null)}
        title="Rename notebook"
      >
        <form
          className="form"
          onSubmit={async (e) => {
            e.preventDefault();
            if (!rename) return;
            setBusy(true);
            const saved = await mutate(rename, { title: title.trim() });
            if (saved) setRename(null);
            setBusy(false);
          }}
        >
          <label>
            Title
            <input
              required
              maxLength={300}
              value={title}
              onChange={(e) => setTitle(e.target.value)}
            />
          </label>
          <button
            className="button primary full"
            disabled={busy || !title.trim()}
          >
            Save name
          </button>
        </form>
      </Modal>
      <Modal
        open={!!move}
        onOpenChange={(v) => !v && setMove(null)}
        title="Move notebook"
      >
        <form
          className="form"
          onSubmit={async (e) => {
            e.preventDefault();
            if (!move) return;
            setBusy(true);
            const saved = await mutate(move, { folder_id: moveFolder || null });
            if (saved) setMove(null);
            setBusy(false);
          }}
        >
          <label>
            Folder
            <select
              value={moveFolder}
              onChange={(e) => setMoveFolder(e.target.value)}
            >
              <option value="">Library (no folder)</option>
              {folders.map((f) => (
                <option key={f.id} value={f.id}>
                  {f.name}
                </option>
              ))}
            </select>
          </label>
          <button className="button primary full" disabled={busy}>
            Move notebook
          </button>
        </form>
      </Modal>
      {importOpen && (
        <Suspense fallback={null}>
          <ImportLibrary
            open={importOpen}
            onClose={() => setImportOpen(false)}
            folderId={currentFolder?.id || null}
            existing={docs}
            onComplete={() => void refresh()}
            notify={notify}
          />
        </Suspense>
      )}
      <Modal open={settings} onOpenChange={setSettings} title="Settings" description="Appearance and local storage.">
        <div className="settings-section appearance-setting"><label htmlFor="appearance">Appearance</label><select id="appearance" value={appearance} onChange={e => setAppearance(e.target.value as "dark" | "light" | "system")}><option value="dark">Dark</option><option value="light">Light</option><option value="system">System</option></select></div>
        <div className="settings-section"><h3>Saved on this device</h3><p>Your notebooks and imported files are saved in this browser. No account or backend connection is required.</p><p>Download notebook backups before clearing browser data or removing the app. Files do not sync between devices or browsers.</p></div>
      </Modal>
      <Modal
        open={help}
        onOpenChange={setHelp}
        title="Noty help"
        description="Shortcuts and importing your existing notes."
      >
        <div className="help-row">
          <span>Find a note</span>
          <kbd>⌘ / Ctrl + K</kbd>
        </div>
        <div className="help-row">
          <span>Create a notebook</span>
          <kbd>⌘ / Ctrl + N</kbd>
        </div>
        <div className="help-row">
          <span>Save while writing</span>
          <span>Automatic</span>
        </div>
        <p className="help-copy">
          The page editor preserves positioned text, images, PDFs and paper settings. Import local files or notebook backups, and download backups to keep your own copies. Drag an image or the Move handle above a selected text box to reposition it.
        </p>
      </Modal>
      <Alert.Root
        open={!!deleteDoc}
        onOpenChange={(v) => !v && setDeleteDoc(null)}
      >
        <Alert.Portal>
          <Alert.Overlay className="modal-overlay" />
          <Alert.Content className="modal">
            <Alert.Title className="modal-title">
              Delete this notebook forever?
            </Alert.Title>
            <Alert.Description className="modal-description">
              “{deleteDoc?.title}” will be permanently removed from this browser’s local
              library. This cannot be undone.
            </Alert.Description>
            <div className="dialog-actions">
              <Alert.Cancel className="button secondary">Cancel</Alert.Cancel>
              <button
                className="button danger-button"
                disabled={busy}
                onClick={() => deleteDoc && void permanentDelete(deleteDoc)}
              >
                {busy ? "Deleting…" : "Delete permanently"}
              </button>
            </div>
          </Alert.Content>
        </Alert.Portal>
      </Alert.Root>
      {toast && (
        <div className="toast" role="status">
          <Check size={17} />
          <span>{toast}</span>
          <button
            className="icon-button"
            aria-label="Dismiss notification"
            onClick={() => setToast("")}
          >
            <X size={16} />
          </button>
        </div>
      )}
    </div>
  );
}
