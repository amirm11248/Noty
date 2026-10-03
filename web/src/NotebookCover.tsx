import { useEffect, useState } from "react";
import type { CSSProperties } from "react";
import { Star, Sparkle } from "./icons";
import { assetURL } from "./cloud";
import type { Notebook, Payload } from "./types";

export default function NotebookCover({ title, cover, doc }: {
  title: string;
  cover?: Payload["cover"];
  doc?: Notebook;
}) {
  const [photo, setPhoto] = useState("");
  const imageFileName = cover?.imageFileName;
  useEffect(() => {
    let active = true;
    let objectURL = "";
    setPhoto("");
    if (doc && imageFileName) {
      const name = doc.payload.assets?.find((a) => a.toLowerCase() === imageFileName.toLowerCase()) || imageFileName;
      void assetURL(doc, name).then((url) => {
        objectURL = url;
        if (active) setPhoto(url);
        else URL.revokeObjectURL(url);
      }).catch(() => {});
    }
    return () => { active = false; if (objectURL) URL.revokeObjectURL(objectURL); };
  }, [doc?.id, doc?.user_id, imageFileName]);
  const color = /^[0-9a-f]{6}$/i.test(cover?.colorHex || "") ? `#${cover!.colorHex}` : "#5267A9";
  const style = ["minimal", "gradient", "linen", "geometric"].includes(cover?.style || "") ? cover!.style : "gradient";
  return (
    <div className={`notebook-cover cover-${style} ${photo ? "cover-photo" : ""}`} style={{ "--cover-color": color } as CSSProperties}>
      {photo && <img className="cover-image" src={photo} alt="" />}
      <div className="cover-spine" />
      <div className="cover-content">
        <div className="cover-top"><Sparkle size={22} strokeWidth={1.2} />{doc?.starred && <Star size={14} fill="currentColor" />}</div>
        <div className="cover-title">{title.trim() || "My notebook"}</div>
        <div className="cover-bottom"><span className="cover-rule" /><span>NOTY</span></div>
      </div>
    </div>
  );
}
