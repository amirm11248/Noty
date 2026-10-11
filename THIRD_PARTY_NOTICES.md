# Third-party notices

**Reviewed:** 2026-10-11

The root [MIT License](LICENSE), Copyright (c) 2026 Malik Abdullah Amir, applies
to original Noty code, documentation, and original project assets to the extent
the maintainer holds the relevant rights. Dependencies and external materials
retain their own copyrights and licenses.

## Bundled native document libraries

The existing full notices in `Noty/Core/Resources/` remain included in the app's
resource bundle. Preserve them when redistributing the bundled JavaScript.

| Library | License and preserved notice |
| --- | --- |
| [docx-preview](https://github.com/VolodymyrBaydalka/docxjs) | Apache-2.0; Copyright Volodymyr Baydalka; [DOCXPreview-LICENSE.txt](Noty/Core/Resources/DOCXPreview-LICENSE.txt) |
| [JSZip](https://github.com/Stuk/jszip) | MIT option of the upstream MIT-or-GPLv3 dual license; [JSZip-LICENSE.txt](Noty/Core/Resources/JSZip-LICENSE.txt) |
| [Pako](https://github.com/nodeca/pako) bundled with JSZip | MIT; [Pako-LICENSE.txt](Noty/Core/Resources/Pako-LICENSE.txt) |

The Swift package resolution file also records
[FontKit](https://github.com/VishwaiOSDev/FontKit) at revision
`d058c81d3c16d1993f40240d071e360a3519e571`, under MIT, Copyright (c) 2022
VishwaiOSDev. Its notice is retained in
[third-party-licenses/FontKit-LICENSE.txt](third-party-licenses/FontKit-LICENSE.txt).
The current Xcode app/test targets have no linked package products; this records
the resolved package's terms without claiming it is currently linked.

## Web companion and server dependencies

`web/package.json` and `web/package-lock.json` record the web dependency versions.
The following license identifiers are recorded in the current lockfile. Retain
the dependencies' full notices when distributing a built application; the root
MIT license does not replace them.

| Packages | License |
| --- | --- |
| React, React DOM, Radix UI components, free Tiptap packages, Supabase JS, Noble hashes, fflate, Vite, and the React Vite plugin | MIT |
| Lucide React | ISC; preserve all notices supplied with its icon package |
| Mammoth | BSD-2-Clause |
| PDF.js (`pdfjs-dist`) and TypeScript | Apache-2.0 |
| DM Sans and Instrument Serif through Fontsource | SIL Open Font License 1.1 (`OFL-1.1`) |

The Supabase Edge Functions import version-pinned
[`@supabase/supabase-js`](https://github.com/supabase/supabase-js) under MIT and
AWS SDK S3 packages under [Apache-2.0](https://github.com/aws/aws-sdk-js-v3/blob/main/LICENSE).
These imported dependencies keep their own terms.

## Assets and platform services

The custom notebook app icon was created with the image-generation tool as
documented in [APP_ICON.md](APP_ICON.md). The original icon and project artwork
are covered by the root license to the extent the maintainer holds rights to
license them. Imported user documents, photos, fonts, and recordings are not
licensed by this repository.

Apple frameworks and system symbols are referenced through platform APIs;
Apple's SDKs and system artwork are not redistributed under the project's MIT
license. Supabase, Backblaze B2, iCloud, OneDrive, and hosting services retain
their own service terms. A source-code license does not grant rights to accounts,
stored user data, platform services, or third-party trademarks.
