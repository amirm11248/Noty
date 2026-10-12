import * as pdfjs from "pdfjs-dist";
import workerURL from "pdfjs-dist/build/pdf.worker.min.mjs?url";
pdfjs.GlobalWorkerOptions.workerSrc = workerURL;
export { pdfjs };
export async function getPDFInfo(file: Blob) {
  const pdf = await pdfjs.getDocument({
    data: new Uint8Array(await file.arrayBuffer()),
    isEvalSupported: false,
  }).promise;
  const pages = pdf.numPages;
  await pdf.destroy();
  return { pages };
}
