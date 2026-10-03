export function pageSize(page) {
  if(Number.isFinite(page.customWidth)&&Number.isFinite(page.customHeight)&&page.customWidth>0&&page.customHeight>0)return [page.customWidth,page.customHeight];
  const sizes={a4:[595,842],a5:[420,595],letter:[612,792],legal:[612,1008],square:[720,720],screen4x3:[768,1024],widescreen16x9:[720,1280]};
  const size=sizes[page.sizePreset]||sizes.letter;return page.orientation==='landscape'?[size[1],size[0]]:size;
}
export function resolveAssetName(doc,page,image){const desired=`Images/${page.id}/${image.fileName}`;return doc.payload.assets?.find(a=>a.toLowerCase()===desired.toLowerCase())||desired;}
export function movePage(pages,id,direction){const list=[...pages],index=list.findIndex(p=>p.id===id),next=index+direction;if(index<0||next<0||next>=list.length||list[next].isCover)return list;[list[index],list[next]]=[list[next],list[index]];return list;}
export function draftKey(doc){return `noty-draft:${doc.user_id}:${doc.id}`;}
export function saveDraft(storage,doc,baseRevision){storage.setItem(draftKey(doc),JSON.stringify({document:doc,baseRevision,savedAt:Date.now()}));}
export function readDraft(storage,doc){try{const value=JSON.parse(storage.getItem(draftKey(doc))||'null');return value?.document?.user_id===doc.user_id&&value?.document?.id===doc.id?value:null;}catch{return null;}}
