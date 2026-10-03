import { newPage } from "./types";
import { createClient } from "@supabase/supabase-js";
import type { Notebook, Folder, Payload } from "./types";
import { manifestAssets } from "./sync-model.mjs";
export const cloud = createClient(
  "https://diwtlxvlpiyeownljjpz.supabase.co",
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRpd3RseHZscGl5ZW93bmxqanB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTc3NjMzNDMsImV4cCI6MjA3MzMzOTM0M30.A-c0ylufHucKDTuxt5ykiVHjl03cPSzDwYomdaweyNk",
);
export class ConflictError extends Error {
  constructor() {
    super(
      "This notebook changed on another device. Your draft is preserved. Download it, then reload the notebook to continue.",
    );
  }
}
export async function loadLibrary() {
  const docs: Notebook[] = [];
  const folders: Folder[] = [];
  for (let from = 0; ; from += 500) {
    const { data, error } = await cloud
      .from("noty_web_documents")
      .select("*")
      .order("updated_at", { ascending: false })
      .range(from, from + 499);
    if (error) throw error;
    docs.push(...data);
    if (data.length < 500) break;
  }
  for (let from = 0; ; from += 500) {
    const { data, error } = await cloud
      .from("noty_web_folders")
      .select("*")
      .order("name")
      .range(from, from + 499);
    if (error) throw error;
    folders.push(...data);
    if (data.length < 500) break;
  }
  return { docs, folders };
}
export async function createNotebook(
  userId: string,
  title: string,
  folderId: string | null,
  color: string,
  kind = "note",
  payload?: Payload,
) {
  const { data, error } = await cloud
    .from("noty_web_documents")
    .insert({
      id: crypto.randomUUID(),
      user_id: userId,
      title,
      folder_id: folderId,
      kind,
      payload: payload || {
        pages: [newPage()],
        cover: { colorHex: color.replace("#", ""), style: "gradient" },
      },
    })
    .select()
    .single();
  if (error) throw error;
  return data as Notebook;
}
export async function saveNotebook(doc: Notebook, changes: Partial<Notebook>) {
  const versionKey=`${doc.user_id}:${doc.id}`;
  const sentVersions=uploadedVersions.get(versionKey)||{};
  if(changes.payload) {
    const key=`${doc.user_id}:${doc.id}`;
    changes={...changes,payload:{...changes.payload,assetManifest:{...(changes.payload.assetManifest as object||{}),...uploadedVersions.get(key)}}};
  }
  const { id, user_id, revision, created_at, updated_at, ...allowed } = changes;
  void id;
  void user_id;
  void revision;
  void created_at;
  void updated_at;
  const { data, error } = await cloud
    .from("noty_web_documents")
    .update(allowed)
    .eq("id", doc.id)
    .eq("user_id", doc.user_id)
    .eq("revision", doc.revision)
    .select()
    .maybeSingle();
  if (error) throw error;
  if (!data) throw new ConflictError();
  const pending={...uploadedVersions.get(versionKey)};
  for(const [path,ref] of Object.entries(sentVersions))if(pending[path]?.object_key===ref.object_key)delete pending[path];
  uploadedVersions.set(versionKey,pending);
  return data as Notebook;
}
export async function createFolder(
  userId: string,
  name: string,
  parentId: string | null,
  color: string,
) {
  const { data, error } = await cloud
    .from("noty_web_folders")
    .insert({
      id: crypto.randomUUID(),
      user_id: userId,
      name,
      parent_id: parentId,
      color,
      payload: {design:{style:"minimal",colorHex:color.replace("#","")}},
    })
    .select()
    .single();
  if (error) throw error;
  return data as Folder;
}
const uploadedVersions = new Map<string, Record<string, CloudAsset>>();
export interface CloudAsset {
  user_id: string; document_id: string; relative_path: string; object_key: string;
  sha256: string; byte_size: number; content_type: string; updated_at: string;
}
export async function listAssets(doc: Notebook): Promise<CloudAsset[]> {
  const rows: CloudAsset[] = [];
  for (let from = 0;; from += 500) {
    const {data, error} = await cloud.from("noty_cloud_assets").select("*")
      .eq("user_id", doc.user_id).eq("document_id", doc.id).order("relative_path").range(from, from + 499);
    if (error) throw error;
    rows.push(...data); if (data.length < 500) return rows;
  }
}
export async function objectRequest(body: Record<string, unknown>) {
  const {data, error} = await cloud.functions.invoke("noty-cloud-object", {body});
  if (error) throw new Error("Cloud storage request failed. " + error.message);
  if (data?.message && !data.url && !data.ok) throw new Error(data.message);
  return data;
}
export async function uploadAsset(userId: string, docId: string, name: string, data: Blob,
  options: {signal?: AbortSignal; onProgress?: (percent: number) => void} = {}) {
  if (data.size > 250 * 1024 * 1024) throw new Error(`${name} is larger than 250 MB.`);
  const {safePath} = await import("./native-library.mjs");
  if (!safePath(name) || name.includes("\\") || name.includes("\0")) throw new Error("Invalid asset path.");
  const {data: session} = await cloud.auth.getSession();
  if (session.session?.user.id !== userId) throw new Error("Sign in to the correct Noty account.");
  const {sha256} = await import("@noble/hashes/sha256");
  const hash = sha256.create();
  for (let offset = 0; offset < data.size; offset += 4 * 1024 * 1024) {
    options.signal?.throwIfAborted();
    hash.update(new Uint8Array(await data.slice(offset, offset + 4 * 1024 * 1024).arrayBuffer()));
  }
  const digest = Array.from(hash.digest(), b => b.toString(16).padStart(2, "0")).join("");
  const contentType = data.type || mimeForPath(name);
  // Retry the same complete object. Metadata is never published after an interrupted PUT.
  let lastError: unknown;
  for (let attempt = 0; attempt < 3; attempt++) {
    options.signal?.throwIfAborted();
    try {
      const signed = await objectRequest({action:"presign_upload", documentID:docId, relativePath:name, contentType,sha256:digest});
      await new Promise<void>((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        const abort = () => xhr.abort();
        options.signal?.addEventListener("abort", abort, {once:true});
        const done = () => options.signal?.removeEventListener("abort", abort);
        xhr.open("PUT", signed.url); xhr.timeout = 300000;
        xhr.setRequestHeader("Content-Type", contentType);
        xhr.upload.onprogress = e => {if(e.lengthComputable) options.onProgress?.(Math.round(e.loaded/e.total*100));};
        xhr.onload = () => {done(); xhr.status >= 200 && xhr.status < 300 ? resolve() : reject(new Error(`Upload failed (${xhr.status}).`));};
        xhr.onerror = xhr.ontimeout = () => {done(); reject(new Error("Upload interrupted. Check your connection and try again."));};
        xhr.onabort = () => {done(); reject(new DOMException("Upload cancelled", "AbortError"));};
        xhr.send(data);
      });
      await objectRequest({action:"verify_upload", documentID:docId, relativePath:name, byteSize:data.size,objectKey:signed.objectKey});
      const {error} = await cloud.from("noty_cloud_assets").upsert({user_id:userId, document_id:docId,
        relative_path:name, object_key:signed.objectKey, sha256:digest, byte_size:data.size, content_type:contentType,
        updated_at:new Date().toISOString()}, {onConflict:"user_id,document_id,relative_path"});
      if(error) throw error;
      const key=`${userId}:${docId}`;
      uploadedVersions.set(key,{...uploadedVersions.get(key),[name]:{user_id:userId,document_id:docId,relative_path:name,object_key:signed.objectKey,sha256:digest,byte_size:data.size,content_type:contentType,updated_at:new Date().toISOString()}});
      return name;
    } catch (error) {
      lastError = error;
      if (options.signal?.aborted || (error as Error).name === "AbortError") throw error;
      if (attempt < 2) await new Promise(resolve => setTimeout(resolve, 500 * 2 ** attempt));
    }
  }
  throw lastError;
}
function mimeForPath(name: string) {
  const ext = name.split(".").pop()?.toLowerCase();
  return ({pdf:"application/pdf", png:"image/png", jpg:"image/jpeg", jpeg:"image/jpeg", webp:"image/webp", m4a:"audio/mp4", mp3:"audio/mpeg", wav:"audio/wav", json:"application/json"} as Record<string,string>)[ext || ""] || "application/octet-stream";
}
export async function assetURL(doc: Notebook, name: string) {
  const versions = doc.payload.assetManifest as Record<string, CloudAsset> | undefined;
  const assets = versions && Object.keys(versions).length ? manifestAssets(versions) : await listAssets(doc);
  // Native UUID path segments are uppercase; database IDs are lowercase.
  const asset = assets.find(a => a.relative_path.toLowerCase() === name.toLowerCase());
  if (asset) {
    const signed = await objectRequest({action:"presign_download", documentID:doc.id, relativePath:asset.relative_path,objectKey:asset.object_key});
    return signed.url as string;
  }
  // Read-only compatibility for files uploaded before the B2 migration.
  const {data, error} = await cloud.storage.from("noty-library").download(`${doc.user_id}/${doc.id}/${name}`);
  if(error) throw new Error(`Asset is not uploaded yet: ${name}. Sync the iPad and retry.`);
  return URL.createObjectURL(data);
}
export async function hydrateNotebook(doc: Notebook): Promise<Notebook> {
  const assets = await listAssets(doc);
  const pinned=doc.payload.assetManifest as Record<string,CloudAsset>|undefined;
  const names = [...new Set([...(doc.payload.assets || []), ...(pinned&&Object.keys(pinned).length?Object.keys(pinned):assets.map(a => a.relative_path))])];
  const prior=(doc.payload.assetManifest||{}) as Record<string,CloudAsset>;
  const manifest={...(pinned&&Object.keys(pinned).length?{}:Object.fromEntries(assets.map(a=>[a.relative_path,a]))),...prior};
  return {...doc, payload:{...doc.payload, assets:names,assetManifest:manifest,
    ...(names.some(n => n.toLowerCase() === "source.pdf") ? {sourcePDF:names.find(n => n.toLowerCase() === "source.pdf")} : {})}};
}
export async function deleteNotebook(doc: Notebook) {
  const {data, error} = await cloud.from("noty_web_documents").delete().eq("id",doc.id)
    .eq("user_id",doc.user_id).eq("revision",doc.revision).select("id");
  if(error) throw error;
  if(!data?.length) throw new ConflictError();
  // The durable database tombstone comes first; failed cleanup can safely be retried.
  await objectRequest({action:"delete_document", documentID:doc.id});
  const {error: assetError} = await cloud.from("noty_cloud_assets").delete().eq("user_id",doc.user_id).eq("document_id",doc.id);
  if(assetError) throw assetError;
}

export function uploadedManifest(userId:string,docId:string){return uploadedVersions.get(`${userId}:${docId}`)||{};}
