import type {Notebook,Page} from './types';
export function pageSize(page:Page): [number,number];
export function resolveAssetName(doc:Notebook,page:Page,image:Page['images'][number]):string;
export function movePage(pages:Page[],id:string,direction:number):Page[];
export function draftKey(doc:Notebook):string;
export function saveDraft(storage:Storage,doc:Notebook,baseRevision:number):void;
export function readDraft(storage:Storage,doc:Notebook):{document:Notebook;baseRevision:number;savedAt:number}|null;
