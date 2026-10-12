export function validID(value: unknown): boolean;
export function nativeDate(value: unknown): string;
export function safePath(path: string): boolean;
export function resolveLibrary(
  entries: Map<string, Blob>,
): Promise<{
  manifest: { documents: any[]; folders: any[] };
  packages: any[];
  entries: Map<string, Blob>;
  paths: string[];
  manifestPath: string;
}>;
export function findAssets(
  library: Awaited<ReturnType<typeof resolveLibrary>>,
  docID: string,
): { name: string; file: Blob }[];
