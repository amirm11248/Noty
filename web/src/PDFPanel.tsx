import { useEffect, useRef, useState } from "react";
import { ChevronLeft, ChevronRight, Loader2, Download } from "./icons";
import { pdfjs } from "./pdf";
import type { PDFDocumentProxy } from "pdfjs-dist";
import type { Notebook } from "./types";
import { assetURL } from "./cloud";
export default function PDFPanel({ doc }: { doc: Notebook }) {
  const [pdf, setPDF] = useState<PDFDocumentProxy | null>(null);
  const [page, setPage] = useState(1);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(true);
  const canvas = useRef<HTMLCanvasElement>(null);
  const urlRef = useRef("");
  useEffect(() => {
    let active = true;
    let loaded: PDFDocumentProxy | null = null;
    const run = async () => {
      try {
        const url = await assetURL(doc, doc.payload.sourcePDF!);
        if (!active) {
          URL.revokeObjectURL(url);
          return;
        }
        urlRef.current = url;
        const data = new Uint8Array(await (await fetch(url)).arrayBuffer());
        loaded = await pdfjs.getDocument({ data, isEvalSupported: false })
          .promise;
        if (active) {
          setPDF(loaded);
          setBusy(false);
        } else await loaded.destroy();
      } catch (e) {
        if (active) {
          setError((e as Error).message);
          setBusy(false);
        }
      }
    };
    void run();
    return () => {
      active = false;
      void loaded?.destroy();
      if (urlRef.current) URL.revokeObjectURL(urlRef.current);
    };
  }, [doc.id, doc.payload.sourcePDF]);
  useEffect(() => {
    if (!pdf || !canvas.current) return;
    let cancelled = false;
    let task:
      | ReturnType<Awaited<ReturnType<PDFDocumentProxy["getPage"]>>["render"]>
      | undefined;
    void pdf
      .getPage(page)
      .then((p) => {
        if (cancelled || !canvas.current) return;
        const viewport = p.getViewport({ scale: 1.7 });
        const target = canvas.current;
        target.width = viewport.width;
        target.height = viewport.height;
        task = p.render({ canvas: target, viewport });
        return task.promise;
      })
      .catch((e) => {
        if (!cancelled) setError(e.message);
      });
    return () => {
      cancelled = true;
      task?.cancel();
    };
  }, [pdf, page]);
  return (
    <div className="pdf-viewer">
      {error ? (
        <div className="editor-error" role="alert">
          Couldn’t open this PDF. {error}
        </div>
      ) : busy ? (
        <div className="pdf-loading">
          <Loader2 className="spin" size={22} />
          Opening document…
        </div>
      ) : (
        <>
          <div className="pdf-controls">
            <button
              className="icon-button"
              aria-label="Previous PDF page"
              disabled={page <= 1}
              onClick={() => setPage((p) => p - 1)}
            >
              <ChevronLeft size={19} />
            </button>
            <span>
              Page {page} of {pdf?.numPages}
            </span>
            <button
              className="icon-button"
              aria-label="Next PDF page"
              disabled={page >= (pdf?.numPages || 1)}
              onClick={() => setPage((p) => p + 1)}
            >
              <ChevronRight size={19} />
            </button>
            <button
              className="icon-button"
              aria-label="Download original PDF"
              onClick={() => {
                const a = document.createElement("a");
                a.href = urlRef.current;
                a.download = `${doc.title}.pdf`;
                a.click();
              }}
            >
              <Download size={18} />
            </button>
          </div>
          <canvas ref={canvas} aria-label={`PDF page ${page}`} />
        </>
      )}
    </div>
  );
}
