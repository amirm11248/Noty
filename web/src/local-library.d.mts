import type { Notebook, Folder, Payload } from "./types";
export class ConflictError extends Error { constructor(); }
export function loadLibrary(): Promise<{ docs: Notebook[]; folders: Folder[] }>;
export function getNotebook(id: string): Promise<Notebook | undefined>;
export function createNotebook(title: string, folderId: string | null, color: string, kind?: string, payload?: Payload): Promise<Notebook>;
export function saveNotebook(doc: Notebook, changes: Partial<Notebook>): Promise<Notebook>;
export function createFolder(name: string, parentId: string | null, color: string): Promise<Folder>;
export function importFolder(folder: Folder): Promise<Folder>;
export function importNotebook(doc: Pick<Notebook, "id" | "title" | "kind" | "folder_id" | "payload"> & Partial<Notebook>, assets?: { name: string; file: Blob }[]): Promise<Notebook>;
export function saveAsset(documentID: string, name: string, file: Blob): Promise<string>;
export function assetBlob(doc: Notebook, name: string): Promise<Blob>;
export function assetURL(doc: Notebook, name: string): Promise<string>;
export function deleteNotebook(doc: Notebook): Promise<void>;
