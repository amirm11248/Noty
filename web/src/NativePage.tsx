import {useEffect, useRef, useState} from "react";
import type {Notebook, Page, TextBox} from "./types";
import {assetURL} from "./cloud";
import {pdfjs} from "./pdf";
import {pageSize, resolveAssetName} from "./sync-model.mjs";

type Stroke = {id:string; color:string; width:number; points:{x:number;y:number}[]};
function AssetImage({doc,name,style}: {doc:Notebook;name:string;style?:React.CSSProperties}) {
  const [url,setURL]=useState(""); const [error,setError]=useState("");
  useEffect(()=>{let active=true; let value="";setError("");setURL("");
    void assetURL(doc,name).then(u=>{value=u;if(active)setURL(u);else URL.revokeObjectURL(u);}).catch(e=>{if(active)setError(e.message);});
    return()=>{active=false;URL.revokeObjectURL(value);};
  },[doc.id,doc.revision,name]);
  return error ? <span className="asset-error" role="alert">{error}</span> : url ? <img src={url} alt="Notebook image" style={style} draggable={false}/> : <span>Loading…</span>;
}
function PDFPage({doc,index,width,height}:{doc:Notebook;index:number;width:number;height:number}) {
  const canvas=useRef<HTMLCanvasElement>(null); const [error,setError]=useState("");
  useEffect(()=>{let active=true; let pdf:any; let render:any; let loading:any;setError("");
    void (async()=>{try {
      const url=await assetURL(doc,doc.payload.sourcePDF || "source.pdf");
      if(!active)return;
      loading=pdfjs.getDocument({url,isEvalSupported:false,rangeChunkSize:256*1024});
      pdf=await loading.promise; if(!active){await pdf.destroy();return;}
      const page=await pdf.getPage(index+1); if(!active||!canvas.current)return;
      const base=page.getViewport({scale:1});const view=page.getViewport({scale:Math.min(2,width/base.width*window.devicePixelRatio)});
      const target=canvas.current;target.width=view.width;target.height=view.height;
      render=page.render({canvas:target,viewport:view});await render.promise;
    }catch(e){if(active && (e as Error).name!=="RenderingCancelledException")setError((e as Error).message);}})();
    return()=>{active=false;render?.cancel();void loading?.destroy();};
  },[doc.id,doc.revision,doc.payload.sourcePDF,index,width]);
  return <><canvas className="native-pdf" ref={canvas} style={{width,height}} aria-label={`Source PDF page ${index+1}`}/>{error&&<p className="asset-error" role="alert">{error}</p>}</>;
}
export default function NativePage({doc,page,onChange,onUpload}:{doc:Notebook;page:Page;onChange:(changes:Partial<Page>)=>void;onUpload:()=>void}) {
  const [selection,setSelection]=useState<{type:"text"|"image";id:string}|null>(null);
  const [tool,setTool]=useState("select"); const [color,setColor]=useState("#202020"); const [strokeWidth,setStrokeWidth]=useState(3);
  const [live,setLive]=useState<Stroke|null>(null); const liveRef=useRef<Stroke|null>(null); const surface=useRef<HTMLDivElement>(null);
  const outer=useRef<HTMLDivElement>(null); const [available,setAvailable]=useState(650);
  useEffect(()=>{if(!outer.current)return;const observer=new ResizeObserver(([e])=>setAvailable(e.contentRect.width));observer.observe(outer.current);return()=>observer.disconnect();},[]);
  useEffect(()=>{setSelection(null);liveRef.current=null;setLive(null);},[page.id]);
  const [width,height]=pageSize(page); const scale=Math.min(1,Math.max(.01,available/width));
  const point=(e:React.PointerEvent)=>{const r=surface.current!.getBoundingClientRect();return{x:(e.clientX-r.left)/scale-Number(page.canvasOffsetX||0),y:(e.clientY-r.top)/scale-Number(page.canvasOffsetY||0)};};
  function updateText(id:string,changes:Partial<TextBox>){onChange({textBoxes:page.textBoxes.map(t=>t.id===id?{...t,...changes}:t), webHTML:undefined});}
  function updateImage(id:string,changes:Record<string,unknown>){onChange({images:page.images.map(t=>t.id===id?{...t,...changes}:t)});}
  const selectedText=selection?.type==="text"?page.textBoxes.find(t=>t.id===selection.id):undefined;
  const selectedImage=selection?.type==="image"?page.images.find(t=>t.id===selection.id):undefined;
  function moveStart(e:React.PointerEvent,type:"text"|"image",id:string,x:number,y:number){
    if(tool!=="select")return;e.stopPropagation();e.currentTarget.setPointerCapture(e.pointerId);setSelection({type,id});
    const origin=point(e);const target=e.currentTarget;
    const move=(event:PointerEvent)=>{const rect=surface.current!.getBoundingClientRect();const next={x:Math.round(x+(event.clientX-rect.left)/scale-Number(page.canvasOffsetX||0)-origin.x),y:Math.round(y+(event.clientY-rect.top)/scale-Number(page.canvasOffsetY||0)-origin.y)};
      if(type==="text")updateText(id,next);else updateImage(id,next);};
    const up=()=>{target.removeEventListener("pointermove",move as EventListener);target.removeEventListener("pointerup",up);target.removeEventListener("pointercancel",up);};
    target.addEventListener("pointermove",move as EventListener);target.addEventListener("pointerup",up,{once:true});target.addEventListener("pointercancel",up,{once:true});
  }
  const strokes=(page.webStrokes || []) as Stroke[];
  const inkName=doc.payload.assets?.find(a=>a.toLowerCase()===`inkpreviews/${page.id}.png`.toLowerCase());
  const hasNativeInk=doc.payload.assets?.some(a=>a.toLowerCase()===`drawings/${page.id}.drawing`.toLowerCase());
  return <div className="native-page-editor">
    <div className="native-tools" role="toolbar" aria-label="Page tools">
      <button aria-pressed={tool==="select"} onClick={()=>setTool("select")}>Select</button>
      <button onClick={()=>{setTool("select");const id=crypto.randomUUID();onChange({textBoxes:[...page.textBoxes,{id,text:"",x:32,y:60,width:Math.min(340,width-64),height:140,fontSize:18,colorHex:"202020",alignment:"leading",isBold:false,isItalic:false,isUnderlined:false}]});setSelection({type:"text",id});}}>Add text</button>
      <button onClick={onUpload}>Add image</button>
      <button aria-pressed={tool==="pen"} onClick={()=>setTool(tool==="pen"?"select":"pen")}>Pen</button>
      <input aria-label="Pen color" type="color" value={color} onChange={e=>setColor(e.target.value)}/>
      <select aria-label="Pen width" value={strokeWidth} onChange={e=>setStrokeWidth(Number(e.target.value))}><option value={1}>Thin</option><option value={3}>Medium</option><option value={6}>Thick</option></select>
      <button disabled={!strokes.length} onClick={()=>onChange({webStrokes:strokes.slice(0,-1)})}>Undo web ink</button>
    </div>
    {(selectedText||selectedImage)&&<div className="object-properties" aria-label="Selected object properties">
      {selectedText&&<><label>Size<input type="number" min={6} max={144} value={selectedText.fontSize} onChange={e=>updateText(selectedText.id,{fontSize:Math.max(6,Number(e.target.value))})}/></label>
      <button aria-pressed={!!selectedText.isBold} onClick={()=>updateText(selectedText.id,{isBold:!selectedText.isBold})}>Bold</button>
      <button aria-pressed={!!selectedText.isItalic} onClick={()=>updateText(selectedText.id,{isItalic:!selectedText.isItalic})}>Italic</button>
      <button aria-pressed={!!selectedText.isUnderlined} onClick={()=>updateText(selectedText.id,{isUnderlined:!selectedText.isUnderlined})}>Underline</button>
      <input aria-label="Text color" type="color" value={`#${selectedText.colorHex||"202020"}`} onChange={e=>updateText(selectedText.id,{colorHex:e.target.value.slice(1)})}/>
      <select aria-label="Text alignment" value={selectedText.alignment||"leading"} onChange={e=>updateText(selectedText.id,{alignment:e.target.value})}><option value="leading">Left</option><option value="center">Center</option><option value="trailing">Right</option></select></>}
      {["x","y","width","height"].map(key=><label key={key}>{key}<input type="number" value={Number((selectedText||selectedImage as any)?.[key as keyof TextBox]||0)} onChange={e=>{const change={[key]:["width","height"].includes(key)?Math.max(10,Number(e.target.value)):Number(e.target.value)};selectedText?updateText(selectedText.id,change):updateImage(selectedImage!.id,change);}}/></label>)}
      {selectedImage&&<><label>Rotation<input type="number" value={selectedImage.rotationDegrees||0} onChange={e=>updateImage(selectedImage.id,{rotationDegrees:Number(e.target.value)})}/></label>{["cropX","cropY","cropWidth","cropHeight"].map(key=><label key={key}>{key}<input type="number" step=".05" min="0" max="1" value={Number((selectedImage as any)[key]??(key.endsWith("Width")||key.endsWith("Height")?1:0))} onChange={e=>updateImage(selectedImage.id,{[key]:Math.max(0,Math.min(1,Number(e.target.value)))})}/></label>)}</>}
      <button onClick={()=>{selectedText?onChange({textBoxes:page.textBoxes.filter(t=>t.id!==selectedText.id),webHTML:undefined}):onChange({images:page.images.filter(i=>i.id!==selectedImage!.id)});setSelection(null);}}>Delete object</button>
    </div>}
    {hasNativeInk&&!inkName&&<p className="native-ink-warning">Sync this notebook from the updated iPad app to show Apple Pencil ink here. The original drawing is preserved.</p>}
    <div ref={outer} className="native-page-outer" style={{height:height*scale}}><div ref={surface} className={`native-page template-${page.template}`} style={{width,height,transform:`scale(${scale})`,backgroundColor:`#${page.paperColorHex||"FFFFFF"}`,touchAction:tool==="pen"?"none":"auto"}}
      onPointerDown={e=>{if(tool!=="pen")return;e.currentTarget.setPointerCapture(e.pointerId);const stroke={id:crypto.randomUUID(),color:color.slice(1),width:strokeWidth,points:[point(e)]};liveRef.current=stroke;setLive(stroke);}}
      onPointerMove={e=>{if(!liveRef.current)return;const stroke={...liveRef.current,points:[...liveRef.current.points,point(e)]};liveRef.current=stroke;setLive(stroke);}}
      onPointerUp={()=>{if(liveRef.current)onChange({webStrokes:[...strokes,liveRef.current]});liveRef.current=null;setLive(null);}}
      onPointerCancel={()=>{liveRef.current=null;setLive(null);}}>
      {page.sourcePageIndex!==undefined&&<PDFPage doc={doc} index={page.sourcePageIndex} width={width} height={height}/>}
      {page.images.map(image=>{const cw=Math.max(.01,Number(image.cropWidth??1)),ch=Math.max(.01,Number(image.cropHeight??1));return <div className={`native-image native-object ${selection?.id===image.id?"selected":""}`} key={image.id}
        style={{left:image.x+Number(page.canvasOffsetX||0),top:image.y+Number(page.canvasOffsetY||0),width:image.width,height:image.height,transform:`rotate(${image.rotationDegrees||0}deg)`,pointerEvents:tool==="pen"?"none":"auto",overflow:"hidden"}}
        onPointerDown={e=>moveStart(e,"image",image.id,image.x,image.y)}>
        <AssetImage doc={doc} name={resolveAssetName(doc,page,image)} style={{position:"absolute",maxWidth:"none",width:`${100/cw}%`,height:`${100/ch}%`,left:`${-Number(image.cropX??0)*100/cw}%`,top:`${-Number(image.cropY??0)*100/ch}%`}}/>
      </div>})}
      {inkName&&<div className="native-ink"><AssetImage doc={doc} name={inkName} style={{width:"100%",height:"100%"}}/></div>}
      <svg className="web-ink" width={width} height={height} aria-label="Web drawings">{[...strokes,...(live?[live]:[])].map(s=><polyline key={s.id} points={s.points.map(p=>`${p.x+Number(page.canvasOffsetX||0)},${p.y+Number(page.canvasOffsetY||0)}`).join(" ")} stroke={`#${s.color}`} strokeWidth={s.width} fill="none" strokeLinecap="round" strokeLinejoin="round"/>)}</svg>
      {page.textBoxes.map(text=><div className={`native-text native-object ${selection?.id===text.id?"selected":""}`} key={text.id} style={{left:text.x+Number(page.canvasOffsetX||0),top:text.y+Number(page.canvasOffsetY||0),width:text.width,height:text.height,pointerEvents:tool==="pen"?"none":"auto"}}>
        <button className="object-handle" aria-label="Move text box" onPointerDown={e=>moveStart(e,"text",text.id,text.x,text.y)}>Move</button>
        <textarea aria-label="Text box" value={text.text} placeholder="Write here…" onFocus={()=>setSelection({type:"text",id:text.id})} onChange={e=>updateText(text.id,{text:e.target.value})}
        style={{fontSize:text.fontSize,fontFamily:text.fontName||"system-ui",fontWeight:text.isBold?700:400,fontStyle:text.isItalic?"italic":"normal",textDecoration:text.isUnderlined?"underline":"none",color:`#${text.colorHex||"37352F"}`,textAlign:text.alignment==="trailing"?"right":text.alignment==="center"?"center":"left",padding:8*(Number(text.paddingScale)||1)}}/>
      </div>)}
    </div></div>
  </div>;
}
