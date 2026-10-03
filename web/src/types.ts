export interface TextBox {
  id: string;
  text: string;
  x: number;
  y: number;
  width: number;
  height: number;
  fontSize: number;
  fontName?: string;
  paddingScale?: number;
  [key: string]: unknown;
  isBold?: boolean;
  isItalic?: boolean;
  isUnderlined?: boolean;
  colorHex?: string;
  alignment?: string;
}
export interface Page {
  id: string;
  template: string;
  textBoxes: TextBox[];
  images: {
    id: string;
    fileName: string;
    x: number;
    y: number;
    width: number;
    height: number;
    rotationDegrees?: number;
    cropX?: number; cropY?: number; cropWidth?: number; cropHeight?: number;
    [key:string]: unknown;
  }[];
  isCover?: boolean;
  isBookmarked?: boolean;
  bookmarkTitle?: string;
  paperColorHex?: string;
  sizePreset?: string;
  orientation?: string;
  sourcePageIndex?: number;
  webHTML?: string;
  [key: string]: unknown;
}
export interface Payload {
  pages: Page[];
  cover?: { colorHex: string; style?: string; imageFileName?: string };
  studyCards?: { id: string; question: string; answer: string }[];
  sourcePDF?: string;
  assets?: string[];
  [key: string]: unknown;
}
export interface Notebook {
  id: string;
  user_id: string;
  title: string;
  kind: string;
  folder_id: string | null;
  payload: Payload;
  starred: boolean;
  trashed_at: string | null;
  created_at: string;
  updated_at: string;
  revision: number;
}
export interface Folder {
  id: string;
  user_id: string;
  name: string;
  parent_id: string | null;
  color: string;
  updated_at: string;
  payload?: {design?:{style?:string;colorHex:string};symbol?:string;imageData?:string;[key:string]:unknown};
}
export const palette = [
  "#5267A9",
  "#497B76",
  "#A0687D",
  "#B58C54",
  "#5F537C",
  "#3F4B5B",
  "#BD6D58",
  "#6E8054",
];
export const newPage = (): Page => ({
  id: crypto.randomUUID(),
  template: "blank",
  textBoxes: [],
  images: [],
  sizePreset: "letter",
  orientation: "portrait",
  paperColorHex: "FFFFFF",
  webHTML: "",
});
export const pageText = (page: Page) =>
  page.textBoxes.map((t) => t.text).join("\n");
export const notebookText = (doc: Notebook) =>
  doc.payload.pages.map(pageText).join("\n");
